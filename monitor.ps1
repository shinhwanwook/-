﻿# 실행 모드: "" = 전체수집, "online" = 온라인상태만 갱신
param([string]$Mode = "")

$FIREBASE_PROJECT = "rental-management-8c377"
$FIREBASE_API_KEY = "AIzaSyAoEuQ_femEy46c07wIHXY3WykfXvqZRgk"
$FIREBASE_URL     = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/device_status"
$RENTAL_URL       = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/rental/main"

# ================================================================
#  설치 시 이 부분만 수정하세요!
#  이 PC에 연결된 프린터 IP만 입력합니다
#  (다른 거래처 IP는 입력하지 마세요)
# ================================================================
# ================================================================
# 상시 온라인 유지 시스템 v16.0
# - PC 시작 시 자동 실행
# - 30분마다 자동 수집
# - 오프라인/bw=0이면 Firebase SKIP (기존 데이터 보호)
# ================================================================
$MY_PRINTER_IPS = @(
    "192.168.1.100"   # ← 이 PC에 연결된 프린터 IP로 변경
    # "192.168.1.101" # ← 프린터가 2대면 이 줄 주석 해제 후 IP 입력
)
# ================================================================

# ============================================================
# 공통 함수
# ============================================================
function Get-WebPage([string]$url, [int]$timeout=30, [string]$cookie="", [string]$referer="") {
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeout * 1000
        $req.Method = "GET"
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        $req.AllowAutoRedirect = $true
        $req.Accept = "text/html,*/*"
        if ($cookie)  { $req.Headers.Add("Cookie", $cookie) }
        if ($referer) { $req.Referer = $referer }
        $res = $req.GetResponse()
        $sr  = New-Object System.IO.StreamReader($res.GetResponseStream())
        $html = $sr.ReadToEnd()
        $sr.Close(); $res.Close()
        return $html
    } catch { return $null }
}

function Encode-OID([int[]]$oid) {
    $enc = [System.Collections.ArrayList]@()
    [void]$enc.Add([byte]($oid[0]*40+$oid[1]))
    for ($i=2; $i -lt $oid.Length; $i++) {
        $v=$oid[$i]
        if ($v -lt 128) { [void]$enc.Add([byte]$v) }
        else {
            $b=[System.Collections.ArrayList]@()
            while ($v -gt 0) { [void]$b.Insert(0,[byte]($v -band 0x7F)); $v=$v -shr 7 }
            for ($j=0; $j -lt $b.Count-1; $j++) { [void]$enc.Add([byte]($b[$j] -bor 0x80)) }
            [void]$enc.Add([byte]$b[$b.Count-1])
        }
    }
    return [byte[]]$enc
}

function Get-SNMP([string]$ip, [int[]]$oid) {
    $udp = $null
    try {
        $oidEnc  = Encode-OID $oid
        $oidTlv  = [byte[]](,0x06)+[byte[]]($oidEnc.Length)+$oidEnc
        $varBind = [byte[]](,0x30)+[byte[]]($oidTlv.Length+2)+$oidTlv+[byte[]](0x05,0x00)
        $varList = [byte[]](,0x30)+[byte[]]($varBind.Length)+$varBind
        $pduData = [byte[]](0x02,0x04,0x00,0x00,0x00,0x01,0x02,0x01,0x00,0x02,0x01,0x00)+$varList
        $pdu     = [byte[]](,0xA0)+[byte[]]($pduData.Length)+$pduData
        $comm    = [System.Text.Encoding]::ASCII.GetBytes("public")
        $commTlv = [byte[]](,0x04)+[byte[]]($comm.Length)+$comm
        $msg     = [byte[]](0x02,0x01,0x00)+$commTlv+$pdu
        $packet  = [byte[]](,0x30)+[byte[]]($msg.Length)+$msg
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 3000
        $udp.Connect($ip, 161)
        $udp.Send($packet, $packet.Length) | Out-Null
        $ep   = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        if ($resp[$resp.Length-2] -eq 0x05) { return $null }
        $last = $null
        for ($i=0; $i -lt $resp.Length-2; $i++) {
            if ($resp[$i] -in @(0x41,0x42,0x43)) {
                $len=$resp[$i+1]; $v=[long]0
                for ($j=0;$j -lt $len;$j++) { $v=($v -shl 8) -bor $resp[$i+2+$j] }
                $last=$v; $i+=1+$len
            } elseif ($resp[$i] -eq 0x02) {
                $len=$resp[$i+1]
                if ($len -ge 1 -and $len -le 4) {
                    $v=[long]0
                    for ($j=0;$j -lt $len;$j++) { $v=($v -shl 8) -bor $resp[$i+2+$j] }
                    if ($v -ge 3) { $last=$v }
                    $i+=1+$len
                }
            }
        }
        return $last
    } catch { return $null }
    finally { if ($udp) { try { $udp.Close() } catch {} } }
}

function Get-TonerPct($cur, $max) {
    if ($null -ne $cur -and $null -ne $max -and [long]$max -gt 0) {
        $diff = [math]::Abs([long]$max - [long]$cur)
        if ([long]$max -gt 200 -and $diff -le 10) { return -1 }
        $pct = [math]::Round([long]$cur / [long]$max * 100)
        return [math]::Max(0, [math]::Min(100, $pct))
    }
    return -1
}

# ============================================================
# Firebase 저장
# ============================================================
function Save-Firebase([string]$docId, [hashtable]$data) {
    $url = "$FIREBASE_URL/${docId}?key=$FIREBASE_API_KEY"
    $fields = @{}
    foreach ($k in $data.Keys) {
        $v = $data[$k]
        if ($v -is [int] -or $v -is [long]) {
            $fields[$k] = @{ integerValue = ([long]$v).ToString() }
        } else {
            $fields[$k] = @{ stringValue = [string]$v }
        }
    }
    $body = @{ fields = $fields } | ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-RestMethod -Uri $url -Method Patch -Body $body -ContentType "application/json; charset=utf-8" | Out-Null
        return $true
    } catch { Write-Host "  Firebase err: $_"; return $false }
}

# ============================================================
# 임대관리에서 내 IP에 해당하는 거래처만 로드
# ============================================================
function Load-MyPrinters([string[]]$myIps) {
    $list = @()
    try {
        # 임대관리 거래처 목록
        $url = "$RENTAL_URL`?key=$FIREBASE_API_KEY"
        $res = Invoke-RestMethod -Uri $url -Method Get
        $contracts = $res.fields.CONTRACTS.arrayValue.values

        # 기존 device_status 번호 확인
        $existingIps = @{}
        $maxNo = 0
        try {
            $devUrl = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/device_status`?key=$FIREBASE_API_KEY&pageSize=100"
            $devRes = Invoke-RestMethod -Uri $devUrl -Method Get
            if ($devRes.documents) {
                foreach ($doc in $devRes.documents) {
                    $docName = $doc.name.Split('/')[-1]
                    if ($docName -match '^device_(\d+)$') {
                        $n = [int]$matches[1]
                        if ($n -gt $maxNo) { $maxNo = $n }
                        $ip = $doc.fields.ip.stringValue
                        if ($ip) { $existingIps[$ip.Trim()] = $n }
                    }
                }
            }
        } catch {}

        foreach ($c in $contracts) {
            $f    = $c.mapValue.fields
            $ip   = $f.printer_ip.stringValue
            $type = $f.printer_type.stringValue
            $name = $f.name.stringValue
            $model= $f.etc.stringValue
            $term = $f.terminated.booleanValue

            if (-not $ip -or $ip.Trim() -eq '' -or $term) { continue }

            # 내 IP 목록에 있는 것만 처리
            if ($myIps -notcontains $ip.Trim()) { continue }

            if ($existingIps.ContainsKey($ip.Trim())) {
                $devNo = $existingIps[$ip.Trim()]
            } else {
                $maxNo++
                $devNo = $maxNo
            }

            $list += [PSCustomObject]@{
                no    = $devNo
                name  = if ($name)  { $name  } else { "거래처$devNo" }
                ip    = $ip.Trim()
                model = if ($model) { $model } else { "" }
                type  = if ($type)  { $type  } else { "ricoh" }
            }
        }

        if ($list.Count -eq 0) {
            Write-Host "  [경고] 임대관리에서 이 PC의 프린터를 찾을 수 없습니다." -ForegroundColor Yellow
            Write-Host "  MY_PRINTER_IPS 에 입력한 IP를 확인하세요." -ForegroundColor Yellow
            Write-Host "  임대관리에 IP가 등록되어 있는지 확인하세요." -ForegroundColor Yellow
        } else {
            Write-Host "  임대관리에서 $($list.Count)개 프린터 로드완료" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [오류] 임대관리 연결 실패: $_" -ForegroundColor Red
    }
    return $list
}

# ============================================================
# 리코 수집
# ============================================================
function Get-RicohData([string]$ip) {
    $r = @{ bw=0; color=0; tk=-1; tc=-1; tm=-1; ty=-1; online="False"; status="Offline" }
    try {
        $main = Get-WebPage "http://$ip/"
        if (-not $main) { return $r }
        $r.online = "True"; $r.status = "OK"

        $cHtml = Get-WebPage "http://$ip/web/guest/ko/websys/status/getUnificationCounter.cgi"
        if ($cHtml -and $cHtml.Length -gt 500) {
            $tdNums = [regex]::Matches($cHtml, '<td nowrap>(\d+)</td>')
            $vals = @(); foreach ($m in $tdNums) { $vals += [int]$m.Groups[1].Value }
            if ($vals.Count -ge 10) {
                $r.bw    = $vals[1] + $vals[5] + $vals[9]
                $r.color = $vals[2] + $vals[6] + $vals[7] + $vals[8]
            }
        }

        $sHtml = Get-WebPage "http://$ip/web/guest/ko/websys/webArch/getStatus.cgi"
        if ($sHtml -and $sHtml.Length -gt 500) {
            $kM = [regex]::Match($sHtml, 'deviceStTnBarK\.gif[^>]+width="(\d+)"')
            $cM = [regex]::Match($sHtml, 'deviceStTnBarC\.gif[^>]+width="(\d+)"')
            $mM = [regex]::Match($sHtml, 'deviceStTnBarM\.gif[^>]+width="(\d+)"')
            $yM = [regex]::Match($sHtml, 'deviceStTnBarY\.gif[^>]+width="(\d+)"')
            $maxWidth = 130
            $allW = @()
            if ($kM.Success) { $allW += [int]$kM.Groups[1].Value }
            if ($cM.Success) { $allW += [int]$cM.Groups[1].Value }
            if ($mM.Success) { $allW += [int]$mM.Groups[1].Value }
            if ($yM.Success) { $allW += [int]$yM.Groups[1].Value }
            if ($allW.Count -gt 0) {
                $dMax = ($allW | Measure-Object -Maximum).Maximum
                if ($dMax -gt 130) { $maxWidth = $dMax }
            }
            if ($kM.Success) { $r.tk = [math]::Min(100,[math]::Max(1,[math]::Round([int]$kM.Groups[1].Value/$maxWidth*100))) }
            if ($cM.Success) { $r.tc = [math]::Min(100,[math]::Max(1,[math]::Round([int]$cM.Groups[1].Value/$maxWidth*100))) }
            if ($mM.Success) { $r.tm = [math]::Min(100,[math]::Max(1,[math]::Round([int]$mM.Groups[1].Value/$maxWidth*100))) }
            if ($yM.Success) { $r.ty = [math]::Min(100,[math]::Max(1,[math]::Round([int]$yM.Groups[1].Value/$maxWidth*100))) }
        }
    } catch { Write-Host "  Ricoh err: $_" }
    return $r
}

# ============================================================
# HP 수집
# ============================================================
function Get-HPData([string]$ip) {
    $r = @{ bw=0; color=0; tk=0; tc=0; tm=0; ty=0; online="False"; status="Offline" }
    try {
        if (-not (Get-WebPage "http://$ip/")) { return $r }
        $r.online = "True"; $r.status = "OK"
        $xml = Get-WebPage "http://$ip/DevMgmt/ProductUsageDyn.xml"
        if ($xml) {
            if ($xml -match 'TotalImpressions[^>]*>\s*(\d+)') { $r.bw    = [int]$matches[1] }
            if ($xml -match 'ColorImpressions[^>]*>\s*(\d+)') { $r.color = [int]$matches[1] }
        }
        $inkXml = Get-WebPage "http://$ip/DevMgmt/ConsumableConfigDyn.xml"
        if ($inkXml) {
            $inkM = [regex]::Matches($inkXml, 'PercentageLevelRemaining[^>]*>\s*(\d+)')
            if ($inkM.Count -ge 1) { $r.tk = [int]$inkM[0].Groups[1].Value }
            if ($inkM.Count -ge 2) { $r.tc = [int]$inkM[1].Groups[1].Value }
            if ($inkM.Count -ge 3) { $r.tm = [int]$inkM[2].Groups[1].Value }
            if ($inkM.Count -ge 4) { $r.ty = [int]$inkM[3].Groups[1].Value }
        }
    } catch { Write-Host "  HP err: $_" }
    return $r
}

# ============================================================
# 교세라 수집 (HTTP 카운터 + SNMP 토너)
# ============================================================
function Get-KyoceraData([string]$ip) {
    $r = @{ bw=0; color=0; tk=-1; tc=-1; tm=-1; ty=-1; online="False"; status="Offline" }
    try {
        $snmpBw = Get-SNMP $ip @(1,3,6,1,2,1,43,10,2,1,4,1,1)
        if ($null -eq $snmpBw) { return $r }
        $r.online = "True"; $r.status = "OK"

        $kyoCookie  = "rtl=0; css=1"
        $kyoReferer = "https://$ip/startwlm/Start_Wlm.htm"
        $prnUrl     = "https://$ip/js/jssrc/model/dvcinfo/dvccounter/DvcInfo_Counter_PrnCounter.model.htm"
        $prnHtml    = Get-WebPage $prnUrl 10 $kyoCookie $kyoReferer

        if ($prnHtml -and $prnHtml.Length -gt 100) {
            $copyBW = 0; $printBW = 0
            if ($prnHtml -match "copyBlackWhite\s*=\s*\('(\d+)'\)")    { $copyBW  = [int]$matches[1] }
            if ($prnHtml -match "printerBlackWhite\s*=\s*\('(\d+)'\)") { $printBW = [int]$matches[1] }
            $r.bw = $copyBW + $printBW
            Write-Host "  Counter: copy=$copyBW print=$printBW total=$($r.bw)"
        } else {
            $r.bw = [int]$snmpBw
            Write-Host "  SNMP Counter (scan included): $($r.bw)"
        }

        $tkMax = Get-SNMP $ip @(1,3,6,1,2,1,43,11,1,1,8,1,1)
        $tkCur = Get-SNMP $ip @(1,3,6,1,2,1,43,11,1,1,9,1,1)
        $r.tk  = Get-TonerPct $tkCur $tkMax
    } catch { Write-Host "  Kyocera err: $_" }
    return $r
}

# ============================================================
# 캐논 수집
# ============================================================
function Get-CanonData([string]$ip) {
    $r = @{ bw=0; color=0; tk=-1; tc=-1; tm=-1; ty=-1; online="False"; status="Offline" }
    try {
        $html = $null
        foreach ($u in @("http://$ip/portal_top.html","http://$ip/","http://$ip/index.html")) {
            $html = Get-WebPage $u; if ($html) { break }
        }
        if (-not $html) { return $r }
        $r.online = "True"; $r.status = "OK"

        foreach ($u in @("http://$ip/countertop.html","http://$ip/counter.html")) {
            $ch = Get-WebPage $u
            if ($ch) {
                $nums = [regex]::Matches($ch, '(\d[\d,]{2,})')
                $found = @()
                foreach ($m in $nums) { $v=[int]($m.Groups[1].Value -replace ',',''); if($v -gt 0){$found+=$v} }
                if ($found.Count -ge 1) { $r.bw    = $found[0] }
                if ($found.Count -ge 2) { $r.color = $found[1] }
                break
            }
        }
    } catch { Write-Host "  Canon err: $_" }
    return $r
}

# ============================================================
# 메인 실행
# ============================================================
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$dt = Get-Date -Format "yyyy-MM-dd"
$tm = Get-Date -Format "HH:mm"

Write-Host "=== Printer Monitor v15.0 ==="
Write-Host "=== $ts ==="
Write-Host ""

# 내 IP에 해당하는 거래처만 로드
Write-Host "[임대관리 연동] 거래처 정보 로드 중..."
$PRINTERS = Load-MyPrinters $MY_PRINTER_IPS

if ($PRINTERS.Count -eq 0) {
    Write-Host ""
    Write-Host "수집할 프린터가 없습니다." -ForegroundColor Yellow
    Write-Host "MY_PRINTER_IPS 를 확인해 주세요." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press any key..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

Write-Host ""

# ────────────────────────────────────────
# 온라인 상태만 갱신 모드 (30분마다)
# ────────────────────────────────────────
if ($Mode -eq "online") {
    Write-Host "[Online Status Check]" -ForegroundColor Cyan
    foreach ($p in $PRINTERS) {
        Write-Host "  [$($p.name)] $($p.ip)" -NoNewline
        $ping = Test-Connection -ComputerName $p.ip -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($ping) {
            Write-Host " [Online]" -ForegroundColor Green
            # 온라인 확인 시간 기록
            $chkData = @{
                fields = @{
                    is_online  = @{ stringValue = "True" }
                    last_seen  = @{ stringValue = $ts }
                    is_checked = @{ stringValue = "True" }
                }
            }
            $patchUrl = "$FIREBASE_URL/device_$($p.no)?key=$FIREBASE_API_KEY&updateMask.fieldPaths=is_online&updateMask.fieldPaths=last_seen&updateMask.fieldPaths=is_checked"
            try {
                $chkData | ConvertTo-Json -Depth 10 | Invoke-RestMethod -Uri $patchUrl -Method Patch -ContentType "application/json; charset=utf-8" -ErrorAction Stop | Out-Null
            } catch {}
        } else {
            Write-Host " [Offline]" -ForegroundColor Red
            # Ping 실패시 is_online False 업데이트
            $offData = @{ fields = @{
                is_online = @{ stringValue = "False" }
                last_seen = @{ stringValue = $ts }
            }}
            $offUrl = "$FIREBASE_URL/device_$($p.no)?key=$FIREBASE_API_KEY&updateMask.fieldPaths=is_online&updateMask.fieldPaths=last_seen"
            try { $offData | ConvertTo-Json -Depth 10 | Invoke-RestMethod -Uri $offUrl -Method Patch -ContentType "application/json; charset=utf-8" -ErrorAction Stop | Out-Null } catch {}
        }
    }
    Write-Host ""
    Write-Host "=== Online Check Done ==="
    exit
}

# ────────────────────────────────────────
# 전체 수집 모드 (PC시작 30분후 + 오후4시)
# ────────────────────────────────────────
foreach ($p in $PRINTERS) {
    Write-Host "[$($p.name)] $($p.ip)"
    switch ($p.type) {
        "ricoh"   { $info = Get-RicohData   $p.ip }
        "hp"      { $info = Get-HPData      $p.ip }
        "canon"   { $info = Get-CanonData   $p.ip }
        "kyocera" { $info = Get-KyoceraData $p.ip }
        default   { $info = Get-RicohData   $p.ip }
    }

    Write-Host "  Online : $($info.online)"
    Write-Host "  BW     : $($info.bw)"
    Write-Host "  Color  : $($info.color)"
    Write-Host "  Toner  : K=$($info.tk)% C=$($info.tc)% M=$($info.tm)% Y=$($info.ty)%"

    # 오프라인이면 최대 3회 재시도 (30초 간격) - 기존 Firebase 값 보호
    if ($info.online -eq "False") {
        $retryOk = $false
        for ($retry = 1; $retry -le 3; $retry++) {
            Write-Host "  [RETRY $retry/3] Offline - Waiting 30 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            switch ($p.type) {
                "ricoh"   { $info = Get-RicohData   $p.ip }
                "hp"      { $info = Get-HPData      $p.ip }
                "canon"   { $info = Get-CanonData   $p.ip }
                "kyocera" { $info = Get-KyoceraData $p.ip }
                default   { $info = Get-RicohData   $p.ip }
            }
            if ($info.online -eq "True") {
                Write-Host "  [OK] Back online after retry $retry!" -ForegroundColor Green
                $retryOk = $true
                break
            }
        }
        if (-not $retryOk) {
            Write-Host "  [SKIP] Still offline after 3 retries - Firebase not updated" -ForegroundColor Red
            Write-Host ""
            continue
        }
    }

    # bw=0이면 수집 실패로 간주하여 SKIP
    if ([int]$info.bw -eq 0) {
        Write-Host "  [SKIP] BW=0 - Possible collection error, Firebase not updated" -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    $data = @{
        name         = "$($p.name)"
        model        = "$($p.model)"
        ip           = "$($p.ip)"
        printer_type = "$($p.type)"
        is_online    = "True"
        status       = "OK"
        bw_count     = [int]$info.bw
        color_count  = [int]$info.color
        toner_k      = [int]$info.tk
        toner_c      = [int]$info.tc
        toner_m      = [int]$info.tm
        toner_y      = [int]$info.ty
        collected_at = "$ts"
        date         = "$dt"
        time         = "$tm"
    }

    $ok  = Save-Firebase "device_$($p.no)" $data
    Save-Firebase "hist_$($p.no)_$($dt -replace '-','')_$($tm -replace ':','')" $data | Out-Null

    if ($ok) { Write-Host "  Firebase: OK" -ForegroundColor Green }
    else      { Write-Host "  Firebase: FAIL" -ForegroundColor Red }
    Write-Host ""
}

Write-Host "=== Done: $ts ==="
Write-Host ""
Write-Host "Press any key..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
