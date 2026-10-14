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

# 학교 안에서 물어볼 사람 (마이크 채널, 인증 코드·제품 키). config.json의 Contact.
function Get-Contact { if ($Config.Contact) { $Config.Contact } else { '정보부장님' } }

# 버튼을 눌렀다가 확인 창에서 [아니요]를 고르면 이 문구를 돌려준다. '해 본 것'에 넣지 않는다.
$script:CancelText = '취소했어요.'

# 관리자 권한이 필요한 일. 윈도우 확인 창(UAC)을 띄우고, 허락받으면 그 안에서 실행한다.
function Invoke-Elevated([string]$Script) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    try {
        $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    } catch {
        throw '관리자 확인 창에서 허락받지 못했어요. 관리자 비밀번호를 물으면 밴드에 올려 주세요.'
    }
    $p.ExitCode
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

function Test-MicNone {
    New-Result guide '무선 마이크는 PC가 아니라 전자교탁(앰프)에 연결돼 있어요. 아래 순서대로 확인해 보세요.' @() @(
        '마이크 전원 스위치가 켜져 있고 불이 들어오는지 보세요.',
        '건전지를 새것으로 바꿔 보세요. 불이 깜빡이거나 빨간색이면 건전지가 거의 없는 거예요.',
        '전자교탁(앰프) 전원이 켜져 있는지, 마이크(MIC) 볼륨 손잡이가 올라가 있는지 보세요.',
        '마이크 신호를 받는 수신기(전자교탁 안이나 옆의 작은 장치)에 불이 들어오는지 보세요.',
        '그래도 안 나면 밴드에 올려 주세요.')
}

function Test-MicCross {
    $contact = Get-Contact
    New-Result guide '다른 반과 마이크 채널(주파수)이 겹쳐서 생기는 일이에요. 교실에서 고칠 수는 없어요.' @() @(
        '어느 반 마이크 소리인지 알아봐 주세요. 들리는 목소리나 시간표로 짐작할 수 있어요.',
        "알게 되면 $($contact)께 메신저로 '○○반 마이크 소리가 우리 반에서 들려요'라고 알려 주세요. 두 반 중 한 곳의 채널을 바꾸면 돼요.",
        '어느 반인지 모르겠으면 밴드에 올려 주세요.')
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

function Format-ModeFact($m) {
    $name = if ($m.Name) { $m.Name } else { '이름 없는 화면(노트북 화면 등)' }
    $best = if ($m.BestWidth -gt 0) { "권장 $($m.BestWidth)×$($m.BestHeight)" } else { '권장 해상도 모름' }
    "$name — 지금 $($m.Width)×$($m.Height), $best"
}

# 흐리게 보일 만큼 권장과 다른가. 4K TV를 1920×1080으로 쓰는 것처럼 비율이 같고
# 충분히 높으면 업체가 일부러 맞춘 것일 수 있어 건드리지 않는다.
function Test-ResolutionOff($m) {
    if ($m.BestWidth -le 0 -or $m.Height -le 0) { return $false }
    $ratioOff = [math]::Abs($m.Width / $m.Height - $m.BestWidth / $m.BestHeight) -gt 0.02
    $tooLow = $m.Width -lt $m.BestWidth -and $m.Width -lt 1920
    $ratioOff -or $tooLow
}

function New-ResolutionAction($m) {
    $label = if ($m.Name) { $m.Name } else { '이름 없는 화면' }
    New-Action "권장 해상도로: $label ($($m.BestWidth)×$($m.BestHeight))" ([scriptblock]::Create(@"
`$r = [PcHelper.Display]::SetResolution('$($m.Source)', $($m.BestWidth), $($m.BestHeight))
if (`$r -ne 0) { throw "이 화면이 그 해상도를 받지 않아요. (코드 `$r)" }
if (-not (Confirm-Keep)) {
    [void][PcHelper.Display]::SetResolution('$($m.Source)', $($m.Width), $($m.Height))
    return '원래 해상도로 되돌렸어요.'
}
'해상도를 바꿨어요. 글씨가 또렷해졌는지 보세요. 글씨가 너무 작으면 [글씨·아이콘이 커졌어요]에서 배율을 맞추세요.'
"@))
}

function Test-DisplaySharp {
    $monitors = @([PcHelper.Display]::Monitors())
    $s = Get-DisplayState
    $facts = @($monitors | ForEach-Object { Format-ModeFact $_ }) + $s.Facts[1]

    # 복제는 화면 두 대가 해상도 하나를 나눠 쓴다. 두 화면 크기가 다르면 한쪽은 흐리거나 비율이 어긋난다.
    $shared = @($monitors | Where-Object Shared)
    $bests = @($shared | ForEach-Object { "$($_.BestWidth)x$($_.BestHeight)" } | Select-Object -Unique)
    if ($bests.Count -gt 1) {
        return New-Result fix '두 화면을 똑같이(복제) 쓰고 있어서 해상도를 하나로 맞추고 있어요. 화면 크기가 달라 한쪽이 흐리거나 비율이 어긋나요.' $facts @(
            '따로 쓰기(확장)로 바꾸면 화면마다 맞는 해상도로 나와요.',
            '두 화면에 똑같이 띄워야 한다면 그대로 두세요. 이때 흐린 건 복제 방식의 한계예요.') @(New-ExtendAction)
    }
    $off = @($monitors | Where-Object { Test-ResolutionOff $_ })
    if ($off.Count -gt 0) {
        return New-Result fix '권장 해상도가 아닌 화면이 있어요. 그래서 글씨가 흐리거나 번지고, 비율이 어긋나 보여요.' $facts @(
            '버튼을 누르면 해상도를 바꾸고, 잘 보이는지 물어봐요. 15초 안에 대답하지 않으면 원래대로 되돌려요.') @($off | ForEach-Object { New-ResolutionAction $_ })
    }
    New-Result guide 'PC는 화면마다 맞는 해상도로 보내고 있어요. 선이나 모니터 쪽을 확인해 보세요.' $facts @(
        '흐린 모니터의 선을 본체 쪽과 모니터 쪽 모두 뺐다가 꽉 다시 꽂아 보세요.',
        "모니터 앞·아래 버튼 중 '메뉴'에 '자동 조정(AUTO)'이 있으면 눌러 보세요.",
        '모니터 선 끝이 파란색 넓적한 단자(RGB)면 원래 조금 흐릴 수 있어요. HDMI 선으로 바꾸고 싶으면 밴드에 올려 주세요.',
        '그래도 번지면 화면 사진과 함께 밴드에 올려 주세요. 선 교체가 필요할 수 있어요.')
}

# ───────────────────────── 터치 ─────────────────────────

$script:TouchPattern = 'touch ?screen|터치 ?스크린'

function Get-TouchState {
    $devices = @(Get-PnpDevice -PresentOnly -Class HIDClass -ErrorAction SilentlyContinue | Where-Object FriendlyName -match $script:TouchPattern)
    $off = @($devices | Where-Object { $_.ConfigManagerErrorCode -eq 22 })
    $digitizer = [PcHelper.Touch]::Digitizer()
    $ready = ($digitizer -band 0x80) -ne 0 -and ($digitizer -band 0x3) -ne 0
    $facts = @()
    if ($devices.Count -eq 0) { $facts += '터치 장치: 찾지 못함' }
    else {
        $facts += "터치 장치: $($devices.Count)개"
        if ($off.Count -gt 0) { $facts += "그중 꺼져 있는 것: $($off.Count)개" }
    }
    $facts += $(if ($ready) { "윈도우 터치: 쓸 수 있음 (동시에 $([PcHelper.Touch]::MaxTouches())곳)" } else { '윈도우 터치: 쓸 수 없음' })
    @{ Count = $devices.Count; Off = $off.Count; On = $devices.Count - $off.Count; Ready = $ready; Facts = $facts }
}

function New-TouchSwitchAction([bool]$TurnOn) {
    $verb = if ($TurnOn) { 'Enable' } else { 'Disable' }
    $label = if ($TurnOn) { '터치 켜기 (관리자 확인 창이 떠요)' } else { '터치 끄기 (관리자 확인 창이 떠요)' }
    $done = if ($TurnOn) { '터치를 켰어요. 화면을 눌러 보세요.' } else { '터치를 껐어요. 다시 켜려면 [터치를 끄고 싶어요 / 켜고 싶어요]에서 켜세요.' }
    $script = "Get-PnpDevice -PresentOnly -Class HIDClass | Where-Object FriendlyName -match '$($script:TouchPattern)' | $verb-PnpDevice -Confirm:`$false"
    New-Action $label ([scriptblock]::Create(@"
[void](Invoke-Elevated @'
$script
'@)
Start-Sleep -Seconds 2
'$done'
"@))
}

function New-TouchMapAction {
    New-Action '터치 화면 맞추기 (관리자 확인 창이 떠요)' {
        try { Start-Process (Join-Path $env:WINDIR 'System32\MultiDigiMon.exe') -ArgumentList '-touch' -ErrorAction Stop }
        catch { throw '관리자 확인 창에서 허락받지 못했어요. 관리자 비밀번호를 물으면 밴드에 올려 주세요.' }
        '터치 화면 맞추기를 열었어요. 화면 안내에 따라 TV(전자칠판)를 한 번 눌러 주세요.'
    }
}

function Get-TouchNotFoundSteps {
    'TV(전자칠판)와 본체는 선 두 개로 이어져 있어요: 화면용 HDMI 선, 터치용 USB 선. 터치용 USB 선이 본체 뒤에 꽉 꽂혀 있는지 보세요.',
    'USB 선을 뺐다가 본체의 다른 USB 단자에 꽂고 10초쯤 기다려 보세요.',
    "TV 메뉴에 '터치 모드'나 '외부 입력 터치' 설정이 있으면 켜져 있는지 보세요.",
    '다시 점검을 눌러 보세요. 그래도 못 찾으면 밴드에 올려 주세요.'
}

function Test-TouchNone {
    $t = Get-TouchState
    if ($t.Count -eq 0 -and -not $t.Ready) {
        return New-Result guide '이 PC가 터치 장치를 찾지 못했어요.' $t.Facts (Get-TouchNotFoundSteps)
    }
    if ($t.Off -gt 0) {
        return New-Result fix '터치가 꺼져 있어요.' $t.Facts @('버튼을 누르고 관리자 확인 창에서 [예]를 누르세요.') @(New-TouchSwitchAction $true)
    }
    $actions = @()
    if ((Get-DisplayState).Count -ge 2) { $actions += New-TouchMapAction }
    New-Result guide '이 PC는 터치 장치를 찾았고 켜져 있어요.' $t.Facts @(
        '터치하면 내 모니터 쪽이 눌리면 아래 [터치 화면 맞추기]를 해 주세요.',
        '화면 테두리(터치 센서가 있는 곳)에 붙은 물건이나 먼지를 치워 보세요.',
        'TV 전원을 껐다가 켜 보세요.',
        '터치는 되는데 판서(펜)만 안 되면 판서 프로그램 문제예요. 밴드에 올려 주세요.') $actions
}

function Test-TouchMap {
    $t = Get-TouchState
    if ($t.Count -eq 0 -and -not $t.Ready) { return Test-TouchNone }
    $s = Get-DisplayState
    $facts = $t.Facts + $s.Facts
    if ($s.Count -lt 2) {
        return New-Result guide 'PC에 화면이 1대만 연결돼 있어요. 터치가 다른 화면으로 갈 수 없는 상태예요.' $facts @('TV가 안 나오면 [화면] 메뉴부터 해 주세요.')
    }
    New-Result fix '윈도우가 터치를 다른 화면의 것으로 알고 있어요. 터치할 화면을 다시 알려 주면 돼요.' $facts @(
        '버튼을 누르고 관리자 확인 창에서 [예]를 누르세요.',
        '화면에 "이 화면을 누르세요"라는 글이 뜨면, 그 글이 TV(전자칠판)에 떠 있을 때 TV를 손가락으로 한 번 누르세요.',
        '글이 내 모니터에 떠 있으면 키보드 Enter를 눌러 다음 화면으로 넘기세요.',
        '끝나면 TV를 눌러 제자리가 눌리는지 확인하세요.') @(New-TouchMapAction)
}

function Test-TouchGhost {
    $t = Get-TouchState
    $actions = @()
    if ($t.On -gt 0) { $actions += New-TouchSwitchAction $false }
    New-Result guide '화면이 저절로 눌리는 건 터치 센서가 무언가를 손가락으로 착각해서예요.' $t.Facts @(
        '화면 테두리에 붙은 자석·종이·지시봉, 화면에 기대 둔 물건을 치우세요.',
        '햇빛이 화면에 바로 비치면 커튼을 쳐 보세요. 강한 햇빛도 터치로 착각해요.',
        "'띵동' 하는 USB 연결 소리가 반복되면 터치용 USB 선이 헐거운 거예요. 본체 뒤 USB 선을 꽉 다시 꽂으세요.",
        '급하면 아래 버튼으로 터치를 잠깐 끄고 수업하세요. 계속되면 밴드에 올려 주세요.') $actions
}

function Test-TouchSwitch {
    $t = Get-TouchState
    if ($t.Count -eq 0) {
        if ($t.Ready) {
            return New-Result band '터치는 되는데 끄고 켤 수 있는 장치를 찾지 못했어요.' $t.Facts @('밴드에 올려 주세요.')
        }
        return New-Result guide '이 PC가 터치 장치를 찾지 못했어요.' $t.Facts (Get-TouchNotFoundSteps)
    }
    $actions = @()
    if ($t.On -gt 0) { $actions += New-TouchSwitchAction $false }
    if ($t.Off -gt 0) { $actions += New-TouchSwitchAction $true }
    $title = if ($t.Off -eq $t.Count) { '지금 터치가 꺼져 있어요.' } elseif ($t.Off -gt 0) { '터치 장치 중 일부만 꺼져 있어요.' } else { '지금 터치가 켜져 있어요.' }
    New-Result fix $title $t.Facts @('버튼을 누르고 관리자 확인 창에서 [예]를 누르세요.') $actions
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
if (`$left -eq 0) { '쌓인 인쇄를 지웠어요. 다시 인쇄해 보세요.' } else { "`$(`$left)개는 지우지 못했어요. 프린터를 껐다 켠 뒤 다시 인쇄해 보세요." }
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

# 스캔은 복합기 주소록과 이 PC의 공유 폴더를 업체가 맞춰 줘야 한다. 여기서는 업체가 볼 정보만 모은다.
function Test-ScanFolder {
    $facts = @("PC 이름: $env:COMPUTERNAME")
    # 실제 랜카드·무선랜만 본다 (가상 네트워크 주소는 업체에 혼란만 준다).
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object ifIndex)
    $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceIndex -in $nics -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress)
    $facts += $(if ($ip.Count -gt 0) { "PC 주소(IP): $($ip -join ', ')" } else { 'PC 주소(IP): 받지 못함' })
    $shares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 0 -and $_.Name -notlike '*$' })
    $facts += $(if ($shares.Count -gt 0) { "공유 폴더: $(($shares | ForEach-Object { "$($_.Name) ($($_.Path))" }) -join ', ')" } else { '공유 폴더: 없음' })
    $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -in $nics -and $_.NetworkCategory -eq 'Public' })
    if ($public.Count -gt 0) { $facts += '네트워크 종류: 공용 (스캔 파일 받기가 막힐 수 있음)' }
    New-Result band '스캔 연결은 복합기와 PC 양쪽을 맞춰야 해서 업체가 해 줘야 해요.' $facts @(
        '복합기 화면의 [스캔] → 보낼 곳 목록에 우리 반 이름이 있는지 보세요. 있으면 골라서 다시 보내 보세요.',
        '최근에 PC 비밀번호를 바꿨다면 밴드 글에 같이 적어 주세요. 비밀번호를 바꾸면 스캔이 끊겨요.',
        '아래 [밴드에 올리기]를 누르면 이 PC 주소와 공유 폴더 정보가 글에 함께 들어가요.')
}

# ───────────────────────── 컴퓨터 (느림·멈춤) ─────────────────────────

function Get-TempFiles([int]$OlderThanDays = 0) {
    $limit = (Get-Date).AddDays(-$OlderThanDays)
    @(Get-ChildItem $env:TEMP -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt $limit)
}

function New-CleanTempAction {
    New-Action '임시 파일 정리하기' {
        if (-not (Confirm-Ask "임시 파일(프로그램이 쓰고 남긴 파일)을 지울까요?`n`n어제 이전에 생긴 것만 지우고, 내 문서·바탕화면·다운로드 파일은 건드리지 않아요.")) { return $script:CancelText }
        $files = Get-TempFiles 1
        $freed = 0
        foreach ($f in $files) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch { }   # 쓰는 중인 파일은 건너뛴다
        }
        Get-ChildItem $env:TEMP -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        "임시 파일 $([math]::Round($freed / 1MB))MB를 정리했어요."
    }
}

function New-RestartAction {
    New-Action 'PC 다시 시작하기' {
        if (-not (Confirm-Ask "PC를 다시 시작할까요?`n`n열려 있는 한글·파워포인트 파일을 먼저 저장해 주세요. 누르고 15초 뒤에 다시 시작해요.")) { return $script:CancelText }
        & shutdown.exe /r /t 15 /c 'PC 도우미가 PC를 다시 시작해요. 저장하지 않은 파일이 있으면 지금 저장하세요.'
        '15초 뒤에 다시 시작해요.'
    }
}

function Test-PcSlow {
    $os = Get-CimInstance Win32_OperatingSystem
    $up = (Get-Date) - $os.LastBootUpTime
    $memPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGb = [math]::Round($disk.FreeSpace / 1GB)
    # 윈도우 내부 항목은 선생님이 닫을 수 있는 프로그램이 아니라서 뺀다.
    $top = @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -notmatch '^(Idle|System|Registry|Secure System|Memory Compression|vmmem.*)$' | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
    } | Sort-Object MB -Descending | Select-Object -First 3)
    $tempMb = [math]::Round(((Get-TempFiles 1) | Measure-Object Length -Sum).Sum / 1MB)

    $facts = @(
        "마지막으로 다시 시작한 지: $([int]$up.TotalDays)일 $($up.Hours)시간",
        "메모리 사용: $memPct%",
        "C 드라이브 남은 공간: $($freeGb)GB / $([math]::Round($disk.Size / 1GB))GB",
        "메모리를 많이 쓰는 프로그램: $(($top | ForEach-Object { "$($_.Name) $($_.MB)MB" }) -join ', ')",
        "정리할 수 있는 임시 파일: $($tempMb)MB")
    $actions = @()
    if ($tempMb -ge 50) { $actions += New-CleanTempAction }
    $actions += New-RestartAction

    if ($freeGb -lt 10) {
        return New-Result band 'C 드라이브 공간이 거의 없어요. 공간이 모자라면 PC가 많이 느려져요.' $facts @(
            '임시 파일을 정리해 보세요.',
            "바탕화면·다운로드 폴더의 큰 동영상 파일을 USB나 클라우드로 옮겨 보세요.",
            '그래도 모자라면 밴드에 올려 주세요.') $actions
    }
    if ($up.TotalDays -ge 3) {
        return New-Result fix "PC를 $([int]$up.TotalDays)일 동안 다시 시작하지 않았어요. 다시 시작하면 대부분 빨라져요." $facts @(
            "윈도우는 '시스템 종료'로 꺼도 완전히 꺼지지 않아요. 가끔은 '다시 시작'을 눌러 주세요.") $actions
    }
    if ($memPct -ge 85) {
        return New-Result fix '메모리를 거의 다 쓰고 있어요. 안 쓰는 프로그램을 닫으면 빨라져요.' $facts @(
            "위 '메모리를 많이 쓰는 프로그램'에서 안 쓰는 것을 닫으세요. 크롬·웨일·엣지는 탭 하나하나가 메모리를 써요.",
            '그래도 느리면 PC를 다시 시작해 보세요.') $actions
    }
    New-Result guide 'PC 상태는 괜찮아 보여요.' $facts @(
        '특정 프로그램(한글, 업무포털 등)만 느리면 그 프로그램 이름을 적어 밴드에 올려 주세요.',
        '켤 때마다 검은 화면에 마우스만 보이거나 파란 화면이 뜨면 밴드에 올려 주세요.') $actions
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

# ───────────────────────── 프로그램 (오피스·한글) ─────────────────────────
# 저장소가 공개라 설치 파일 링크·인증 코드·제품 키는 넣지 않는다. 그건 정보부장님께 묻게 한다.

function Get-OfficeInfo {
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    $ids = if ($c2r) { "$($c2r.ProductReleaseIds)" } else { '' }
    $kind = if ($ids -match 'O365|M365') { 'account' } elseif ($ids -match 'Volume') { 'volume' } elseif ($ids) { 'other' } else { 'none' }
    $name = switch -Regex ($ids) {
        'O365|M365'         { 'Microsoft 365 (가입센터 계정으로 인증)'; break }
        'ProPlus2024Volume' { 'Office 2024 (학교용)'; break }
        'ProPlus2021Volume' { 'Office 2021 (학교용)'; break }
        '.'                 { $ids; break }
        default             { '설치 안 됨' }
    }
    $signedIn = @(Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -ErrorAction SilentlyContinue).Count -gt 0
    $facts = @("오피스: $name")
    if ($kind -eq 'account') { $facts += $(if ($signedIn) { '오피스 로그인: 됨' } else { '오피스 로그인: 안 됨' }) }
    @{ Kind = $kind; Facts = $facts }
}

function Get-HangulName {
    $keys = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '한컴|Hancom' -and $_.DisplayName -match '한글|Hwp|오피스|Office' } |
        ForEach-Object DisplayName | Select-Object -Unique)
}

function New-Office365Action {
    $url = if ($Config.Office365Url) { $Config.Office365Url } else { 'https://o365.sje.go.kr' }
    New-Action '오피스 365 가입센터 열기' ([scriptblock]::Create("Start-Process '$url'; '가입센터를 열었어요. 위 순서대로 해 보세요.'"))
}

function Get-Office365Steps {
    $contact = Get-Contact
    "아래 [오피스 365 가입센터 열기]를 누르세요.",
    "계정이 없으면 [교직원 회원가입]을 누르세요. 가입 인증 코드는 $($contact)께 물어보세요. 학교 이름은 직접 적어 주세요.",
    "가입한 계정으로 [Microsoft 365 로그인] → 왼쪽 아래 [앱] → [Microsoft 365 앱 설치] → [Office 설치]를 누르세요.",
    '받은 설치 파일을 실행하고, 관리자 확인 창이 뜨면 [예]를 누르세요. 설치가 끝날 때까지 창을 닫지 마세요.',
    '엑셀을 열고 가입한 계정으로 로그인하면 인증이 끝나요.'
}

function Test-OfficeLicense {
    $o = Get-OfficeInfo
    $contact = Get-Contact
    switch ($o.Kind) {
        'none' {
            return New-Result guide '이 PC에는 오피스(엑셀·파워포인트)가 설치돼 있지 않아요.' $o.Facts @(Get-Office365Steps) @(New-Office365Action)
        }
        'account' {
            return New-Result guide 'Microsoft 365는 가입센터 계정으로 로그인해야 인증돼요.' $o.Facts @(
                '엑셀을 열고 오른쪽 위 [로그인]을 누르세요.',
                '오피스 365 가입센터에서 만든 계정으로 로그인하세요. 다른 사람 계정이 보이면 [로그아웃] 후 내 계정으로 다시 로그인하세요.',
                "계정이 없으면 아래 버튼으로 가입하세요. 가입 인증 코드는 $($contact)께 물어보세요.",
                '로그인했는데도 인증하라고 뜨면 엑셀을 모두 닫고 다시 열어 보세요. 그래도 안 되면 밴드에 올려 주세요.') @(New-Office365Action)
        }
        'volume' {
            return New-Result guide "학교용 오피스의 인증이 풀렸을 수 있어요. 학교용 인증 방법은 $($contact)께 물어보세요." $o.Facts @(
                "$($contact)께 '오피스 인증이 풀렸어요'라고 알려 주세요. 학교용 설치 파일과 인증 방법을 안내받을 수 있어요.",
                '받은 파일은 C 드라이브 바로 아래처럼 영어로만 된 폴더에 압축을 풀어야 해요. 폴더 이름에 한글이 있으면 실패해요.',
                '배치 파일을 오른쪽 클릭 → [관리자 권한으로 실행]하세요.',
                "개인 계정으로 쓰고 싶으면 오피스 365 가입센터로 바꿀 수도 있어요. 이때는 지금 오피스를 먼저 지워야 해서 $($contact)께 먼저 물어보세요.")
        }
    }
    New-Result band '오피스 종류를 알아내지 못했어요.' $o.Facts @("$($contact)께 묻거나 밴드에 올려 주세요.")
}

function Test-OfficeInstall {
    $o = Get-OfficeInfo
    if ($o.Kind -ne 'none') {
        return New-Result ok '이 PC에는 이미 오피스가 설치돼 있어요.' $o.Facts @(
            '시작 메뉴에서 엑셀·파워포인트를 찾아 열어 보세요.',
            "인증하라고 뜨면 [엑셀·파워포인트가 인증하라고 떠요]를 눌러 주세요.")
    }
    New-Result guide '오피스 365 가입센터에서 직접 설치할 수 있어요.' $o.Facts @(Get-Office365Steps) @(New-Office365Action)
}

function Test-Hangul {
    $names = @(Get-HangulName)
    $contact = Get-Contact
    $facts = @($(if ($names.Count -gt 0) { "한글: $($names -join ', ')" } else { '한글: 설치 안 됨' }))
    if ($names.Count -eq 0) {
        return New-Result guide '이 PC에는 한글이 설치돼 있지 않아요.' $facts @(
            "한글 설치 파일 주소와 제품 키는 $($contact)께 물어보세요.",
            '받은 설치 파일을 실행하고, 관리자 확인 창이 뜨면 [예]를 누르세요.',
            '제품 키를 묻는 칸에 받은 키를 그대로 넣으세요.')
    }
    New-Result guide '한글은 설치돼 있어요.' $facts @(
        '한글 창을 모두 닫고 PC를 다시 시작한 뒤 열어 보세요. 대부분 이걸로 풀려요.',
        "제품 키(인증)를 다시 넣으라고 뜨면 $($contact)께 제품 키를 물어보세요.",
        '특정 파일만 안 열리면 그 파일을 USB나 메신저로 다른 PC에서 열어 보세요. 거기서도 안 열리면 파일 문제예요.',
        '그래도 안 되면 뜨는 오류 창을 사진으로 찍어 밴드에 올려 주세요.') @(New-RestartAction)
}
