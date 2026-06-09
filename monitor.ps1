# ================================================
#  프린터 모니터링 PowerShell 스크립트 v1.0
#  Firebase REST API 직접 전송
# ================================================

# ── Firebase 설정 ────────────────────────────────
$FIREBASE_PROJECT = "rental-management-8c377"
$FIREBASE_API_KEY = "AIzaSyAoEuQ_femEy46c07wIHXY3WykfXvqZRgk"
$FIREBASE_URL     = "https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/device_status"
# ────────────────────────────────────────────────

# ── 수집할 프린터 목록 ───────────────────────────
$PRINTERS = @(
    @{ no=1;  name="리코 MP C2004ex";      ip="192.168.10.199"; model="RICOH MP C2004ex"; contract_no=1 },
    @{ no=2;  name="캐논 GX7092";          ip="192.168.10.188"; model="Canon GX7092";     contract_no=2 },
    @{ no=3;  name="HP OFFICEJET PRO 8610"; ip="192.168.10.155"; model="HP OJ Pro 8610";  contract_no=3 }
)
# ────────────────────────────────────────────────

# ── SNMP OID 정의 ────────────────────────────────
# 공통 표준 OID (대부분 프린터 지원)
$OID_BW_COUNTER    = "1.3.6.1.2.1.43.10.2.1.4.1.1"   # 흑백 카운터
$OID_COLOR_COUNTER = "1.3.6.1.2.1.43.10.2.1.4.1.2"   # 컬러 카운터
$OID_TONER_K_MAX   = "1.3.6.1.2.1.43.11.1.1.8.1.1"   # 검정 토너 최대값
$OID_TONER_K_CUR   = "1.3.6.1.2.1.43.11.1.1.9.1.1"   # 검정 토너 현재값
$OID_TONER_C_MAX   = "1.3.6.1.2.1.43.11.1.1.8.1.2"   # 청록 토너 최대값
$OID_TONER_C_CUR   = "1.3.6.1.2.1.43.11.1.1.9.1.2"   # 청록 토너 현재값
$OID_TONER_M_MAX   = "1.3.6.1.2.1.43.11.1.1.8.1.3"   # 자홍 토너 최대값
$OID_TONER_M_CUR   = "1.3.6.1.2.1.43.11.1.1.9.1.3"   # 자홍 토너 현재값
$OID_TONER_Y_MAX   = "1.3.6.1.2.1.43.11.1.1.8.1.4"   # 노랑 토너 최대값
$OID_TONER_Y_CUR   = "1.3.6.1.2.1.43.11.1.1.9.1.4"   # 노랑 토너 현재값
$OID_STATUS        = "1.3.6.1.2.1.25.3.5.1.1.1"       # 프린터 상태
# ────────────────────────────────────────────────

# ── SNMP 값 가져오기 함수 ────────────────────────
function Get-SNMPValue {
    param($ip, $oid)
    try {
        $result = & snmpget -v1 -c public -t 3 -r 1 $ip $oid 2>$null
        if ($result -match "INTEGER:\s*(\d+)") { return [int]$matches[1] }
        if ($result -match "Counter32:\s*(\d+)") { return [int]$matches[1] }
        if ($result -match "Gauge32:\s*(\d+)") { return [int]$matches[1] }
        return $null
    } catch {
        return $null
    }
}

# ── SNMP 없을때 WMI 대체 함수 ───────────────────
function Get-PrinterStatusWMI {
    param($printerName)
    try {
        $printer = Get-WmiObject -Class Win32_Printer | 
                   Where-Object { $_.Name -like "*$printerName*" } |
                   Select-Object -First 1
        if ($printer) {
            return @{
                status = if($printer.PrinterStatus -eq 3){"정상"}else{"확인필요"}
                jobs   = $printer.Jobs
            }
        }
    } catch {}
    return $null
}

# ── 토너 퍼센트 계산 함수 ───────────────────────
function Get-TonerPercent {
    param($current, $max)
    if ($max -and $max -gt 0 -and $current -ne $null) {
        $pct = [math]::Round(($current / $max) * 100)
        return [math]::Max(0, [math]::Min(100, $pct))
    }
    return -1  # 알 수 없음
}

# ── Firebase에 저장하는 함수 ────────────────────
function Save-ToFirebase {
    param($docId, $data)
    
    $url = "$FIREBASE_URL/$docId`?key=$FIREBASE_API_KEY"
    
    # Firestore 형식으로 변환
    $fields = @{}
    foreach ($key in $data.Keys) {
        $val = $data[$key]
        if ($val -is [int] -or $val -is [long]) {
            $fields[$key] = @{ integerValue = $val.ToString() }
        } elseif ($val -is [bool]) {
            $fields[$key] = @{ booleanValue = $val }
        } else {
            $fields[$key] = @{ stringValue = $val.ToString() }
        }
    }
    
    $body = @{ fields = $fields } | ConvertTo-Json -Depth 5
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method Patch `
                    -Body $body -ContentType "application/json; charset=utf-8"
        return $true
    } catch {
        Write-Host "  ⚠ Firebase 저장 오류: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# ── 메인 수집 루프 ───────────────────────────────
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$dateOnly  = Get-Date -Format "yyyy-MM-dd"
$timeOnly  = Get-Date -Format "HH:mm"

Write-Host ""
Write-Host "  수집 시작: $timestamp" -ForegroundColor Cyan
Write-Host ""

foreach ($printer in $PRINTERS) {
    Write-Host "  [$($printer.name)] $($printer.ip) 수집 중..." -ForegroundColor White
    
    # SNMP로 수집 시도
    $bw_count    = Get-SNMPValue $printer.ip $OID_BW_COUNTER
    $color_count = Get-SNMPValue $printer.ip $OID_COLOR_COUNTER
    
    $toner_k_max = Get-SNMPValue $printer.ip $OID_TONER_K_MAX
    $toner_k_cur = Get-SNMPValue $printer.ip $OID_TONER_K_CUR
    $toner_c_max = Get-SNMPValue $printer.ip $OID_TONER_C_MAX
    $toner_c_cur = Get-SNMPValue $printer.ip $OID_TONER_C_CUR
    $toner_m_max = Get-SNMPValue $printer.ip $OID_TONER_M_MAX
    $toner_m_cur = Get-SNMPValue $printer.ip $OID_TONER_M_CUR
    $toner_y_max = Get-SNMPValue $printer.ip $OID_TONER_Y_MAX
    $toner_y_cur = Get-SNMPValue $printer.ip $OID_TONER_Y_CUR
    $status_raw  = Get-SNMPValue $printer.ip $OID_STATUS
    
    # 토너 퍼센트 계산
    $toner_k_pct = Get-TonerPercent $toner_k_cur $toner_k_max
    $toner_c_pct = Get-TonerPercent $toner_c_cur $toner_c_max
    $toner_m_pct = Get-TonerPercent $toner_m_cur $toner_m_max
    $toner_y_pct = Get-TonerPercent $toner_y_cur $toner_y_max
    
    # 상태 텍스트 변환
    $status_text = switch ($status_raw) {
        3  { "정상" }
        4  { "인쇄중" }
        5  { "인쇄중" }
        6  { "용지없음" }
        7  { "오프라인" }
        default { if($bw_count -ne $null){"정상"}else{"연결불가"} }
    }
    
    # 온라인 여부
    $is_online = ($bw_count -ne $null -or $color_count -ne $null)
    
    # 결과 출력
    if ($is_online) {
        Write-Host "    ✅ 연결 성공" -ForegroundColor Green
        if ($bw_count -ne $null)    { Write-Host "    흑백 카운터: $($bw_count.ToString('N0'))매" }
        if ($color_count -ne $null) { Write-Host "    컬러 카운터: $($color_count.ToString('N0'))매" }
        if ($toner_k_pct -ge 0)     { Write-Host "    토너(K): $toner_k_pct%" }
        if ($toner_c_pct -ge 0)     { Write-Host "    토너(C): $toner_c_pct%" }
    } else {
        Write-Host "    ⚠ 연결 실패 (오프라인 또는 SNMP 비활성)" -ForegroundColor Yellow
    }
    
    # Firebase에 저장할 데이터
    $data = @{
        name         = $printer.name
        model        = $printer.model
        ip           = $printer.ip
        contract_no  = $printer.contract_no
        status       = $status_text
        is_online    = $is_online.ToString()
        bw_count     = if($bw_count -ne $null){$bw_count}else{0}
        color_count  = if($color_count -ne $null){$color_count}else{0}
        toner_k      = if($toner_k_pct -ge 0){$toner_k_pct}else{-1}
        toner_c      = if($toner_c_pct -ge 0){$toner_c_pct}else{-1}
        toner_m      = if($toner_m_pct -ge 0){$toner_m_pct}else{-1}
        toner_y      = if($toner_y_pct -ge 0){$toner_y_pct}else{-1}
        collected_at = $timestamp
        date         = $dateOnly
        time         = $timeOnly
    }
    
    # Firebase 저장
    $docId  = "device_$($printer.no)"
    $saved  = Save-ToFirebase $docId $data
    
    if ($saved) {
        Write-Host "    💾 Firebase 저장 완료" -ForegroundColor Green
    }
    
    # 일별 히스토리 저장 (날짜별 기록)
    $histId = "hist_$($printer.no)_$($dateOnly -replace '-','')"
    Save-ToFirebase $histId $data | Out-Null
    
    Write-Host ""
}

Write-Host "  ✅ 전체 수집 완료: $timestamp" -ForegroundColor Cyan
Write-Host ""
