# 교실 PC 도우미 — 바탕화면에 붙어 있는 작은 패널.
# 고장 현상 고르기 → 현재 상태 점검 → 자동 수리 또는 안내 → 안 되면 밴드로.
#
# 실행: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File PcHelper.ps1
#   -NoPin        바탕화면에 고정하지 않고 보통 창으로 띄움 (테스트용)
#   -Open <갈래>  켜자마자 도우미 창을 연다: display | touch | audio | print | net | pc | app (테스트용)

param([switch]$NoPin, [string]$Open)

$ErrorActionPreference = 'Continue'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 같은 사용자로 두 번 켜지지 않게 한다 (시작 프로그램 + 바탕화면 바로가기).
# 이미 켜져 있으면 그쪽에 "패널 보여 줘" 신호만 보내고 끝난다 (숨겨 둔 패널을 바로가기로 다시 꺼내는 용도).
$mutex = New-Object System.Threading.Mutex($false, "Local\ClassroomPcHelper")
$showSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ClassroomPcHelper-Show')
if (-not $mutex.WaitOne(0)) { [void]$showSignal.Set(); return }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
. (Join-Path $AppDir 'lib\Native.ps1')
. (Join-Path $AppDir 'lib\Checks.ps1')
. (Join-Path $AppDir 'lib\Update.ps1')
. (Join-Path $AppDir 'lib\Status.ps1')

$Config = Get-Content (Join-Path $AppDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
# 버튼 처리 중 예상 못 한 오류가 나도 패널이 꺼지지 않게 기록만 남긴다.
$LogPath = Join-Path $env:APPDATA 'ClassroomPcHelper\error.log'
$app.Add_DispatcherUnhandledException({
    param($s, $e)
    $e.Handled = $true
    try {
        $dir = Split-Path $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content $LogPath "$(Get-Date -Format s) $($e.Exception.Message)" -Encoding UTF8
    } catch { }
})

# ───────────────────────── 사용자 설정 (반 이름, 문의 링크, 패널 위치) ─────────────────────────

$SettingsPath = Join-Path $env:APPDATA 'ClassroomPcHelper\settings.json'

# BandUrl·Contact·Office365Url: $null이면 config.json 값을 쓴다. 다른 학교용 설치는 BandUrl을 ''로 적어 둔다.
$OverrideKeys = 'BandUrl', 'Contact', 'Office365Url'

function Get-Settings {
    $s = @{ RoomName = ''; Left = $null; Top = $null; Hidden = $false; BandUrl = $null; Contact = $null; Office365Url = $null }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch { }
    }
    $s
}

# 이 PC에서 쓰는 값: 설정 창에서 바꾼 값, 없으면 config.json 값.
function Get-Setting([string]$Name) {
    if ($null -ne $script:Settings[$Name]) { [string]$script:Settings[$Name] } else { [string]$Config.$Name }
}

# 다정초 버전 = 문의 링크가 config.json의 다정초 밴드 그대로. 아니면(비었거나 다른 곳) 다른 학교 버전.
function Test-BandEdition {
    $url = Get-Setting 'BandUrl'
    [bool]$url -and $url -eq $Config.BandUrl
}

# 다른 학교 버전에서는 '밴드' 대신 '수리업체'로 말한다. 점검 안내 문구(Checks.ps1)도 화면에 띄울 때 바꾼다.
function Get-AskLabel { if (Test-BandEdition) { '밴드에 올리기' } else { '수리업체에 문의하기' } }

function Convert-AskText([string]$Text) {
    if ((Test-BandEdition) -or -not $Text) { return $Text }
    $Text -replace '\[밴드에 올리기\]', '[수리업체에 문의하기]' -replace '밴드에 올려 주세요', '수리업체에 문의해 주세요' `
          -replace '밴드 글', '문의 글' -replace '밴드에', '수리업체에'
}

# 링크로 열어도 되는 주소인지 (웹 주소만). 'www.…'처럼 앞을 빼고 적으면 https://를 붙인다.
function ConvertTo-WebUrl([string]$Text) {
    $t = $Text.Trim()
    if (-not $t) { return '' }
    if ($t -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $t = "https://$t" }
    $u = $null
    if ([Uri]::TryCreate($t, 'Absolute', [ref]$u) -and $u.Scheme -in 'http', 'https' -and $u.Host -match '\.') { return $u.AbsoluteUri }
    $null
}

function Save-Settings {
    $dir = Split-Path $SettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8
}

$script:Settings = Get-Settings

# ───────────────────────── 증상 목록 ─────────────────────────

# Icon: Segoe Fluent Icons 글자 번호. Tint/Ink: 갈래 아이콘의 옅은 바탕색/글자색.
$Groups = [ordered]@{
    display = @{ Name = '화면'; Icon = 0xE7F4; Tint = '#E6F1FB'; Ink = '#0C447C'; Hint = 'TV·전자칠판·듀얼 모니터'; Symptoms = @(
        @{ Text = '한쪽 화면(TV·전자칠판)이 안 나와요'; Check = { Test-DisplayMissing } }
        @{ Text = '학생 화면에 내 작업 화면이 그대로 보여요'; Check = { Test-DisplayMirrored } }
        @{ Text = 'TV에 내 화면을 똑같이 띄우고 싶어요'; Check = { Test-DisplaySame } }
        @{ Text = '글씨·아이콘이 갑자기 커졌어요 (작아졌어요)'; Check = { Test-DisplayScale } }
        @{ Text = '마우스가 옆 화면으로 안 넘어가요 / 방향이 반대예요'; Check = { Test-DisplayMouse } }
        @{ Text = '화면이 흐려요 / 글씨가 번져요 / 비율이 이상해요'; Check = { Test-DisplaySharp } }
    ) }
    touch = @{ Name = '터치'; Icon = 0xE815; Tint = '#E1F5EE'; Ink = '#085041'; Hint = '전자칠판 터치'; Symptoms = @(
        @{ Text = '전자칠판 터치가 안 돼요'; Check = { Test-TouchNone } }
        @{ Text = '터치하면 다른 화면(내 모니터)이 눌려요'; Check = { Test-TouchMap } }
        @{ Text = '저절로 눌리거나 화면이 커졌다 작아졌다 해요'; Check = { Test-TouchGhost } }
        @{ Text = '터치를 끄고 싶어요 / 다시 켜고 싶어요'; Check = { Test-TouchSwitch } }
    ) }
    audio = @{ Name = '소리'; Icon = 0xE767; Tint = '#EEEDFE'; Ink = '#3C3489'; Hint = '스피커·TV 소리·마이크'; Symptoms = @(
        @{ Text = '교실 스피커로 소리가 안 나요 (TV로는 나요)'; Check = { Test-AudioTarget -WantTv $false } }
        @{ Text = 'TV(전자칠판)에서 소리가 안 나요'; Check = { Test-AudioTarget -WantTv $true } }
        @{ Text = '소리가 아예 안 나요'; Check = { Test-AudioNone } }
        @{ Text = '지직거리는 잡음, 삐 소리가 나요'; Check = { Test-AudioNoise } }
        @{ Text = '마이크 소리가 안 나요'; Check = { Test-MicNone } }
        @{ Text = '다른 반 마이크 소리가 우리 반에서 들려요'; Check = { Test-MicCross } }
    ) }
    print = @{ Name = '프린터'; Icon = 0xE749; Tint = '#FAECE7'; Ink = '#712B13'; Hint = '인쇄·용지 걸림·스캔'; Symptoms = @(
        @{ Text = '인쇄가 안 돼요'; Check = { Test-PrintFail } }
        @{ Text = '다른 반(엉뚱한) 프린터로 나가요'; Check = { Test-PrintWrong } }
        @{ Text = '종이가 걸렸다고 떠요'; Check = { Test-PrintJam } }
        @{ Text = '쓰려는 프린터가 목록에 없어요'; Check = { Test-PrintMissing } }
        @{ Text = '스캔한 파일이 PC로 안 들어와요 / 스캔 연결이 필요해요'; Check = { Test-ScanFolder } }
    ) }
    net = @{ Name = '인터넷'; Icon = 0xE774; Tint = '#EAF3DE'; Ink = '#27500A'; Hint = '인터넷·사이트 접속'; Symptoms = @(
        @{ Text = '인터넷이 안 돼요'; Check = { Test-NetDown } }
        @{ Text = '특정 사이트·업무포털만 안 열려요'; Check = { Test-NetDown } }
    ) }
    pc = @{ Name = '컴퓨터'; Icon = 0xE9D9; Tint = '#F1EFE8'; Ink = '#444441'; Hint = '느림·멈춤'; Symptoms = @(
        @{ Text = '컴퓨터가 느려요 / 자꾸 멈춰요'; Check = { Test-PcSlow } }
    ) }
    app = @{ Name = '프로그램'; Icon = 0xE8A5; Tint = '#FBEAF0'; Ink = '#72243E'; Hint = '오피스·한글 설치·인증'; Symptoms = @(
        @{ Text = '엑셀·파워포인트가 인증하라고 떠요 / 편집이 안 돼요'; Check = { Test-OfficeLicense } }
        @{ Text = '엑셀·파워포인트(오피스)를 설치하고 싶어요'; Check = { Test-OfficeInstall } }
        @{ Text = '한글이 안 열려요 / 인증하라고 떠요 / 설치하고 싶어요'; Check = { Test-Hangul } }
    ) }
}

# ───────────────────────── 공통 화면 조각 ─────────────────────────

$Colors = @{
    Primary = '#2563EB'; PrimaryHover = '#1D4ED8'; PrimaryLight = '#DBEAFE'; PrimaryTint = '#EEF4FF'
    Text = '#191F28'; Sub = '#4E5968'; Faint = '#8B95A1'; Line = '#E5E8EB'; Bg = '#F2F4F6'; Card = '#FFFFFF'; Hover = '#F7F9FC'
    Ok = '#16A34A'; OkTint = '#ECFDF3'; Warn = '#D97706'; WarnTint = '#FFF7E8'; Bad = '#DC2626'; BadTint = '#FEF2F2'
}

# 판정(Tone)마다 색·아이콘. 결과 화면 맨 위 카드에 쓴다.
$Tones = @{
    ok    = @{ Label = '정상이에요';         Color = $Colors.Ok;      Tint = $Colors.OkTint;      Icon = 0xE73E }
    fix   = @{ Label = '바로 고칠 수 있어요'; Color = $Colors.Primary; Tint = $Colors.PrimaryTint; Icon = 0xE90F }
    guide = @{ Label = '직접 확인해 주세요';  Color = $Colors.Warn;    Tint = $Colors.WarnTint;    Icon = 0xE7BA }
    band  = @{ Label = '밴드에 올려 주세요';  Color = $Colors.Bad;     Tint = $Colors.BadTint;     Icon = 0xE724 }
}

function New-ButtonStyle([string]$Key, [string]$Bg, [string]$Fg, [string]$Border = 'Transparent', [int]$Radius = 10,
                         [string]$Padding = '16,12', [string]$Align = 'Center', [string]$HoverBg = '', [string]$Weight = 'SemiBold') {
    $hover = if ($HoverBg) { "<Setter TargetName=`"B`" Property=`"Background`" Value=`"$HoverBg`"/>" } else { '<Setter TargetName="B" Property="Opacity" Value="0.88"/>' }
    @"
  <Style x:Key="$Key" TargetType="Button">
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontSize" Value="15"/>
    <Setter Property="FontWeight" Value="$Weight"/>
    <Setter Property="Foreground" Value="$Fg"/>
    <Setter Property="Background" Value="$Bg"/>
    <Setter Property="BorderBrush" Value="$Border"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="$Padding"/>
    <Setter Property="HorizontalContentAlignment" Value="$Align"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="$Radius" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">$hover</Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.75"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
"@
}

$StyleXaml = @"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
$(New-ButtonStyle 'Primary' $Colors.Primary 'White')
$(New-ButtonStyle 'Soft' $Colors.PrimaryLight $Colors.PrimaryHover)
$(New-ButtonStyle 'Gray' $Colors.Bg $Colors.Text)
$(New-ButtonStyle 'Outline' $Colors.Card $Colors.Text -Border '#D1D6DB' -HoverBg $Colors.Hover)
$(New-ButtonStyle 'Item' $Colors.Card $Colors.Text -Border $Colors.Line -Radius 12 -Padding '14,12' -Align 'Stretch' -HoverBg $Colors.Hover -Weight 'Normal')
$(New-ButtonStyle 'Plain' 'Transparent' $Colors.Sub -Weight 'Normal')
$(New-ButtonStyle 'Icon' 'Transparent' $Colors.Faint -Radius 8 -Padding '6' -HoverBg $Colors.Bg -Weight 'Normal')
</ResourceDictionary>
"@
$Styles = [Windows.Markup.XamlReader]::Parse($StyleXaml)

# 글꼴: 앱에 같이 넣은 Pretendard(fonts 폴더), 없으면 맑은 고딕. 아이콘은 윈도우 기본 아이콘 글꼴.
$FontDir = Join-Path $AppDir 'fonts'
$FontFamily = if (Test-Path (Join-Path $FontDir 'Pretendard-Regular.otf')) {
    New-Object System.Windows.Media.FontFamily ([Uri]('file:///' + ($FontDir -replace '\\', '/') + '/')), './#Pretendard, Malgun Gothic'
} else { New-Object System.Windows.Media.FontFamily 'Malgun Gothic' }
$IconFont = New-Object System.Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'

function Brush([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

# 프로그램 아이콘 (파란 바탕에 체크한 모니터). 창·알림 영역·바로가기에 같이 쓴다.
$IconPath = Join-Path $AppDir 'icon.ico'
$AppIcon = New-Object System.Drawing.Icon $IconPath, ([System.Windows.Forms.SystemInformation]::SmallIconSize)
# 파일에서 바로 읽으면 켜져 있는 동안 icon.ico가 잠겨 업데이트가 덮어쓰지 못한다. 메모리로 읽어 둔다.
$AppIconImage = [System.Windows.Media.Imaging.BitmapFrame]::Create(
    (New-Object System.IO.MemoryStream (, [IO.File]::ReadAllBytes($IconPath))), 'None', 'OnLoad')
Update-ShortcutIcon $AppDir
Register-AppEntry $AppDir

function New-Text {
    param([string]$Text, [double]$Size = 15, [string]$Color = $Colors.Text, [switch]$Bold, [double]$Bottom = 0)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Brush $Color; $t.TextWrapping = 'Wrap'
    $t.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    $t.LineHeight = [math]::Round($Size * 1.5)
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    $t
}

# 아이콘 글자 하나. 색을 안 주면 버튼 글자색을 따른다.
function New-Glyph([int]$Code, [double]$Size = 16, [string]$Color = '') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = [string][char]$Code; $t.FontFamily = $IconFont; $t.FontSize = $Size
    $t.VerticalAlignment = 'Center'; $t.HorizontalAlignment = 'Center'
    if ($Color) { $t.Foreground = Brush $Color }
    $t
}

# 옅은 색 사각형(또는 원) 위의 아이콘.
function New-IconTile([int]$Code, [string]$Tint, [string]$Ink, [double]$Box = 32, [double]$Size = 16, [double]$Radius = 8) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = $Box; $b.Height = $Box; $b.Background = Brush $Tint
    $b.CornerRadius = New-Object System.Windows.CornerRadius $Radius
    $b.VerticalAlignment = 'Center'
    $b.Child = New-Glyph $Code $Size $Ink
    $b
}

function New-Btn {
    param([string]$Text, [string]$Style = 'Item', $Tag, [scriptblock]$OnClick, [double]$Bottom = 8, [int]$Icon = 0)
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $Styles[$Style]
    if ($Text) {
        # 긴 장치 이름도 잘리지 않게 줄바꿈되는 글자로 넣는다.
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $Text; $label.TextWrapping = 'Wrap'; $label.VerticalAlignment = 'Center'
        if ($Style -ne 'Item') { $label.TextAlignment = 'Center' }
        # 아이콘을 붙이면 줄바꿈이 안 돼서, 긴 글자(장치 이름 등)는 아이콘 없이 줄바꿈되게 둔다.
        if ($Icon -and $Text.Length -le 22) {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Center'
            $g = New-Glyph $Icon 15
            $g.Margin = New-Object System.Windows.Thickness 0, 1, 8, 0
            [void]$row.Children.Add($g); [void]$row.Children.Add($label)
            $b.Content = $row
        } else { $b.Content = $label }
        [System.Windows.Automation.AutomationProperties]::SetName($b, $Text)
    }
    $b.Tag = $Tag
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    if ($OnClick) { $b.Add_Click($OnClick) }
    $b
}

function New-Box {
    param([string]$Background = $Colors.Bg, [double]$Bottom = 16, [double]$Radius = 12)
    $border = New-Object System.Windows.Controls.Border
    $border.Background = Brush $Background
    $border.CornerRadius = New-Object System.Windows.CornerRadius $Radius
    $border.Padding = New-Object System.Windows.Thickness 16, 14, 16, 14
    $border.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    $stack = New-Object System.Windows.Controls.StackPanel
    $border.Child = $stack
    @{ Border = $border; Stack = $stack }
}

function Update-Ui { $script:Win.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background) }

# ───────────────────────── 도우미 창 ─────────────────────────

$script:Win = $null
$script:State = @{ Group = $null; Symptom = $null; Result = $null; Done = @(); Notice = '' }

function Show-Helper([string]$GroupKey) {
    $script:State = @{ Group = $GroupKey; Symptom = $null; Result = $null; Done = @(); Notice = '' }
    if (-not $script:Win) {
        $w = New-Object System.Windows.Window
        $w.Title = $Config.AppName; $w.Icon = $AppIconImage
        $w.Width = 520; $w.Height = 680; $w.MinWidth = 420; $w.MinHeight = 480
        # TV 쪽이 아니라 주 모니터(선생님 화면) 가운데에 띄운다.
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.WindowStartupLocation = 'Manual'
        $w.Left = $wa.Left + ($wa.Width - $w.Width) / 2
        $w.Top = $wa.Top + [math]::Max(0, ($wa.Height - $w.Height) / 2)
        $w.Background = Brush $Colors.Card
        $w.FontFamily = $FontFamily
        $w.Topmost = $true
        $w.Resources.MergedDictionaries.Add($Styles)

        $grid = New-Object System.Windows.Controls.Grid
        foreach ($h in 'Auto', '*', 'Auto') {
            $row = New-Object System.Windows.Controls.RowDefinition
            $row.Height = (New-Object System.Windows.GridLengthConverter).ConvertFromString($h)
            $grid.RowDefinitions.Add($row)
        }
        $script:Header = New-Object System.Windows.Controls.StackPanel
        $script:Header.Margin = New-Object System.Windows.Thickness 28, 24, 28, 12
        $scroll = New-Object System.Windows.Controls.ScrollViewer
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $script:Body = New-Object System.Windows.Controls.StackPanel
        $script:Body.Margin = New-Object System.Windows.Thickness 28, 4, 28, 16
        $scroll.Content = $script:Body
        $script:Scroll = $scroll
        $script:Footer = New-Object System.Windows.Controls.StackPanel
        $script:Footer.Margin = New-Object System.Windows.Thickness 28, 8, 28, 24
        [System.Windows.Controls.Grid]::SetRow($script:Header, 0)
        [System.Windows.Controls.Grid]::SetRow($scroll, 1)
        [System.Windows.Controls.Grid]::SetRow($script:Footer, 2)
        [void]$grid.Children.Add($script:Header); [void]$grid.Children.Add($scroll); [void]$grid.Children.Add($script:Footer)
        $w.Content = $grid
        $w.Add_Closing({ param($s, $e) $e.Cancel = $true; $s.Hide() })   # 닫아도 다시 쓸 수 있게 숨기기만 한다
        $script:Win = $w
    }
    Show-Symptoms
    $script:Win.Show()
    $script:Win.Activate() | Out-Null
}

function Set-Header([string]$Title, [string]$Sub, [bool]$Back) {
    $script:Header.Children.Clear()
    $g = $Groups[$script:State.Group]
    if ($Back) {
        $b = New-Btn '처음으로' 'Plain' $null { Show-Symptoms } 8 -Icon 0xE72B
        $b.HorizontalAlignment = 'Left'; $b.Padding = New-Object System.Windows.Thickness 0, 4, 8, 4; $b.FontSize = 14
        [void]$script:Header.Children.Add($b)
    }
    # 어느 갈래인지: 갈래 아이콘 + 이름
    $chip = New-Object System.Windows.Controls.StackPanel
    $chip.Orientation = 'Horizontal'; $chip.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    [void]$chip.Children.Add((New-IconTile $g.Icon $g.Tint $g.Ink 28 15 8))
    $name = New-Text $g.Name 14 $g.Ink -Bold
    $name.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0; $name.VerticalAlignment = 'Center'
    [void]$chip.Children.Add($name)
    [void]$script:Header.Children.Add($chip)
    [void]$script:Header.Children.Add((New-Text $Title 22 -Bold -Bottom 2))
    if ($Sub) { [void]$script:Header.Children.Add((New-Text $Sub 14 $Colors.Sub)) }
}

# 증상 한 줄: 글자 + 오른쪽 화살표
function New-RowButton([string]$Text, $Tag, [scriptblock]$OnClick) {
    $b = New-Btn '' 'Item' $Tag $OnClick 8
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)
    $label = New-Text $Text 15
    $label.VerticalAlignment = 'Center'
    $arrow = New-Glyph 0xE76C 12 $Colors.Faint
    $arrow.Margin = New-Object System.Windows.Thickness 12, 0, 0, 0
    [System.Windows.Controls.Grid]::SetColumn($arrow, 1)
    [void]$grid.Children.Add($label); [void]$grid.Children.Add($arrow)
    $b.Content = $grid
    $b.Padding = New-Object System.Windows.Thickness 18, 14, 16, 14
    [System.Windows.Automation.AutomationProperties]::SetName($b, $Text)
    $b
}

function Show-Symptoms {
    $g = $Groups[$script:State.Group]
    $script:State.Symptom = $null; $script:State.Result = $null; $script:State.Done = @(); $script:State.Notice = ''
    Set-Header "$($g.Name) 문제" '어떤 증상인가요? 비슷한 것을 눌러 주세요.' $false
    $script:Body.Children.Clear(); $script:Footer.Children.Clear()
    foreach ($sym in $g.Symptoms) {
        [void]$script:Body.Children.Add((New-RowButton $sym.Text $sym { Start-Check $this.Tag }))
    }
    $other = New-Btn "여기 없는 문제예요 · $(Get-AskLabel)" 'Plain' $null { Send-ToBand -Symptom '목록에 없는 문제' } 0 -Icon 0xE724
    $other.FontSize = 14
    [void]$script:Body.Children.Add($other)
    $script:Scroll.ScrollToTop()
}

function Start-Check($Symptom) {
    $script:State.Symptom = $Symptom
    Set-Header $Symptom.Text '' $true
    $script:Body.Children.Clear(); $script:Footer.Children.Clear()
    [void]$script:Body.Children.Add((New-Text '이 PC 상태를 점검하고 있어요…' 15 $Colors.Sub))
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    Update-Ui
    try {
        $result = & $Symptom.Check
    } catch {
        $result = New-Result band '점검하다가 오류가 났어요.' @("오류 내용: $($_.Exception.Message)") @('밴드에 올려 주세요.')
    }
    $script:Win.Cursor = $null
    $script:State.Result = $result
    Show-Result
}

# 점검 결과 한 줄이 좋은 소식인지 나쁜 소식인지 문구로 가른다. 밴드 글에는 문구 그대로 들어간다.
function Get-FactTone([string]$Fact) {
    if ($Fact -match '^무선 — 연결 안 됨') { return 'info' }   # 유선으로 쓰는 교실이 대부분이라 문제 아님
    if ($Fact -match '지금 (\d+×\d+), 권장 (\d+×\d+)') { if ($Matches[1] -eq $Matches[2]) { return 'ok' } else { return 'warn' } }
    if ($Fact -match '선 빠짐|빠져|음소거 켜짐|받지 못함|응답 없음|연결 안 됨|찾지 못함|쓸 수 없음|용지 걸림|용지 없음|토너 없음|오프라인|덮개 열림|설치 안 됨|로그인: 안 됨|공유 폴더: 없음') { return 'bad' }
    if ($Fact -match '대기 중인 인쇄|용지 적음|토너 적음|점검 필요|공용|기능: 켜짐|꺼져 있는 것') { return 'warn' }
    if ($Fact -match '연결됨|응답함|이상 없음|쓸 수 있음|지금 여기로|로그인: 됨') { return 'ok' }
    'info'
}

function Get-ActionIcon([string]$Label) {
    switch -Regex ($Label) {
        '설정 창'          { return 0xE713 }
        '가입센터'         { return 0xE774 }
        '다시 시작'        { return 0xE72C }
        '임시 파일'        { return 0xE74D }
        '소리 보내기|음소거|확인 소리' { return 0xE767 }
        '프린터|인쇄'      { return 0xE749 }
        '터치'             { return 0xE815 }
        '복제|확장|해상도' { return 0xE7F4 }
    }
    0xE90F
}

function Show-Result {
    $r = $script:State.Result
    $script:Body.Children.Clear(); $script:Footer.Children.Clear()

    if ($script:State.Notice) {
        $n = New-Box $Colors.PrimaryTint -Bottom 12
        $line = New-Object System.Windows.Controls.DockPanel
        $i = New-Glyph 0xE946 16 $Colors.Primary
        $i.VerticalAlignment = 'Top'; $i.Margin = New-Object System.Windows.Thickness 0, 3, 10, 0
        [System.Windows.Controls.DockPanel]::SetDock($i, 'Left')
        [void]$line.Children.Add($i)
        [void]$line.Children.Add((New-Text (Convert-AskText $script:State.Notice) 15 $Colors.PrimaryHover -Bold))
        [void]$n.Stack.Children.Add($line)
        [void]$script:Body.Children.Add($n.Border)
    }

    # 판정 카드: 큰 원 아이콘 + 판정 + 한 줄 설명
    $tone = $Tones[$r.Tone]; if (-not $tone) { $tone = $Tones['band'] }
    $toneLabel = if ($r.Tone -eq 'band' -and -not (Test-BandEdition)) { '수리업체에 문의해 주세요' } else { $tone.Label }
    $hero = New-Box $tone.Tint -Bottom 14 -Radius 14
    $hero.Border.Padding = New-Object System.Windows.Thickness 16
    $heroRow = New-Object System.Windows.Controls.DockPanel
    $circle = New-IconTile $tone.Icon $tone.Color '#FFFFFF' 44 20 22
    $circle.Margin = New-Object System.Windows.Thickness 0, 0, 14, 0
    [System.Windows.Controls.DockPanel]::SetDock($circle, 'Left')
    [void]$heroRow.Children.Add($circle)
    $heroText = New-Object System.Windows.Controls.StackPanel
    $heroText.VerticalAlignment = 'Center'
    [void]$heroText.Children.Add((New-Text $toneLabel 13 $tone.Color -Bold))
    [void]$heroText.Children.Add((New-Text (Convert-AskText $r.Title) 17 -Bold))
    [void]$heroRow.Children.Add($heroText)
    [void]$hero.Stack.Children.Add($heroRow)
    [void]$script:Body.Children.Add($hero.Border)

    # 고치기 버튼: 첫 번째만 진하게, 나머지는 옅게
    $first = $true
    foreach ($a in $r.Actions) {
        $style = if ($first) { 'Primary' } else { 'Soft' }
        [void]$script:Body.Children.Add((New-Btn $a.Label $style $a { Invoke-Fix $this.Tag } -Icon (Get-ActionIcon $a.Label)))
        $first = $false
    }
    if ($r.Actions.Count -gt 0) { [void]$script:Body.Children.Add((New-Text '' 4 -Bottom 10)) }

    # 해 볼 순서: 번호 원 + 문장
    if ($r.Steps.Count -gt 0) {
        [void]$script:Body.Children.Add((New-Text '이렇게 해 보세요' 15 -Bold -Bottom 10))
        $n = 1
        foreach ($s in $r.Steps) {
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
            $num = New-Object System.Windows.Controls.Border
            $num.Width = 24; $num.Height = 24; $num.CornerRadius = New-Object System.Windows.CornerRadius 12
            $num.Background = Brush $Colors.PrimaryTint; $num.VerticalAlignment = 'Top'
            $num.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0
            $numText = New-Text "$n" 12 $Colors.Primary -Bold
            $numText.HorizontalAlignment = 'Center'; $numText.VerticalAlignment = 'Center'
            $num.Child = $numText
            [System.Windows.Controls.DockPanel]::SetDock($num, 'Left')
            [void]$row.Children.Add($num)
            [void]$row.Children.Add((New-Text (Convert-AskText $s) 15))
            [void]$script:Body.Children.Add($row)
            $n++
        }
        [void]$script:Body.Children.Add((New-Text '' 4 -Bottom 6))
    }

    # 점검한 것: 줄마다 상태 아이콘
    if ($r.Facts.Count -gt 0) {
        [void]$script:Body.Children.Add((New-Text '점검한 것' 13 $Colors.Faint -Bold -Bottom 6))
        $card = New-Object System.Windows.Controls.Border
        $card.BorderBrush = Brush $Colors.Line; $card.BorderThickness = New-Object System.Windows.Thickness 1
        $card.CornerRadius = New-Object System.Windows.CornerRadius 12
        $card.Padding = New-Object System.Windows.Thickness 14, 4, 14, 4
        $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
        $list = New-Object System.Windows.Controls.StackPanel
        $marks = @{ ok = @(0xE73E, $Colors.Ok); warn = @(0xE7BA, $Colors.Warn); bad = @(0xEA39, $Colors.Bad); info = @(0xE946, $Colors.Faint) }
        $last = $r.Facts.Count - 1
        for ($k = 0; $k -le $last; $k++) {
            $f = $r.Facts[$k]
            $m = $marks[(Get-FactTone $f)]
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = New-Object System.Windows.Thickness 0, 8, 0, 8
            $icon = New-Glyph $m[0] 14 $m[1]
            $icon.VerticalAlignment = 'Top'; $icon.Margin = New-Object System.Windows.Thickness 0, 3, 10, 0
            [System.Windows.Controls.DockPanel]::SetDock($icon, 'Left')
            [void]$row.Children.Add($icon)
            [void]$row.Children.Add((New-Text $f 13.5 $Colors.Sub))
            [void]$list.Children.Add($row)
            if ($k -lt $last) {
                $sep = New-Object System.Windows.Controls.Border
                $sep.Height = 1; $sep.Background = Brush '#F0F2F4'
                [void]$list.Children.Add($sep)
            }
        }
        $card.Child = $list
        [void]$script:Body.Children.Add($card)
    }

    $row = New-Object System.Windows.Controls.Primitives.UniformGrid
    $row.Columns = 2
    $again = New-Btn '다시 점검' 'Gray' $null { $script:State.Notice = ''; Start-Check $script:State.Symptom } 0 -Icon 0xE72C
    $again.Margin = New-Object System.Windows.Thickness 0, 0, 4, 8
    $done = New-Btn '해결됐어요' 'Gray' $null { $script:Win.Hide() } 0 -Icon 0xE73E
    $done.Margin = New-Object System.Windows.Thickness 4, 0, 0, 8
    [void]$row.Children.Add($again); [void]$row.Children.Add($done)
    [void]$script:Footer.Children.Add($row)
    $bandStyle = if ($r.Tone -eq 'band') { 'Primary' } else { 'Outline' }
    [void]$script:Footer.Children.Add((New-Btn "그래도 안 돼요 · $(Get-AskLabel)" $bandStyle $null { Send-ToBand } 0 -Icon 0xE724))
    $script:Scroll.ScrollToTop()
}

function Invoke-Fix($Action) {
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    Update-Ui
    try {
        $msg = (& $Action.Run | Select-Object -Last 1)
        if ($msg -ne $script:CancelText) { $script:State.Done += $Action.Label }
    } catch {
        $msg = "고치지 못했어요: $($_.Exception.Message)"
        $script:State.Done += "$($Action.Label) (실패)"
    }
    $script:Win.Cursor = $null
    # 고친 뒤 다시 점검해서 바뀐 상태를 보여 준다.
    try { $script:State.Result = & $script:State.Symptom.Check } catch { }
    $script:State.Notice = $msg
    $script:StatusNext = [DateTime]::Now   # 고친 뒤 패널 상태 줄도 바로 새로 읽는다
    Show-Result
}

# 수리 버튼이 PC를 크게 바꾸기 전에 묻는다.
function Confirm-Ask([string]$Message) {
    [System.Windows.MessageBox]::Show($script:Win, $Message, $Config.AppName, 'YesNo', 'Question') -eq 'Yes'
}

# 화면 설정을 바꾼 뒤 잘 보이는지 묻는다. 화면이 안 나와서 못 누르면 시간이 지나 $false.
function Confirm-Keep([int]$Seconds = 15) {
    $d = New-Object System.Windows.Window
    $d.Title = $Config.AppName; $d.Width = 400; $d.SizeToContent = 'Height'; $d.ResizeMode = 'NoResize'
    $d.WindowStartupLocation = 'CenterOwner'; $d.Owner = $script:Win; $d.Topmost = $true; $d.FontFamily = $FontFamily; $d.Icon = $AppIconImage
    $d.Resources.MergedDictionaries.Add($Styles)
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Margin = New-Object System.Windows.Thickness 24
    [void]$p.Children.Add((New-Text '화면이 잘 보이나요?' 18 -Bold -Bottom 6))
    $count = New-Text '' 14 $Colors.Sub -Bottom 14
    [void]$p.Children.Add($count)
    $keep = New-Btn '네, 이대로 쓸게요' 'Primary' $null { $d.DialogResult = $true } 6
    $back = New-Btn '원래대로 되돌리기' 'Soft' $null { $d.DialogResult = $false } 0
    [void]$p.Children.Add($keep); [void]$p.Children.Add($back)
    $d.Content = $p
    $left = @{ Seconds = $Seconds }
    $count.Text = "$($Seconds)초 뒤에 원래대로 되돌려요."
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        $left.Seconds--
        $count.Text = "$($left.Seconds)초 뒤에 원래대로 되돌려요."
        if ($left.Seconds -le 0) { $timer.Stop(); $d.DialogResult = $false }
    }.GetNewClosure())
    $timer.Start()
    $result = $d.ShowDialog()
    $timer.Stop()
    [bool]$result
}

# ───────────────────────── 밴드(수리업체)로 보내기 ─────────────────────────

# 작은 대화 창 틀. 패널 메뉴에서 부르면 도우미 창이 없거나 숨어 있다. 그때는 주 모니터 가운데에 띄운다.
function New-Dialog([double]$Width = 380) {
    $d = New-Object System.Windows.Window
    $d.Title = $Config.AppName; $d.Width = $Width; $d.SizeToContent = 'Height'; $d.ResizeMode = 'NoResize'
    if ($script:Win -and $script:Win.IsVisible) { $d.WindowStartupLocation = 'CenterOwner'; $d.Owner = $script:Win }
    else { $d.WindowStartupLocation = 'CenterScreen' }
    $d.Topmost = $true; $d.FontFamily = $FontFamily; $d.Icon = $AppIconImage; $d.Background = Brush $Colors.Card
    $d.Resources.MergedDictionaries.Add($Styles)
    $d
}

# 이름 + 설명 + 글 상자 + 예시 한 묶음. 글 상자를 돌려준다.
function Add-Field($Panel, [string]$Label, [string]$Help, [string]$Value, [string]$Example) {
    $l = New-Text $Label 15 -Bold -Bottom 2
    [void]$Panel.Children.Add($l)
    if ($Help) { [void]$Panel.Children.Add((New-Text $Help 13 $Colors.Sub -Bottom 8)) }
    $box = New-Object System.Windows.Controls.TextBox
    $box.FontSize = 15; $box.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
    $box.Text = $Value
    [System.Windows.Automation.AutomationProperties]::SetLabeledBy($box, $l)
    [void]$Panel.Children.Add($box)
    if ($Example) { [void]$Panel.Children.Add((New-Text $Example 12.5 $Colors.Faint -Bottom 16)) }
    else { $box.Margin = New-Object System.Windows.Thickness 0, 0, 0, 16 }
    $box
}

function Show-Warning([string]$Message) {
    $owner = if ($script:Win -and $script:Win.IsVisible) { $script:Win } else { $panel }
    [void][System.Windows.MessageBox]::Show($owner, $Message, $Config.AppName, 'OK', 'Warning')
}

# 한 칸만 묻는 창. [확인]이면 적은 글, 닫으면 $null.
function Read-Value([string]$Label, [string]$Help, [string]$Value, [string]$Example) {
    $d = New-Dialog
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Margin = New-Object System.Windows.Thickness 24
    $box = Add-Field $p $Label $Help $Value $Example
    $ok = New-Btn '확인' 'Primary' $null { $d.DialogResult = $true } 0
    $ok.IsDefault = $true
    [void]$p.Children.Add($ok)
    $d.Content = $p
    $d.Add_ContentRendered({ $box.Focus() | Out-Null })
    if ($d.ShowDialog()) { return $box.Text.Trim() }
    $null
}

function Read-RoomName {
    Read-Value '우리 반(교실) 이름' '올리는 글 맨 앞에 붙어요. 한 번만 적으면 기억해요.' $script:Settings.RoomName '예: 5-빛솔, 4학년 연구실, 돌봄3반'
}

# 다른 학교 버전에서 문의 링크가 비어 있을 때 묻는다. 웹 주소만 받는다.
function Read-AskUrl {
    $text = ''
    while ($true) {
        $text = Read-Value '수리 문의 링크' '그래도 안 될 때 열 주소예요. 수리업체 밴드·카페·카카오톡 오픈채팅·홈페이지 주소를 붙여 넣으세요. 한 번만 적으면 기억해요.' $text '예: https://band.us/band/12345678'
        if ($null -eq $text) { return $null }
        $url = ConvertTo-WebUrl $text
        if ($url) { return $url }
        Show-Warning '주소 모양이 아니에요. 인터넷 창 맨 위 주소 칸의 주소를 복사해서 붙여 넣어 주세요.'
    }
}

function Send-ToBand([string]$Symptom) {
    if (-not $script:Settings.RoomName) {
        $name = Read-RoomName
        if (-not $name) { return }
        $script:Settings.RoomName = $name
        Save-Settings
        Update-PanelSub
    }
    $url = ConvertTo-WebUrl (Get-Setting 'BandUrl')
    if (-not $url) {
        $url = Read-AskUrl
        if (-not $url) { return }
        $script:Settings.BandUrl = $url
        Save-Settings
    }
    $g = $Groups[$script:State.Group]
    if (-not $Symptom) { $Symptom = $script:State.Symptom.Text }
    $lines = @("[$($script:Settings.RoomName)] $($g.Name) — $Symptom", '')
    $r = $script:State.Result
    if ($r -and $r.Facts.Count -gt 0) {
        $lines += '점검 결과'
        $lines += @($r.Facts | ForEach-Object { "- $_" })
        $lines += ''
    }
    if ($script:State.Done.Count -gt 0) {
        $lines += '해 본 것'
        $lines += @($script:State.Done | ForEach-Object { "- $_" })
        $lines += ''
    }
    $lines += "(PC 도우미로 점검 · PC 이름 $env:COMPUTERNAME)"
    Set-Clipboard -Value ($lines -join "`r`n")
    Start-Process $url

    $script:State.Notice = if (Test-BandEdition) { "$($Config.BandName)를 열었어요. [글쓰기]를 누르고 Ctrl+V로 붙여 넣으세요. 점검 내용이 복사돼 있어요." }
                           else { '수리 문의 페이지를 열었어요. 글 쓰는 칸에 Ctrl+V로 붙여 넣으세요. 점검 내용이 복사돼 있어요.' }
    if ($r) { Show-Result } else {
        $script:Body.Children.Clear()
        $n = New-Box $Colors.PrimaryLight
        [void]$n.Stack.Children.Add((New-Text $script:State.Notice 15 $Colors.PrimaryHover -Bold))
        [void]$script:Body.Children.Add($n.Border)
        [void]$script:Body.Children.Add((New-Text '증상을 자세히 적어 주세요. (언제부터, 어떤 화면이 뜨는지, 사진이 있으면 함께)' 15 $Colors.Sub))
    }
}

# ───────────────────────── 설정 창 ─────────────────────────
# 반 이름, 수리 문의 링크, 물어볼 사람, 오피스 365 가입센터, 자동 실행. 맨 아래 제작자 링크.

$CreditUrl = 'https://eompage.com'

function Show-SettingsWindow {
    $d = New-Dialog 440
    $d.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 40
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Margin = New-Object System.Windows.Thickness 24, 20, 24, 16
    $scroll.Content = $p
    [void]$p.Children.Add((New-Text '설정' 20 -Bold -Bottom 16))

    $room = Add-Field $p '우리 반(교실) 이름' '올리는 글 맨 앞에 붙어요.' $script:Settings.RoomName '예: 5-빛솔, 4학년 연구실, 돌봄3반'
    $band = Add-Field $p '수리 문의 링크' '그래도 안 될 때 점검 내용을 복사해 두고 이 주소를 열어요. 수리업체 밴드·카페·카카오톡 오픈채팅·홈페이지 주소를 넣으세요.' `
        (Get-Setting 'BandUrl') '비워 두면 처음 문의할 때 물어봐요.'
    $contact = Add-Field $p '학교 안에서 물어볼 사람' '마이크 채널, 오피스 인증 코드, 한글 제품 키를 물어볼 분이에요.' (Get-Contact) '예: 정보부장님'
    $o365 = Add-Field $p '오피스 365 가입센터 주소' '교육청마다 달라요. 오피스 설치·인증 안내에서 열어요.' (Get-Setting 'Office365Url') '예: https://o365.sje.go.kr'

    # 저장소에서 바로 실행할 때는 바로가기가 엉뚱한 곳을 가리키게 되므로 설치본에서만 바꿀 수 있다.
    $auto = New-Object System.Windows.Controls.CheckBox
    $auto.Content = '윈도우 켤 때 자동으로 켜기'; $auto.FontSize = 15; $auto.VerticalContentAlignment = 'Center'
    $auto.IsChecked = Test-Path (Get-StartupShortcutPath)
    $auto.IsEnabled = $AppDir -like "$env:LOCALAPPDATA\ClassroomPcHelper\*"
    $auto.Margin = New-Object System.Windows.Thickness 0, 0, 0, 16
    [void]$p.Children.Add($auto)

    $err = New-Text '' 13.5 $Colors.Bad -Bottom 10
    $err.Visibility = 'Collapsed'
    [void]$p.Children.Add($err)

    $row = New-Object System.Windows.Controls.Primitives.UniformGrid
    $row.Columns = 2
    $cancel = New-Btn '취소' 'Gray' $null { $d.DialogResult = $false } 0
    $cancel.Margin = New-Object System.Windows.Thickness 0, 0, 4, 0
    $save = New-Btn '저장' 'Primary' $null {
        $url = ConvertTo-WebUrl $band.Text
        $o = ConvertTo-WebUrl $o365.Text
        if ($null -eq $url -or $null -eq $o) {
            $err.Text = if ($null -eq $url) { '수리 문의 링크가 주소 모양이 아니에요. 인터넷 창 맨 위 주소 칸의 주소를 붙여 넣어 주세요.' } else { '오피스 365 가입센터 주소가 주소 모양이 아니에요.' }
            $err.Visibility = 'Visible'
            return
        }
        $c = $contact.Text.Trim()
        $script:Settings.RoomName = $room.Text.Trim()
        # config.json과 같으면 비워 둔다 (나중에 config.json이 바뀌면 그 값을 따르게). 문의 링크는 빈 값도 저장한다(다른 학교 버전).
        $script:Settings.BandUrl = if ($url -eq (ConvertTo-WebUrl $Config.BandUrl)) { $null } else { $url }
        $script:Settings.Contact = if (-not $c -or $c -eq $Config.Contact) { $null } else { $c }
        $script:Settings.Office365Url = if (-not $o -or $o -eq (ConvertTo-WebUrl $Config.Office365Url)) { $null } else { $o }
        Save-Settings
        if ($auto.IsEnabled -and [bool]$auto.IsChecked -ne (Test-Path (Get-StartupShortcutPath))) { Set-AutoStart $AppDir ([bool]$auto.IsChecked) }
        $d.DialogResult = $true
    } 0
    $save.Margin = New-Object System.Windows.Thickness 4, 0, 0, 0
    $save.IsDefault = $true
    [void]$row.Children.Add($cancel); [void]$row.Children.Add($save)
    [void]$p.Children.Add($row)

    $credit = New-Object System.Windows.Controls.TextBlock
    $credit.FontSize = 12; $credit.Foreground = Brush $Colors.Faint
    $credit.HorizontalAlignment = 'Center'; $credit.Margin = New-Object System.Windows.Thickness 0, 18, 0, 0
    [void]$credit.Inlines.Add('제작자: ')
    $link = New-Object System.Windows.Documents.Hyperlink
    [void]$link.Inlines.Add($CreditUrl)
    $link.Foreground = Brush $Colors.Sub; $link.Cursor = [System.Windows.Input.Cursors]::Hand
    $link.Add_Click({ Start-Process $CreditUrl })
    [void]$credit.Inlines.Add($link)
    [void]$p.Children.Add($credit)

    $d.Content = $scroll
    $d.Add_ContentRendered({ $room.Focus() | Out-Null })
    if (-not $d.ShowDialog()) { return }

    # 바뀐 문구(밴드 ↔ 수리업체, 반 이름)를 바로 보여 준다.
    Update-PanelSub
    if ($script:Win -and $script:Win.IsVisible) { if ($script:State.Result) { Show-Result } else { Show-Symptoms } }
}

# ───────────────────────── 바탕화면 패널 ─────────────────────────

$panel = New-Object System.Windows.Window
$panel.WindowStyle = 'None'; $panel.ResizeMode = 'NoResize'; $panel.ShowInTaskbar = $false
$panel.SizeToContent = 'WidthAndHeight'; $panel.Background = Brush $Colors.Card
# 윈도우 11은 둥근 모서리·테두리를 시스템이 그린다. 윈도우 10은 얇은 테두리만.
$IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000
$panel.BorderBrush = Brush $Colors.Line
$panel.BorderThickness = New-Object System.Windows.Thickness $(if ($IsWin11) { 0 } else { 1 })
$panel.FontFamily = $FontFamily; $panel.Title = $Config.AppName; $panel.Icon = $AppIconImage
$panel.Resources.MergedDictionaries.Add($Styles)

$stack = New-Object System.Windows.Controls.StackPanel
$stack.Margin = New-Object System.Windows.Thickness 14, 14, 14, 8
$stack.Width = 224

# 머리: 앱 아이콘 + 이름 (끌어서 옮기는 손잡이) / 반 이름
$head = New-Object System.Windows.Controls.DockPanel
$head.Cursor = [System.Windows.Input.Cursors]::SizeAll
$head.ToolTip = '끌어서 옮길 수 있어요'
$head.Background = Brush $Colors.Card
$head.Margin = New-Object System.Windows.Thickness 2, 0, 0, 12
$logo = New-Object System.Windows.Controls.Image
$logo.Source = $AppIconImage; $logo.Width = 28; $logo.Height = 28
$logo.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
[System.Windows.Controls.DockPanel]::SetDock($logo, 'Left')
[void]$head.Children.Add($logo)
# 오른쪽 위 톱니바퀴: 설정 창 (반 이름, 수리 문의 링크 등)
$gear = New-Btn '' 'Icon' $null { Show-SettingsWindow } 0
$gear.Content = New-Glyph 0xE713 16
$gear.ToolTip = '설정'; $gear.VerticalAlignment = 'Center'
[System.Windows.Automation.AutomationProperties]::SetName($gear, '설정')
[System.Windows.Controls.DockPanel]::SetDock($gear, 'Right')
[void]$head.Children.Add($gear)
$headText = New-Object System.Windows.Controls.StackPanel
$headText.VerticalAlignment = 'Center'
[void]$headText.Children.Add((New-Text $Config.AppName 15 -Bold))
$script:PanelSub = New-Text '' 12 $Colors.Faint
[void]$headText.Children.Add($script:PanelSub)
[void]$head.Children.Add($headText)
[void]$stack.Children.Add($head)

function Update-PanelSub {
    $script:PanelSub.Text = if ($script:Settings.RoomName) { "$($script:Settings.RoomName) · 문제가 생기면 눌러요" } else { '문제가 생기면 눌러 보세요' }
}
Update-PanelSub

# 갈래 한 줄: 색 아이콘 + 이름 + 지금 상태(점 + 글자). 상태가 오기 전에는 갈래 설명을 보여 준다.
$script:StatusRows = @{}
$StatusColors = @{ ok = $Colors.Ok; warn = $Colors.Warn; bad = $Colors.Bad; info = '#B0B8C1' }
foreach ($key in $Groups.Keys) {
    $g = $Groups[$key]
    $b = New-Btn '' 'Item' $key { Show-Helper $this.Tag } 6
    $b.Padding = New-Object System.Windows.Thickness 10, 9, 12, 9
    [System.Windows.Automation.AutomationProperties]::SetName($b, "$($g.Name) 문제")
    $row = New-Object System.Windows.Controls.DockPanel
    $tile = New-IconTile $g.Icon $g.Tint $g.Ink 34 17 9
    $tile.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    [System.Windows.Controls.DockPanel]::SetDock($tile, 'Left')
    [void]$row.Children.Add($tile)
    $text = New-Object System.Windows.Controls.StackPanel
    $text.VerticalAlignment = 'Center'
    $name = New-Text $g.Name 14 -Bold
    $name.LineHeight = 20
    [void]$text.Children.Add($name)
    $line = New-Object System.Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 6; $dot.Height = 6; $dot.Margin = New-Object System.Windows.Thickness 0, 1, 5, 0
    $dot.VerticalAlignment = 'Center'; $dot.Visibility = 'Collapsed'
    $status = New-Text $g.Hint 12 $Colors.Faint
    $status.LineHeight = 17; $status.TextWrapping = 'NoWrap'; $status.TextTrimming = 'CharacterEllipsis'; $status.MaxWidth = 150
    [void]$line.Children.Add($dot); [void]$line.Children.Add($status)
    [void]$text.Children.Add($line)
    [void]$row.Children.Add($text)
    $b.Content = $row
    $script:StatusRows[$key] = @{ Dot = $dot; Text = $status }
    [void]$stack.Children.Add($b)
}
$panel.Content = $stack

function Update-PanelStatus($Status) {
    foreach ($key in $script:StatusRows.Keys) {
        $s = $Status[$key]
        if (-not $s) { continue }
        $row = $script:StatusRows[$key]
        $row.Text.Text = $s.Text
        $row.Text.Foreground = Brush $(if ($s.Level -eq 'bad') { $Colors.Bad } elseif ($s.Level -eq 'warn') { '#B45309' } else { $Colors.Faint })
        $row.Dot.Fill = Brush $StatusColors[$s.Level]
        $row.Dot.Visibility = 'Visible'
    }
}

# 패널을 숨기면 알림 영역(작업 표시줄 오른쪽 아래) 아이콘으로만 남는다.
function Set-PanelHidden([bool]$Hidden) {
    $script:Settings.Hidden = $Hidden
    Save-Settings
    if ($Hidden) {
        $panel.Hide()
        $tray.ShowBalloonTip(5000, $Config.AppName, "작업 표시줄 오른쪽 아래 아이콘으로 들어갔어요. 아이콘을 누르면 다시 나와요. (아이콘이 안 보이면 ^ 를 누르세요)", 'Info')
    } else {
        $panel.Show()
        if (-not $NoPin) { [PcHelper.Desk]::SendToBack((New-Object System.Windows.Interop.WindowInteropHelper $panel).Handle) }
    }
}

$menu = New-Object System.Windows.Controls.ContextMenu
$hide = New-Object System.Windows.Controls.MenuItem; $hide.Header = '작은 아이콘으로 숨기기'
$hide.Add_Click({ Set-PanelHidden $true })
$settingsItem = New-Object System.Windows.Controls.MenuItem; $settingsItem.Header = '설정'
$settingsItem.Add_Click({ Show-SettingsWindow })
$quit = New-Object System.Windows.Controls.MenuItem; $quit.Header = 'PC 도우미 끄기'
$quit.Add_Click({ [System.Windows.Application]::Current.Shutdown() })
$version = New-Object System.Windows.Controls.MenuItem; $version.Header = "버전 $(Get-AppVersion $AppDir)"; $version.IsEnabled = $false
foreach ($item in $hide, $settingsItem, $quit, $version) { [void]$menu.Items.Add($item) }
$panel.ContextMenu = $menu

# ───────────────────────── 알림 영역 아이콘 ─────────────────────────
# 왼쪽 클릭: 패널 보이기/숨기기. 오른쪽 클릭: 갈래 바로 열기와 메뉴.

[System.Windows.Forms.Application]::EnableVisualStyles()
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $AppIcon
$tray.Text = $Config.AppName
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font 'Malgun Gothic', 10
foreach ($key in $Groups.Keys) {
    $item = $trayMenu.Items.Add("$($Groups[$key].Name) 문제")
    $item.Tag = $key
    $item.Add_Click({ param($s) Show-Helper $s.Tag })
}
[void]$trayMenu.Items.Add('-')
$trayToggle = $trayMenu.Items.Add('패널 보이기')
$trayToggle.Add_Click({ Set-PanelHidden (-not $script:Settings.Hidden) })
[void]$trayMenu.Items.Add('설정').Add_Click({ Show-SettingsWindow })
# 저장소에서 바로 실행할 때는 바로가기가 엉뚱한 곳을 가리키게 되므로 설치본에서만 바꿀 수 있다.
$trayAuto = New-Object System.Windows.Forms.ToolStripMenuItem '윈도우 켤 때 자동 실행'
$trayAuto.Enabled = $AppDir -like "$env:LOCALAPPDATA\ClassroomPcHelper\*"
$trayAuto.Add_Click({
    $on = -not (Test-Path (Get-StartupShortcutPath))
    Set-AutoStart $AppDir $on
    $msg = if ($on) { '이제 윈도우를 켜면 PC 도우미가 자동으로 켜져요.' } else { '이제 윈도우를 켜도 자동으로 켜지지 않아요. 바탕화면 바로가기로 켤 수 있어요.' }
    $tray.ShowBalloonTip(4000, $Config.AppName, $msg, 'Info')
})
[void]$trayMenu.Items.Add($trayAuto)
[void]$trayMenu.Items.Add('PC 도우미 끄기').Add_Click({ [System.Windows.Application]::Current.Shutdown() })
$trayMenu.Add_Opening({
    $trayToggle.Text = $(if ($script:Settings.Hidden) { '패널 보이기' } else { '패널 숨기기' })
    $trayAuto.Checked = Test-Path (Get-StartupShortcutPath)
})
$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Set-PanelHidden (-not $script:Settings.Hidden) } })
$tray.Visible = $true
# 끌 때 아이콘을 치우지 않으면 마우스를 올릴 때까지 유령 아이콘이 남는다.
$app.Add_Exit({ $tray.Visible = $false; $tray.Dispose() })

$head.Add_MouseLeftButtonDown({
    $panel.DragMove()
    $script:Settings.Left = [math]::Round($panel.Left); $script:Settings.Top = [math]::Round($panel.Top)
    Save-Settings
})

# 위치: 저장된 곳이 화면 안이면 거기, 아니면 주 모니터 오른쪽 위.
$area = [System.Windows.SystemParameters]::WorkArea
$panel.Add_Loaded({
    $l = $script:Settings.Left; $t = $script:Settings.Top
    $inside = $null -ne $l -and $null -ne $t -and $l -ge [System.Windows.SystemParameters]::VirtualScreenLeft -and
              $l -lt ([System.Windows.SystemParameters]::VirtualScreenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth - 40) -and
              $t -ge [System.Windows.SystemParameters]::VirtualScreenTop -and
              $t -lt ([System.Windows.SystemParameters]::VirtualScreenTop + [System.Windows.SystemParameters]::VirtualScreenHeight - 40)
    if ($inside) { $panel.Left = $l; $panel.Top = $t }
    else { $panel.Left = $area.Right - $panel.ActualWidth - 24; $panel.Top = $area.Top + 24 }
})

$panel.Add_SourceInitialized({ [PcHelper.Desk]::Round((New-Object System.Windows.Interop.WindowInteropHelper $panel).Handle) })

if (-not $NoPin) {
    $panel.ShowActivated = $false
    $panel.Add_ContentRendered({ [PcHelper.Desk]::SendToBack((New-Object System.Windows.Interop.WindowInteropHelper $panel).Handle) })
    $panel.Add_SourceInitialized({
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $panel).Handle
        [PcHelper.Desk]::Pin($h)
    })
    # 패널을 누른 뒤에도 다른 창 위로 올라오지 않고 바탕화면 층으로 돌아간다.
    $panel.Add_Deactivated({ [PcHelper.Desk]::SendToBack((New-Object System.Windows.Interop.WindowInteropHelper $panel).Handle) })
}

# 자동 업데이트: 켜고 30초 뒤 한 번, 그 뒤로 6시간마다 확인한다.
# 도우미 창을 쓰는 중이면 다음 확인으로 미룬다. 새 버전을 깔았으면 스스로 다시 켠다.
$updateTimer = New-Object System.Windows.Threading.DispatcherTimer
$updateTimer.Interval = [TimeSpan]::FromSeconds(30)
$updateTimer.Add_Tick({
    $updateTimer.Interval = [TimeSpan]::FromHours(6)
    if ($script:Win -and $script:Win.IsVisible) { return }
    if (Install-Update $AppDir $Config.UpdateRepo) {
        $updateTimer.Stop()
        $mutex.ReleaseMutex()
        Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') (Get-LaunchArguments $AppDir)
        [System.Windows.Application]::Current.Shutdown()
    }
})
$updateTimer.Start()

# 1초마다: 바로가기에서 온 "패널 보여 줘" 신호, 패널 상태 줄(1분마다 새로 읽기)을 챙긴다.
$script:StatusNext = [DateTime]::Now.AddSeconds(2)
$tickTimer = New-Object System.Windows.Threading.DispatcherTimer
$tickTimer.Interval = [TimeSpan]::FromSeconds(1)
$tickTimer.Add_Tick({
    if ($showSignal.WaitOne(0)) { Set-PanelHidden $false }
    $s = Receive-PanelStatus
    if ($s) { Update-PanelStatus $s }
    if ($panel.IsVisible -and [DateTime]::Now -ge $script:StatusNext) {
        $script:StatusNext = [DateTime]::Now.AddSeconds(60)
        Start-PanelStatus
    }
})
$tickTimer.Start()

if (-not $script:Settings.Hidden) { $panel.Show() }
if ($Open -and $Groups.Contains($Open)) { Show-Helper $Open }
[void]$app.Run()
try { $mutex.ReleaseMutex() } catch { }
