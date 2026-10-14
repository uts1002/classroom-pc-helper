# 증상별 점검 → 판단.
# 모든 Test-* 함수는 PC를 바꾸지 않고 읽기만 한다. 바꾸는 일은 결과에 담긴 Actions 버튼을 눌렀을 때만 한다.
#
# 결과 모양
#   Tone    : ok(정상) | fix(자동으로 고칠 수 있음) | guide(직접 확인할 것) | band(밴드에 올릴 것)
#   Title   : 판단 한 줄
#   Facts   : 점검해서 알아낸 것 (밴드 글에도 들어간다)
#   Steps   : 선생님이 직접 해 볼 순서
#   Actions : @{ Label; Run = { ...; '결과 문구' } } 버튼

function New-Result {
    param([string]$Tone, [string]$Title, [string[]]$Facts = @(), [string[]]$Steps = @(), [object[]]$Actions = @())
    [pscustomobject]@{ Tone = $Tone; Title = $Title; Facts = @($Facts); Steps = @($Steps); Actions = @($Actions) }
}

function New-Action {
    param([string]$Label, [scriptblock]$Run)
    @{ Label = $Label; Run = $Run }
}

function Open-Settings([string]$Page) {
    New-Action '설정 창 열기' ([scriptblock]::Create("Start-Process 'ms-settings:$Page'; '설정 창을 열었어요. 위 순서대로 해 보세요.'"))
}

# ───────────────────────── 소리 ─────────────────────────

$script:TvAudioPattern = 'HDMI|DisplayPort|Display Audio|NVIDIA|AMD High Definition|ATI |Intel\(R\) Display|디스플레이 오디오|\bTV\b'
$script:IgnoreAudioPattern = 'Hands-Free|핸즈프리|Bluetooth|블루투스'

function Get-AudioOutputs {
    foreach ($d in [PcHelper.Audio]::Outputs()) {
        if ($d.Name -match $script:IgnoreAudioPattern) { continue }
        [pscustomobject]@{
            Id = $d.Id; Name = $d.Name; IsDefault = $d.IsDefault
            Plugged = ($d.State -eq 1)
            IsTv = ($d.Name -match $script:TvAudioPattern)
        }
    }
}

function Format-AudioFact($d) {
    $kind = if ($d.IsTv) { 'TV·전자칠판' } else { '교실 스피커 쪽' }
    $state = if (-not $d.Plugged) { '선 빠짐' } elseif ($d.IsDefault) { '지금 여기로 소리가 나감' } else { '연결됨' }
    "$($d.Name)  [$kind, $state]"
}

function Get-VolumeFacts {
    $vol = [math]::Round([PcHelper.Audio]::GetVolume() * 100)
    $mute = [PcHelper.Audio]::GetMute()
    $muteText = if ($mute) { '음소거 켜짐' } else { '음소거 아님' }
    @{ Volume = $vol; Mute = $mute; Fact = "PC 볼륨 $vol, $muteText" }
}

function New-UnmuteAction {
    New-Action '음소거 풀고 볼륨 50으로' {
        [PcHelper.Audio]::SetMute($false)
        if ([PcHelper.Audio]::GetVolume() -lt 0.5) { [PcHelper.Audio]::SetVolume(0.5) }
        Invoke-TestSound
        '음소거를 풀고 볼륨을 올렸어요. 소리가 나는지 들어 보세요.'
    }
}

function New-SwitchAudioAction($device) {
    $id = $device.Id; $name = $device.Name
    New-Action "여기로 소리 보내기: $name" ([scriptblock]::Create(@"
[PcHelper.Audio]::SetDefault('$id')
[PcHelper.Audio]::SetMute(`$false)
Invoke-TestSound
"소리가 나가는 곳을 바꿨어요. 확인 소리가 들리는지 보세요."
"@))
}

function Invoke-TestSound {
    $files = 'Windows Notify System Generic.wav', 'Windows Background.wav', 'tada.wav', 'chimes.wav'
    foreach ($f in $files) {
        $path = Join-Path $env:WINDIR "Media\$f"
        if (Test-Path $path) { (New-Object System.Media.SoundPlayer $path).Play(); return }
    }
}

function Test-AudioTarget {
    param([bool]$WantTv)
    $devices = @(Get-AudioOutputs)
    $facts = @($devices | ForEach-Object { Format-AudioFact $_ })
    $v = Get-VolumeFacts
    $facts += $v.Fact
    $place = if ($WantTv) { 'TV·전자칠판' } else { '교실 스피커' }
    $placeTo = if ($WantTv) { 'TV·전자칠판으로' } else { '교실 스피커로' }

    $targets = @($devices | Where-Object { $_.IsTv -eq $WantTv })
    $current = $targets | Where-Object { $_.IsDefault -and $_.Plugged } | Select-Object -First 1
    $ready = @($targets | Where-Object { $_.Plugged -and -not $_.IsDefault })
    $unplugged = @($targets | Where-Object { -not $_.Plugged })

    if ($current) {
        if ($v.Mute -or $v.Volume -lt 5) {
            return New-Result fix "소리가 $placeTo 나가고 있는데 음소거(또는 볼륨 0)예요." $facts @() @(New-UnmuteAction)
        }
        $steps = if ($WantTv) {
            'TV 리모컨으로 TV 볼륨을 올려 보세요.', 'TV가 음소거(스피커 그림에 X)인지 확인하세요.', '그래도 안 나면 밴드에 올려 주세요.'
        } else {
            '전자교탁(또는 앰프)의 전원이 켜져 있는지 확인하세요.', '앰프·스피커의 볼륨 손잡이를 올려 보세요.', '전자교탁에 PC/TV 소리 선택 버튼이 있으면 PC 쪽으로 맞추세요.', '그래도 안 나면 밴드에 올려 주세요.'
        }
        return New-Result guide "PC는 $placeTo 소리를 잘 보내고 있어요. PC 밖 장비를 확인해 보세요." $facts $steps @(New-Action '확인 소리 내 보기' { Invoke-TestSound; '확인 소리를 냈어요.' })
    }
    if ($ready.Count -gt 0) {
        $actions = @($ready | ForEach-Object { New-SwitchAudioAction $_ })
        return New-Result fix "소리가 $placeTo 가지 않고 다른 곳으로 나가고 있어요." $facts @() $actions
    }
    if ($unplugged.Count -gt 0) {
        $steps = if ($WantTv) {
            'TV(전자칠판)와 본체를 잇는 HDMI 선이 양쪽 다 꽉 꽂혀 있는지 확인하세요.', 'TV 전원이 켜져 있는지 확인하세요.', '다시 점검을 눌러 보세요.'
        } else {
            '본체 뒤의 초록색 소리 단자에 스피커 선이 꽉 꽂혀 있는지 확인하세요.', '앞면 단자에 꽂혀 있다면 뒤쪽 초록색 단자로 옮겨 보세요.', '다시 점검을 눌러 보세요.'
        }
        return New-Result guide "$place 선이 빠져 있다고 나와요." $facts $steps
    }
    $steps = if ($WantTv) {
        'TV(전자칠판)가 켜져 있고 PC 화면이 TV에 나오는지 먼저 확인하세요. 화면이 안 나오면 [화면] 메뉴부터 해 주세요.', '그래도 안 되면 밴드에 올려 주세요.'
    } else {
        '스피커가 USB로 연결되는 방식이면 USB 선을 뺐다가 다시 꽂아 보세요.', '그래도 안 되면 밴드에 올려 주세요.'
    }
    New-Result band "PC가 $place 장치를 찾지 못했어요." $facts $steps
}

function Test-AudioNone {
    $devices = @(Get-AudioOutputs)
    $facts = @($devices | ForEach-Object { Format-AudioFact $_ })
    $v = Get-VolumeFacts
    $facts += $v.Fact
    if ($v.Mute -or $v.Volume -lt 5) {
        return New-Result fix '음소거(또는 볼륨 0)로 되어 있어요.' $facts @() @(New-UnmuteAction)
    }
    $plugged = @($devices | Where-Object { $_.Plugged })
    if ($plugged.Count -eq 0) {
        return New-Result guide '연결된 스피커가 하나도 없다고 나와요.' $facts @('본체 뒤 초록색 단자의 스피커 선, TV와 연결된 HDMI 선을 확인하세요.', '다시 점검을 눌러 보세요.')
    }
    $actions = @($plugged | ForEach-Object { New-SwitchAudioAction $_ })
    New-Result fix '소리를 낼 수 있는 곳이 여러 개예요. 하나씩 눌러서 확인 소리가 나는 곳을 찾아 보세요.' $facts @('버튼을 누르면 그쪽으로 확인 소리가 나요.', '어느 쪽도 소리가 안 나면 앰프·TV 전원과 볼륨을 확인하고, 그래도 안 되면 밴드에 올려 주세요.') $actions
}

function Test-AudioNoise {
    $facts = @(Get-AudioOutputs | ForEach-Object { Format-AudioFact $_ })
    New-Result band '잡음·삐 소리는 대부분 마이크나 앰프 같은 장비 쪽 문제예요.' $facts @(
        '무선 마이크를 꺼 보고 소리가 멈추는지 확인하세요. 멈추면 마이크 쪽 문제예요.',
        '마이크가 스피커 가까이 있으면 멀리 떨어뜨려 보세요. (삐 소리의 흔한 원인)',
        '앰프 볼륨을 조금 줄여 보세요.',
        '그래도 계속 나면 밴드에 올려 주세요. 언제부터, 어떤 소리인지 적어 주면 좋아요.')
}

# ───────────────────────── 화면 ─────────────────────────

function Get-Monitors {
    $list = @()
    try {
        $list = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | Where-Object Active | ForEach-Object {
            $name = (@($_.UserFriendlyName) | Where-Object { $_ } | ForEach-Object { [char]$_ }) -join ''
            # 노트북 화면 등 이름 정보가 없는 모니터는 제조사 코드(예: BOE0A08)로 보여 준다.
            if (-not $name.Trim()) { $name = "이름 없는 화면($(($_.InstanceName -split '\\')[1]))" }
            $name
        })
    } catch { }
    if ($list.Count -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms
        $list = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { '화면' })
    }
    $list
}

function Get-TopologyText([uint32]$t) {
    switch ($t) { 1 { '내 화면만 켜짐' } 2 { '복제 (두 화면이 똑같이 나옴)' } 4 { '확장 (두 화면을 따로 씀)' } 8 { '두 번째 화면만 켜짐' } default { '알 수 없음' } }
}

function Get-DisplayState {
    $monitors = @(Get-Monitors)
    $topology = [PcHelper.Display]::Topology()
    $facts = @("PC가 인식한 화면 $($monitors.Count)대: $($monitors -join ', ')", "지금 방식: $(Get-TopologyText $topology)")
    @{ Count = $monitors.Count; Topology = $topology; Facts = $facts }
}

function New-CloneAction {
    New-Action '두 화면을 똑같이 (복제)' { [void][PcHelper.Display]::Clone(); Start-Sleep -Seconds 3; '복제로 바꿨어요. 두 화면에 같은 화면이 나오는지 보세요.' }
}
function New-ExtendAction {
    New-Action '두 화면을 따로 쓰기 (확장)' { [void][PcHelper.Display]::Extend(); Start-Sleep -Seconds 3; '확장으로 바꿨어요. 학생에게 보여 줄 창은 TV 쪽으로 끌어다 놓으세요.' }
}

function Test-DisplayMissing {
    $s = Get-DisplayState
    if ($s.Count -le 1) {
        return New-Result guide 'PC에 화면이 1대만 연결돼 있어요. 다른 화면은 PC가 못 보고 있어요.' $s.Facts @(
            'TV(전자칠판) 전원이 켜져 있는지 확인하세요.',
            "TV 리모컨의 '입력' 또는 '외부입력' 버튼으로 HDMI를 하나씩 바꿔 보세요. (외부 강사가 다녀간 뒤 자주 바뀌어 있어요)",
            '본체 뒤와 TV 뒤의 HDMI 선이 꽉 꽂혀 있는지 확인하세요.',
            '다시 점검을 눌러 보세요. 그래도 1대면 밴드에 올려 주세요.')
    }
    if ($s.Topology -eq 1 -or $s.Topology -eq 8) {
        return New-Result fix '화면은 연결돼 있는데 한쪽이 꺼진 상태로 설정돼 있어요.' $s.Facts @() @((New-CloneAction), (New-ExtendAction))
    }
    New-Result guide "PC는 화면 $($s.Count)대에 모두 화면을 보내고 있어요. 안 나오는 쪽 TV(모니터)를 확인해 보세요." $s.Facts @(
        "안 나오는 쪽 리모컨의 '입력' 버튼으로 HDMI를 하나씩 바꿔 보세요.",
        '모니터 전원 불이 켜져 있는지 확인하세요.',
        '아래 버튼으로 복제/확장을 바꿔 보는 것도 방법이에요.',
        '그래도 안 나오면 밴드에 올려 주세요.') @((New-CloneAction), (New-ExtendAction))
}

function Test-DisplayMirrored {
    $s = Get-DisplayState
    if ($s.Count -le 1) { return Test-DisplayMissing }
    if ($s.Topology -eq 2) {
        return New-Result fix '지금 복제 상태라 내 화면이 학생 화면에 그대로 나와요.' $s.Facts @() @(New-ExtendAction)
    }
    New-Result guide '이미 두 화면을 따로 쓰는 상태(확장)예요. 주 화면이 TV로 바뀌었을 수 있어요.' $s.Facts @(
        "설정 창에서 내 모니터 그림을 누르세요.",
        "아래쪽 '이 디스플레이를 주 디스플레이로 만들기'에 체크하세요.",
        '창을 옮길 때는 창을 끌어다 놓거나 Win + Shift + 화살표를 누르세요.') @(Open-Settings 'display')
}

function Test-DisplaySame {
    $s = Get-DisplayState
    if ($s.Count -le 1) { return Test-DisplayMissing }
    if ($s.Topology -eq 2) {
        return New-Result guide '이미 복제 상태예요. 두 화면이 똑같이 나와야 정상이에요.' $s.Facts @("한쪽이 안 나오면 [한쪽 화면이 안 나와요]를 눌러 점검해 보세요.")
    }
    New-Result fix '지금은 두 화면을 따로 쓰는 상태예요.' $s.Facts @() @(New-CloneAction)
}

function Test-DisplayScale {
    $s = Get-DisplayState
    New-Result guide '글씨·아이콘 크기는 설정 창에서 바로 되돌릴 수 있어요.' $s.Facts @(
        '설정 창 위쪽에서 크기가 이상한 화면 그림을 누르세요. (모르겠으면 [식별]을 누르면 화면에 번호가 떠요)',
        "'배율' 칸을 눌러 (권장)이라고 적힌 값을 고르세요.",
        "'디스플레이 해상도'도 (권장)으로 되어 있는지 확인하세요.") @(Open-Settings 'display')
}

function Test-DisplayMouse {
    $s = Get-DisplayState
    New-Result guide '마우스가 넘어가는 방향은 설정 창의 화면 그림 위치로 정해져요.' $s.Facts @(
        "설정 창 위쪽의 화면 그림(1, 2)을 실제 놓인 위치대로 끌어서 옮기세요. (예: TV가 왼쪽이면 TV 그림을 왼쪽으로)",
        "어느 그림이 어느 화면인지 모르겠으면 [식별]을 누르세요.",
        "옮긴 뒤 [적용]을 누르세요.") @(Open-Settings 'display')
}

# ───────────────────────── 프린터 ─────────────────────────

$script:VirtualPrinterPattern = 'PDF|XPS|OneNote|Fax|팩스|Hancom|한컴|Send To|Microsoft Print'

function Get-PrinterStateText($p) {
    $e = [int]$p.DetectedErrorState
    $map = @{ 3 = '용지 적음'; 4 = '용지 없음'; 5 = '토너 적음'; 6 = '토너 없음'; 7 = '덮개 열림'; 8 = '용지 걸림'; 9 = '꺼짐(오프라인)'; 10 = '점검 필요'; 11 = '출력함 가득 참' }
    if ($map.ContainsKey($e)) { return $map[$e] }
    if ($p.WorkOffline -or $p.PrinterStatus -eq 7) { return '꺼짐(오프라인)' }
    '이상 없음'
}

function Get-PrinterInfo {
    @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
        $jobs = @(Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Name = $_.Name; Default = [bool]$_.Default
            Virtual = ($_.Name -match $script:VirtualPrinterPattern)
            State = Get-PrinterStateText $_
            Jobs = $jobs.Count
            Raw = $_
        }
    })
}

function Format-PrinterFact($p) {
    $mark = if ($p.Default) { ' (기본 프린터)' } else { '' }
    $jobs = if ($p.Jobs -gt 0) { ", 대기 중인 인쇄 $($p.Jobs)개" } else { '' }
    "$($p.Name)$mark — $($p.State)$jobs"
}

function New-SetDefaultPrinterAction($p) {
    $name = $p.Name -replace "'", "''"
    New-Action "기본 프린터로 정하기: $($p.Name)" ([scriptblock]::Create(@"
# 윈도우가 마지막에 쓴 프린터를 멋대로 기본으로 바꾸는 기능을 끈다.
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord
`$printer = Get-CimInstance Win32_Printer | Where-Object Name -eq '$name'
[void](Invoke-CimMethod -InputObject `$printer -MethodName SetDefaultPrinter)
"기본 프린터를 바꿨어요. 이제 인쇄하면 이 프린터로 나가요."
"@))
}

function New-ClearJobsAction($p) {
    $name = $p.Name -replace "'", "''"
    New-Action '쌓인 인쇄 작업 지우기' ([scriptblock]::Create(@"
Get-PrintJob -PrinterName '$name' -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
`$left = @(Get-PrintJob -PrinterName '$name' -ErrorAction SilentlyContinue).Count
if (`$left -eq 0) { '쌓인 인쇄를 지웠어요. 다시 인쇄해 보세요.' } else { "`$left개는 지우지 못했어요. 프린터를 껐다 켠 뒤 다시 인쇄해 보세요." }
"@))
}

function Get-JamSteps {
    '프린터 전원을 끄세요.',
    '앞·옆·뒤 덮개와 용지함을 모두 열어 걸린 종이를 찾으세요.',
    '종이는 나오는 방향으로 천천히 당겨 빼세요. 찢어진 조각이 남지 않게 확인하세요.',
    '덮개를 모두 닫고 전원을 켜세요.',
    '걸린 종이가 안 보이는데 계속 걸렸다고 뜨면 센서 문제일 수 있어요. 밴드에 올려 주세요.'
}

function Test-PrintFail {
    $printers = Get-PrinterInfo
    $facts = @($printers | ForEach-Object { Format-PrinterFact $_ })
    $real = @($printers | Where-Object { -not $_.Virtual })
    $default = $printers | Where-Object Default | Select-Object -First 1

    if (-not $default -or $default.Virtual) {
        if ($real.Count -eq 0) {
            return New-Result band '이 PC에는 연결된 프린터가 없어요. 새로 연결하려면 업체 도움이 필요해요.' $facts @('밴드에 어느 프린터(교실/연구실)를 연결하고 싶은지 적어 주세요.')
        }
        return New-Result fix '기본 프린터가 실제 프린터가 아니에요(PDF 등). 쓸 프린터를 골라 주세요.' $facts @() @($real | ForEach-Object { New-SetDefaultPrinterAction $_ })
    }
    $actions = @()
    if ($default.Jobs -gt 0) { $actions += New-ClearJobsAction $default }

    switch ($default.State) {
        '용지 걸림' { return New-Result guide '프린터에 종이가 걸렸다고 나와요.' $facts (Get-JamSteps) $actions }
        '용지 없음' { return New-Result guide '프린터에 용지가 없다고 나와요.' $facts @('용지함에 종이를 채우세요.', '종이가 있는데도 없다고 나오면 용지함을 끝까지 밀어 넣어 보세요.', '그래도 계속 나오면 밴드에 올려 주세요.') $actions }
        '덮개 열림' { return New-Result guide '프린터 덮개가 열려 있다고 나와요.' $facts @('앞·옆 덮개와 토너 넣는 곳을 꾹 눌러 닫으세요.', '다시 인쇄해 보세요.') $actions }
        { $_ -in '토너 없음', '토너 적음' } { return New-Result guide '토너(잉크)가 떨어졌거나 얼마 안 남았다고 나와요.' $facts @('여분 토너가 있으면 교체하세요. (연구실 복합기는 하단 보관함에 여분이 있는 경우가 많아요)', '여분이 없으면 밴드에 토너 보충을 요청하세요.') $actions }
        '꺼짐(오프라인)' { return New-Result guide 'PC가 프린터를 찾지 못하고 있어요(오프라인).' $facts @('프린터 전원이 켜져 있는지 확인하세요.', '프린터와 본체를 잇는 USB 선(또는 랜선)이 꽉 꽂혀 있는지 확인하세요.', '프린터를 껐다가 30초 뒤에 켜 보세요.', '다시 점검을 눌러 보세요.') $actions }
    }
    if ($actions.Count -gt 0) {
        return New-Result fix "보내 놓은 인쇄가 $($default.Jobs)개 쌓여 있어요. 막혀 있을 수 있어요." $facts @('지운 뒤에도 안 되면 프린터를 껐다 켜 보세요.') $actions
    }
    New-Result guide 'PC 쪽에서는 문제를 찾지 못했어요.' $facts @(
        "인쇄 창에서 프린터 이름이 '$($default.Name)'인지 확인하세요.",
        '프린터를 껐다가 30초 뒤에 켜고 다시 인쇄해 보세요.',
        '인쇄물이 번지거나 줄이 생기는 건 프린터 부품 문제라 밴드에 사진과 함께 올려 주세요.')
}

function Test-PrintWrong {
    $printers = Get-PrinterInfo
    $facts = @($printers | ForEach-Object { Format-PrinterFact $_ })
    $auto = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction SilentlyContinue).LegacyDefaultPrinterMode -ne 1
    if ($auto) { $facts += "윈도우가 기본 프린터를 자동으로 바꾸는 기능: 켜짐 (다른 프린터로 나가는 흔한 원인)" }
    $real = @($printers | Where-Object { -not $_.Virtual })
    if ($real.Count -eq 0) {
        return New-Result band '이 PC에는 연결된 프린터가 없어요.' $facts @('밴드에 어느 프린터를 연결하고 싶은지 적어 주세요.')
    }
    New-Result fix '우리 반 프린터를 눌러 기본으로 정해 주세요. 자동으로 바뀌는 기능도 함께 꺼요.' $facts @() @($real | ForEach-Object { New-SetDefaultPrinterAction $_ })
}

function Test-PrintJam {
    $printers = Get-PrinterInfo
    $facts = @($printers | ForEach-Object { Format-PrinterFact $_ })
    $default = $printers | Where-Object Default | Select-Object -First 1
    $actions = @()
    if ($default -and $default.Jobs -gt 0) { $actions += New-ClearJobsAction $default }
    $steps = @(Get-JamSteps) + '두꺼운 종이·라벨지는 옆쪽 수동 급지대(손으로 넣는 곳)에 한 장씩 넣으면 덜 걸려요.'
    New-Result guide '걸린 종이는 직접 빼야 해요. 아래 순서대로 해 보세요.' $facts $steps $actions
}

function Test-PrintMissing {
    $printers = Get-PrinterInfo
    $facts = @($printers | ForEach-Object { Format-PrinterFact $_ })
    New-Result band '새 프린터 연결은 드라이버 설치가 필요해서 업체가 해 줘야 해요.' $facts @(
        '목록에 쓰려는 프린터가 있으면 [다른 프린터로 나가요]에서 기본으로 정하면 돼요.',
        "없으면 밴드에 '○○ 프린터(예: 4학년 연구실 복합기) 연결 요청'이라고 올려 주세요. 스캔 폴더도 필요하면 같이 적어 주세요.")
}

# ───────────────────────── 인터넷 ─────────────────────────

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.ConnectAsync($HostName, $Port).Wait($TimeoutMs) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

function Test-NetDown {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $facts = @($adapters | ForEach-Object {
        $kind = if ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|무선') { '무선' } else { '유선(랜선)' }
        $off = if ($kind -eq '무선') { '연결 안 됨' } else { '선 빠짐' }
        $state = if ($_.Status -eq 'Up') { '연결됨' } elseif ($_.Status -eq 'Disconnected') { $off } else { "$($_.Status)" }
        "$kind — $state"
    })
    $up = @($adapters | Where-Object Status -eq 'Up')
    if ($up.Count -eq 0) {
        return New-Result guide '랜선이 빠져 있다고 나와요.' $facts @(
            "본체 뒤 랜선(전화선보다 조금 굵은 선)을 '딸깍' 소리가 나게 다시 꽂으세요.",
            '벽이나 책상 아래 랜선 단자 쪽도 확인하세요.',
            '꽂은 자리 옆에 불이 깜빡이면 연결된 거예요. 다시 점검을 눌러 보세요.')
    }
    $ip = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $up.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' })
    $good = @($ip | Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($good.Count -eq 0) {
        $facts += 'IP 주소: 받지 못함'
        return New-Result band '랜선은 꽂혀 있는데 학교 네트워크에서 주소를 받지 못했어요.' $facts @('PC를 다시 시작해 보세요.', '그래도 안 되면 밴드에 올려 주세요. 교실 네트워크 장비 문제일 수 있어요.')
    }
    $facts += "IP 주소: $($good[0].IPAddress)"
    $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $gwOk = $gateway -and (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue)
    $facts += $(if ($gwOk) { '학교 네트워크 장비: 응답함' } else { '학교 네트워크 장비: 응답 없음' })
    $dnsOk = $false
    try { $dnsOk = [bool](Resolve-DnsName 'www.naver.com' -DnsOnly -ErrorAction Stop | Select-Object -First 1) } catch { }
    $webOk = $dnsOk -and (Test-TcpPort 'www.naver.com' 443)
    $facts += $(if ($webOk) { '바깥 인터넷(네이버): 연결됨' } else { '바깥 인터넷(네이버): 연결 안 됨' })

    if ($webOk) {
        return New-Result guide '이 PC의 인터넷은 정상이에요.' $facts @(
            '브라우저(크롬·엣지·웨일)를 모두 닫았다가 다시 열어 보세요.',
            '특정 사이트만 안 열리면 학교 유해 사이트 차단에 걸렸을 수 있어요. 밴드에 사이트 주소를 적어 올려 주세요.',
            '업무포털·메신저만 안 되면 밴드에 그 내용을 올려 주세요.')
    }
    New-Result band '이 PC는 연결돼 있는데 바깥 인터넷이 안 돼요. 학교(층) 전체 문제일 수 있어요.' $facts @(
        '옆 반도 안 되는지 물어보세요. 같이 안 되면 학교 네트워크 문제예요.',
        '밴드에 올려 주세요. 옆 반도 안 되면 그 내용도 같이 적어 주세요.')
}
