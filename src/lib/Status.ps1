# 패널에 보여 줄 갈래별 '지금 상태' 한 줄 (예: 소리 · 음소거).
# 패널이 멈추지 않게 따로 돌리는 PowerShell에서 1분마다 읽기만 한다. PC를 바꾸지 않는다.
#   Level: ok(초록) | warn(주황) | bad(빨강) | info(회색)

$script:StatusScript = {
    param([string]$TvPattern, [string]$VirtualPattern)
    $out = @{}
    function Put([string]$Key, [string]$Text, [string]$Level) { $out[$Key] = @{ Text = $Text; Level = $Level } }

    try {
        $n = @([System.Windows.Forms.Screen]::AllScreens).Count
        $mode = switch ([PcHelper.Display]::Topology()) { 2 { ' · 복제' } 4 { ' · 확장' } default { '' } }
        Put 'display' "화면 $($n)대$mode" 'ok'
    } catch { }

    try {
        $d = [PcHelper.Touch]::Digitizer()
        if (($d -band 0x80) -and ($d -band 0x3)) { Put 'touch' '터치 인식됨' 'ok' } else { Put 'touch' '터치 장치 없음' 'info' }
    } catch { }

    try {
        $def = [PcHelper.Audio]::Outputs() | Where-Object IsDefault | Select-Object -First 1
        if (-not $def) { Put 'audio' '소리 장치 없음' 'bad' }
        else {
            $where = if ($def.Name -match $TvPattern) { 'TV' } else { '스피커' }
            $vol = [math]::Round([PcHelper.Audio]::GetVolume() * 100)
            if ([PcHelper.Audio]::GetMute()) { Put 'audio' "$where · 음소거" 'warn' }
            elseif ($vol -lt 5) { Put 'audio' "$where · 볼륨 0" 'warn' }
            else { Put 'audio' "$where · 볼륨 $vol" 'ok' }
        }
    } catch { }

    try {
        $p = Get-CimInstance Win32_Printer -Filter 'Default=TRUE' -ErrorAction Stop | Select-Object -First 1
        if (-not $p) { Put 'print' '기본 프린터 없음' 'warn' }
        elseif ($p.Name -match $VirtualPattern) { Put 'print' '기본이 PDF로 돼 있음' 'warn' }
        else {
            $e = [int]$p.DetectedErrorState
            $jobs = @(Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$($p.Name),*" }).Count
            if ($e -eq 8) { Put 'print' '용지 걸림' 'bad' }
            elseif ($e -eq 4) { Put 'print' '용지 없음' 'bad' }
            elseif ($e -eq 7) { Put 'print' '덮개 열림' 'bad' }
            elseif ($e -eq 9 -or $p.WorkOffline -or $p.PrinterStatus -eq 7) { Put 'print' '프린터 꺼짐' 'bad' }
            elseif ($e -in 5, 6) { Put 'print' '토너 부족' 'warn' }
            elseif ($jobs -gt 0) { Put 'print' "인쇄 대기 $($jobs)건" 'warn' }
            else { Put 'print' '준비됨' 'ok' }
        }
    } catch { }

    try {
        # 윈도우가 판단한 인터넷 연결. 학교 필터가 윈도우 확인 주소를 막을 수 있어 아니라고 하면 한 번 더 확인한다.
        $nlm = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'))
        $online = [bool]$nlm.IsConnectedToInternet
        if (-not $online) {
            $c = New-Object System.Net.Sockets.TcpClient
            try { $online = $c.ConnectAsync('www.naver.com', 443).Wait(2000) -and $c.Connected } catch { } finally { $c.Dispose() }
        }
        if ($online) { Put 'net' '연결됨' 'ok' }
        else {
            $up = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
                $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -in 'Ethernet', 'Wireless80211' })
            if ($up.Count -gt 0) { Put 'net' '인터넷 안 됨' 'bad' } else { Put 'net' '랜선 빠짐' 'bad' }
        }
    } catch { }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $days = [int][math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)
        $mem = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
        if ($days -ge 3) { Put 'pc' "$($days)일째 다시 시작 안 함" 'warn' }
        elseif ($mem -ge 90) { Put 'pc' "메모리 $mem% 사용" 'warn' }
        else { Put 'pc' "메모리 $mem% 사용" 'ok' }
    } catch { }

    try {
        $parts = @()
        if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue).ProductReleaseIds) { $parts += '오피스' }
        $keys = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        if (Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '한컴|Hancom' }) { $parts += '한글' }
        if ($parts.Count -gt 0) { Put 'app' "$($parts -join ' · ') 설치됨" 'info' } else { Put 'app' '오피스·한글 없음' 'info' }
    } catch { }

    $out
}

# 한 번 만들어 둔 PowerShell 공간에서 돌린다. 끝났는지는 Receive-PanelStatus로 확인한다.
$script:StatusRunspace = $null
$script:StatusJob = $null

function Start-PanelStatus {
    if ($script:StatusJob) { return }
    if (-not $script:StatusRunspace) {
        $script:StatusRunspace = [runspacefactory]::CreateRunspace()
        $script:StatusRunspace.Open()
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:StatusRunspace
    [void]$ps.AddScript($script:StatusScript.ToString()).AddArgument($script:TvAudioPattern).AddArgument($script:VirtualPrinterPattern)
    $script:StatusJob = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
}

# 끝났으면 결과(갈래 → 상태)를 돌려주고, 아직이면 $null.
function Receive-PanelStatus {
    $job = $script:StatusJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return $null }
    $script:StatusJob = $null
    try { $r = $job.Ps.EndInvoke($job.Handle) } catch { $r = $null } finally { $job.Ps.Dispose() }
    if ($r -and $r.Count -gt 0) { $r[0] } else { $null }
}
