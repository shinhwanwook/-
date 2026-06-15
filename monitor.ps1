$FIREBASE_PROJECT = "rental-management-8c377"
$FIREBASE_API_KEY = "AIzaSyAoEuQ_femEy46c07wIHXY3WykfXvqZRgk"
$FIREBASE_URL     = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/device_status"
$RENTAL_URL       = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/rental/main"

# ================================================================
#  프린터 목록을 임대관리시스템 Firebase에서 자동으로 읽어옵니다
#  메모장 수정 불필요! 임대관리에 IP 등록하면 자동 적용됩니다.
# ================================================================

function Load-PrintersFromFirebase {
    try {
        $url = "$RENTAL_URL`?key=$FIREBASE_API_KEY"
        $res = Invoke-RestMethod -Uri $url -Method Get
        $contracts = $res.fields.CONTRACTS.arrayValue.values

        $list = @()
        $maxNo = 0

        # 기존 device_status 번호 확인 (중복 방지)
        $devUrl = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/device_status`?key=$FIREBASE_API_KEY&pageSize=100"
        $existingIps = @{}
        try {
            $devRes = Invoke-RestMethod -Uri $devUrl -Method Get
            if ($devRes.documents) {
                foreach ($doc in $devRes.documents) {
                    $docName = $doc.name.Split('/')[-1]
                    if ($docName -match '^device_(\d+)$') {
                        $n = [int]$matches[1]
                        if ($n -gt $maxNo) { $maxNo = $n }
                        $ip = $doc.fields.ip.stringValue
                        if ($ip) { $existingIps[$ip] = $n }
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

            # 이미 등록된 IP면 기존 번호 사용, 없으면 새 번호
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
            Write-Host "  [경고] 임대관리에 IP 등록된 거래처가 없습니다." -ForegroundColor Yellow
            Write-Host "  임대관리시스템 -> 신규등록/수정 -> IP 주소 입력 후 저장해 주세요." -ForegroundColor Yellow
        } else {
            Write-Host "  임대관리에서 $($list.Count)개 거래처 로드완료" -ForegroundColor Green
        }
        return $list
    } catch {
        Write-Host "  [오류] 임대관리 데이터 로드 실패: $_" -ForegroundColor Red
        return @()
    }
}


# =============================================
# 공통 함수
# =============================================

# HTTP 요청
function Get-WebPage([string]$url, [int]$timeout=10, [string]$cookie="", [string]$referer="") {
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
        $sr = New-Object System.IO.StreamReader($res.GetResponseStream())
        $html = $sr.ReadToEnd()
        $sr.Close(); $res.Close()
        return $html
    } catch { return $null }
}

# SNMP 함수 (교세라용)
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

# Firebase 저장
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

# =============================================
# 리코 - HTTP 방식
# =============================================
function Get-RicohData([string]$ip) {
    $r = @{ bw=0; color=0; tk=-1; tc=-1; tm=-1; ty=-1; online="False"; status="Offline" }
    try {
        if (-not (Get-WebPage "http://$ip/")) { return $r }
        $r.online = "True"; $r.status = "OK"

        # 카운터
        $cHtml = Get-WebPage "http://$ip/web/guest/ko/websys/status/getUnificationCounter.cgi"
        if ($cHtml -and $cHtml.Length -gt 500) {
            $tdNums = [regex]::Matches($cHtml, '<td nowrap>(\d+)</td>')
            $vals = @(); foreach ($m in $tdNums) { $vals += [int]$m.Groups[1].Value }
            if ($vals.Count -ge 10) {
                $r.bw    = $vals[1] + $vals[5] + $vals[9]
                $r.color = $vals[2] + $vals[6] + $vals[7] + $vals[8]
            }
        }

        # 토너
        $sHtml = Get-WebPage "http://$ip/web/guest/ko/websys/webArch/getStatus.cgi"
        if ($sHtml -and $sHtml.Length -gt 500) {
            $kM = [regex]::Match($sHtml, 'deviceStTnBarK\.gif[^>]+width="(\d+)"')
            $cM = [regex]::Match($sHtml, 'deviceStTnBarC\.gif[^>]+width="(\d+)"')
            $mM = [regex]::Match($sHtml, 'deviceStTnBarM\.gif[^>]+width="(\d+)"')
            $yM = [regex]::Match($sHtml, 'deviceStTnBarY\.gif[^>]+width="(\d+)"')
            # 최대 width 값으로 기준값 자동 감지
            $maxWidth = 130
            $allWidths = @()
            if ($kM.Success) { $allWidths += [int]$kM.Groups[1].Value }
            if ($cM.Success) { $allWidths += [int]$cM.Groups[1].Value }
            if ($mM.Success) { $allWidths += [int]$mM.Groups[1].Value }
            if ($yM.Success) { $allWidths += [int]$yM.Groups[1].Value }
            if ($allWidths.Count -gt 0) {
                $detectedMax = ($allWidths | Measure-Object -Maximum).Maximum
                # 최대값이 130보다 크면 그 값을 기준으로 사용
                if ($detectedMax -gt 130) { $maxWidth = $detectedMax }
            }
            if ($kM.Success) { $r.tk = [math]::Min(100,[math]::Max(1,[math]::Round([int]$kM.Groups[1].Value/$maxWidth*100))) }
            if ($cM.Success) { $r.tc = [math]::Min(100,[math]::Max(1,[math]::Round([int]$cM.Groups[1].Value/$maxWidth*100))) }
            if ($mM.Success) { $r.tm = [math]::Min(100,[math]::Max(1,[math]::Round([int]$mM.Groups[1].Value/$maxWidth*100))) }
            if ($yM.Success) { $r.ty = [math]::Min(100,[math]::Max(1,[math]::Round([int]$yM.Groups[1].Value/$maxWidth*100))) }
        }
    } catch { Write-Host "  Ricoh err: $_" }
    return $r
}

# =============================================
# HP - HTTP XML 방식
# =============================================
function Get-HPData([string]$ip) {
    $r = @{ bw=0; color=0; tk=0; tc=0; tm=0; ty=0; online="False"; status="Offline" }
    try {
        if (-not (Get-WebPage "http://$ip/")) { return $r }
        $r.online = "True"; $r.status = "OK"

        # 카운터
        $xml = Get-WebPage "http://$ip/DevMgmt/ProductUsageDyn.xml"
        if ($xml) {
            if ($xml -match 'TotalImpressions[^>]*>\s*(\d+)') { $r.bw = [int]$matches[1] }
            if ($xml -match 'ColorImpressions[^>]*>\s*(\d+)') { $r.color = [int]$matches[1] }
        }

        # 잉크 (리필 잉크 = 0%)
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

# =============================================
# 캐논 - HTTP 방식
# =============================================
function Get-CanonData([string]$ip) {
    $r = @{ bw=0; color=0; tk=-1; tc=-1; tm=-1; ty=-1; online="False"; status="Offline" }
    try {
        $urls = @("http://$ip/portal_top.html","http://$ip/","http://$ip/index.html")
        $html = $null
        foreach ($u in $urls) { $html = Get-WebPage $u; if ($html) { break } }
        if (-not $html) { return $r }
        $r.online = "True"; $r.status = "OK"

        $curls = @("http://$ip/countertop.html","http://$ip/counter.html","http://$ip/status_counter.html")
        foreach ($u in $curls) {
            $ch = Get-WebPage $u
            if ($ch) {
                $nums = [regex]::Matches($ch, '(\d[\d,]{2,})')
                $found = @()
                foreach ($m in $nums) { $v=[int]($m.Groups[1].Value -replace ',',''); if($v -gt 0){$found+=$v} }
                if ($found.Count -ge 1) { $r.bw = $found[0] }
                if ($found.Count -ge 2) { $r.color = $found[1] }
                break
            }
        }

        $turls = @("http://$ip/consumables.html","http://$ip/inkinfo.html","http://$ip/status_ink.html")
        foreach ($u in $turls) {
            $th = Get-WebPage $u
            if ($th) {
                $pm = [regex]::Matches($th, '(\d+)\s*%')
                if ($pm.Count -ge 1) { $r.tk = [int]$pm[0].Groups[1].Value }
                if ($pm.Count -ge 2) { $r.tc = [int]$pm[1].Groups[1].Value }
                if ($pm.Count -ge 3) { $r.tm = [int]$pm[2].Groups[1].Value }
                if ($pm.Count -ge 4) { $r.ty = [int]$pm[3].Groups[1].Value }
                if ($r.tk -gt 0) { break }
            }
        }
    } catch { Write-Host "  Canon err: $_" }
    return $r
}

# =============================================
# 교세라 - SNMP(온라인/토너) + HTTP(카운터) 혼합 방식
# =============================================
function Get-KyoceraData([string]$ip) {
    $r = @{ bw=0; color=0; tk=-1; tc=-1; tm=-1; ty=-1; online="False"; status="Offline" }
    try {
        # 온라인 확인 - SNMP
        $snmpTotal = Get-SNMP $ip @(1,3,6,1,2,1,43,10,2,1,4,1,1)
        if ($null -eq $snmpTotal) { return $r }
        $r.online = "True"
        $r.status = "OK"

        # 카운터 - HTTP 쿠키 방식 (rtl=0; css=1)
        $kyoCookie = "rtl=0; css=1"
        $prnUrl  = "https://$ip/js/jssrc/model/dvcinfo/dvccounter/DvcInfo_Counter_PrnCounter.model.htm"
        $scanUrl = "https://$ip/js/jssrc/model/dvcinfo/dvccounter/DvcInfo_Counter_ScanCounter.model.htm"

        $kyoReferer = "https://$ip/startwlm/Start_Wlm.htm"
        $prnHtml  = Get-WebPage $prnUrl 10 $kyoCookie $kyoReferer
        $scanHtml = Get-WebPage $scanUrl 10 $kyoCookie $kyoReferer

        if ($prnHtml -and $prnHtml.Length -gt 100) {
            # copyBlackWhite + printerBlackWhite
            $copyBW = 0; $printBW = 0
            if ($prnHtml -match "copyBlackWhite\s*=\s*\('(\d+)'\)")    { $copyBW  = [int]$matches[1] }
            if ($prnHtml -match "printerBlackWhite\s*=\s*\('(\d+)'\)") { $printBW = [int]$matches[1] }
            $r.bw = $copyBW + $printBW
            Write-Host "  HTTP Counter: copy=$copyBW print=$printBW total=$($r.bw)"
        } else {
            # HTTP 실패시 SNMP 값 사용 (스캔 포함)
            $r.bw = [int]$snmpTotal
            Write-Host "  SNMP Counter (scan included): $($r.bw)"
        }

        if ($scanHtml -and $scanHtml.Length -gt 100) {
            $scanCopy = 0; $scanOther = 0
            if ($scanHtml -match "scanCopy\s*=\s*parseInt\('(\d+)'")  { $scanCopy  = [int]$matches[1] }
            if ($scanHtml -match "scanOther\s*=\s*parseInt\('(\d+)'") { $scanOther = [int]$matches[1] }
            Write-Host "  Scan: copy=$scanCopy other=$scanOther"
        }

        # 토너 - SNMP
        $tkMax = Get-SNMP $ip @(1,3,6,1,2,1,43,11,1,1,8,1,1)
        $tkCur = Get-SNMP $ip @(1,3,6,1,2,1,43,11,1,1,9,1,1)
        $r.tk  = Get-TonerPct $tkCur $tkMax
    } catch { Write-Host "  Kyocera err: $_" }
    return $r
}


# =============================================
# 메인 실행
# =============================================
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$dt = Get-Date -Format "yyyy-MM-dd"
$tm = Get-Date -Format "HH:mm"

Write-Host "=== Printer Monitor v14.0 ==="
Write-Host "=== $ts ==="
Write-Host ""

# 임대관리에서 거래처 목록 자동 로드
$PRINTERS = Load-PrintersFromFirebase

if ($PRINTERS.Count -eq 0) {
    Write-Host "수집할 거래처가 없습니다." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press any key..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

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

    # 오프라인이면 Firebase 현재값 유지 (덮어쓰지 않음)
    if ($info.online -eq "False") {
        Write-Host "  Firebase: SKIP (offline - keeping existing data)" -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    $data = @{
        name         = "$($p.name)"
        model        = "$($p.model)"
        ip           = "$($p.ip)"
        is_online    = "$($info.online)"
        status       = "$($info.status)"
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

    $ok = Save-Firebase "device_$($p.no)" $data
    Save-Firebase "hist_$($p.no)_$($dt -replace '-','')_$($tm -replace ':','')" $data | Out-Null

    if ($ok) { Write-Host "  Firebase: OK" -ForegroundColor Green }
    else      { Write-Host "  Firebase: FAIL" -ForegroundColor Red }
    Write-Host ""
}

Write-Host "=== Done: $ts ==="
Write-Host ""
Write-Host "Press any key..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
