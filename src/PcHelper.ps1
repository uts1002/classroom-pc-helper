# 교실 PC 도우미 — 바탕화면에 붙어 있는 작은 패널.
# 고장 현상 고르기 → 현재 상태 점검 → 자동 수리 또는 안내 → 안 되면 밴드로.
#
# 실행: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File PcHelper.ps1
#   -NoPin        바탕화면에 고정하지 않고 보통 창으로 띄움 (테스트용)
#   -Open <갈래>  켜자마자 도우미 창을 연다: display | audio | print | net (테스트용)

param([switch]$NoPin, [string]$Open)

$ErrorActionPreference = 'Continue'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 같은 사용자로 두 번 켜지지 않게 한다 (시작 프로그램 + 바탕화면 바로가기).
$mutex = New-Object System.Threading.Mutex($false, "Local\ClassroomPcHelper")
if (-not $mutex.WaitOne(0)) { return }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
. (Join-Path $AppDir 'lib\Native.ps1')
. (Join-Path $AppDir 'lib\Checks.ps1')

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

# ───────────────────────── 사용자 설정 (반 이름, 패널 위치) ─────────────────────────

$SettingsPath = Join-Path $env:APPDATA 'ClassroomPcHelper\settings.json'

function Get-Settings {
    $s = @{ RoomName = ''; Left = $null; Top = $null }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in 'RoomName', 'Left', 'Top') { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch { }
    }
    $s
}

function Save-Settings {
    $dir = Split-Path $SettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8
}

$script:Settings = Get-Settings

# ───────────────────────── 증상 목록 ─────────────────────────

$Groups = [ordered]@{
    display = @{ Name = '화면'; Hint = 'TV·전자칠판·듀얼 모니터'; Symptoms = @(
        @{ Text = '한쪽 화면(TV·전자칠판)이 안 나와요'; Check = { Test-DisplayMissing } }
        @{ Text = '학생 화면에 내 작업 화면이 그대로 보여요'; Check = { Test-DisplayMirrored } }
        @{ Text = 'TV에 내 화면을 똑같이 띄우고 싶어요'; Check = { Test-DisplaySame } }
        @{ Text = '글씨·아이콘이 갑자기 커졌어요 (작아졌어요)'; Check = { Test-DisplayScale } }
        @{ Text = '마우스가 옆 화면으로 안 넘어가요 / 방향이 반대예요'; Check = { Test-DisplayMouse } }
    ) }
    audio = @{ Name = '소리'; Hint = '스피커·TV 소리·잡음'; Symptoms = @(
        @{ Text = '교실 스피커로 소리가 안 나요 (TV로는 나요)'; Check = { Test-AudioTarget -WantTv $false } }
        @{ Text = 'TV(전자칠판)에서 소리가 안 나요'; Check = { Test-AudioTarget -WantTv $true } }
        @{ Text = '소리가 아예 안 나요'; Check = { Test-AudioNone } }
        @{ Text = '지직거리는 잡음, 삐 소리가 나요'; Check = { Test-AudioNoise } }
    ) }
    print = @{ Name = '프린터'; Hint = '인쇄·용지 걸림'; Symptoms = @(
        @{ Text = '인쇄가 안 돼요'; Check = { Test-PrintFail } }
        @{ Text = '다른 반(엉뚱한) 프린터로 나가요'; Check = { Test-PrintWrong } }
        @{ Text = '종이가 걸렸다고 떠요'; Check = { Test-PrintJam } }
        @{ Text = '쓰려는 프린터가 목록에 없어요'; Check = { Test-PrintMissing } }
    ) }
    net = @{ Name = '인터넷'; Hint = '인터넷·사이트 접속'; Symptoms = @(
        @{ Text = '인터넷이 안 돼요'; Check = { Test-NetDown } }
        @{ Text = '특정 사이트·업무포털만 안 열려요'; Check = { Test-NetDown } }
    ) }
}

# ───────────────────────── 공통 화면 조각 ─────────────────────────

$Colors = @{
    Primary = '#2563EB'; PrimaryHover = '#1D4ED8'; PrimaryLight = '#DBEAFE'
    Text = '#191F28'; Sub = '#4E5968'; Faint = '#8B95A1'; Line = '#E5E8EB'; Bg = '#F2F4F6'; Card = '#FFFFFF'
    Ok = '#16A34A'; Warn = '#D97706'; Bad = '#DC2626'
}

$StyleXaml = @"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="Base" TargetType="Button">
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontSize" Value="15"/>
    <Setter Property="Padding" Value="16,12"/>
    <Setter Property="HorizontalContentAlignment" Value="Left"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.75"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Base}">
    <Setter Property="Background" Value="$($Colors.Primary)"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
  </Style>
  <Style x:Key="Soft" TargetType="Button" BasedOn="{StaticResource Base}">
    <Setter Property="Background" Value="$($Colors.PrimaryLight)"/>
    <Setter Property="Foreground" Value="$($Colors.PrimaryHover)"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
  </Style>
  <Style x:Key="Item" TargetType="Button" BasedOn="{StaticResource Base}">
    <Setter Property="Background" Value="$($Colors.Card)"/>
    <Setter Property="Foreground" Value="$($Colors.Text)"/>
    <Setter Property="BorderBrush" Value="$($Colors.Line)"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="18,16"/>
  </Style>
  <Style x:Key="Plain" TargetType="Button" BasedOn="{StaticResource Base}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="$($Colors.Sub)"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
  </Style>
</ResourceDictionary>
"@
$Styles = [Windows.Markup.XamlReader]::Parse($StyleXaml)
$FontFamily = New-Object System.Windows.Media.FontFamily 'Pretendard, Malgun Gothic'

function Brush([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

function New-Text {
    param([string]$Text, [double]$Size = 15, [string]$Color = $Colors.Text, [switch]$Bold, [double]$Bottom = 0)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Brush $Color; $t.TextWrapping = 'Wrap'
    $t.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    $t.LineHeight = [math]::Round($Size * 1.5)
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    $t
}

function New-Btn {
    param([string]$Text, [string]$Style = 'Item', $Tag, [scriptblock]$OnClick, [double]$Bottom = 8)
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $Styles[$Style]
    if ($Text) {
        # 긴 장치 이름도 잘리지 않게 줄바꿈되는 글자로 넣는다.
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $Text; $label.TextWrapping = 'Wrap'
        if ($Style -ne 'Item') { $label.TextAlignment = 'Center' }
        $b.Content = $label
        [System.Windows.Automation.AutomationProperties]::SetName($b, $Text)
    }
    $b.Tag = $Tag
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, $Bottom
    if ($OnClick) { $b.Add_Click($OnClick) }
    $b
}

function New-Box {
    param([string]$Background = $Colors.Bg, [double]$Bottom = 16)
    $border = New-Object System.Windows.Controls.Border
    $border.Background = Brush $Background
    $border.CornerRadius = New-Object System.Windows.CornerRadius 10
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
        $w.Title = $Config.AppName
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
    if ($Back) {
        $b = New-Btn '‹ 처음으로' 'Plain' $null { Show-Symptoms } 6
        $b.HorizontalAlignment = 'Left'; $b.Padding = New-Object System.Windows.Thickness 0, 4, 8, 4
        [void]$script:Header.Children.Add($b)
    }
    [void]$script:Header.Children.Add((New-Text $Title 22 -Bold -Bottom 4))
    if ($Sub) { [void]$script:Header.Children.Add((New-Text $Sub 14 $Colors.Sub)) }
}

function Show-Symptoms {
    $g = $Groups[$script:State.Group]
    $script:State.Symptom = $null; $script:State.Result = $null; $script:State.Done = @(); $script:State.Notice = ''
    Set-Header "$($g.Name) 문제" '어떤 증상인가요? 비슷한 것을 눌러 주세요.' $false
    $script:Body.Children.Clear(); $script:Footer.Children.Clear()
    foreach ($sym in $g.Symptoms) {
        [void]$script:Body.Children.Add((New-Btn $sym.Text 'Item' $sym { Start-Check $this.Tag }))
    }
    $other = New-Btn '여기 없는 문제예요 → 밴드에 올리기' 'Plain' $null { Send-ToBand -Symptom '목록에 없는 문제' }
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

function Show-Result {
    $r = $script:State.Result
    $script:Body.Children.Clear(); $script:Footer.Children.Clear()

    if ($script:State.Notice) {
        $n = New-Box $Colors.PrimaryLight
        [void]$n.Stack.Children.Add((New-Text $script:State.Notice 15 $Colors.PrimaryHover -Bold))
        [void]$script:Body.Children.Add($n.Border)
    }

    $tone = switch ($r.Tone) {
        'ok'    { @{ Label = '정상이에요'; Color = $Colors.Ok } }
        'fix'   { @{ Label = '바로 고칠 수 있어요'; Color = $Colors.Primary } }
        'guide' { @{ Label = '직접 확인해 주세요'; Color = $Colors.Warn } }
        default { @{ Label = '밴드에 올려 주세요'; Color = $Colors.Bad } }
    }
    [void]$script:Body.Children.Add((New-Text $tone.Label 14 $tone.Color -Bold -Bottom 4))
    [void]$script:Body.Children.Add((New-Text $r.Title 18 -Bold -Bottom 16))

    foreach ($a in $r.Actions) {
        [void]$script:Body.Children.Add((New-Btn $a.Label 'Primary' $a { Invoke-Fix $this.Tag }))
    }
    if ($r.Actions.Count -gt 0) { [void]$script:Body.Children.Add((New-Text '' 4 -Bottom 8)) }

    if ($r.Steps.Count -gt 0) {
        [void]$script:Body.Children.Add((New-Text '이렇게 해 보세요' 15 -Bold -Bottom 8))
        $i = 1
        foreach ($s in $r.Steps) { [void]$script:Body.Children.Add((New-Text "$i.  $s" 15 $Colors.Text -Bottom 6)); $i++ }
        [void]$script:Body.Children.Add((New-Text '' 4 -Bottom 10))
    }

    if ($r.Facts.Count -gt 0) {
        $box = New-Box
        [void]$box.Stack.Children.Add((New-Text '점검 결과' 13 $Colors.Faint -Bold -Bottom 6))
        foreach ($f in $r.Facts) { [void]$box.Stack.Children.Add((New-Text "· $f" 13 $Colors.Sub -Bottom 2)) }
        [void]$script:Body.Children.Add($box.Border)
    }

    $row = New-Object System.Windows.Controls.Primitives.UniformGrid
    $row.Columns = 2
    $again = New-Btn '다시 점검' 'Soft' $null { $script:State.Notice = ''; Start-Check $script:State.Symptom } 0
    $again.Margin = New-Object System.Windows.Thickness 0, 0, 4, 8
    $done = New-Btn '해결됐어요' 'Soft' $null { $script:Win.Hide() } 0
    $done.Margin = New-Object System.Windows.Thickness 4, 0, 0, 8
    [void]$row.Children.Add($again); [void]$row.Children.Add($done)
    [void]$script:Footer.Children.Add($row)
    [void]$script:Footer.Children.Add((New-Btn '그래도 안 돼요 → 밴드에 올리기' 'Primary' $null { Send-ToBand } 0))
    $script:Scroll.ScrollToTop()
}

function Invoke-Fix($Action) {
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    Update-Ui
    try {
        $msg = (& $Action.Run | Select-Object -Last 1)
        $script:State.Done += $Action.Label
    } catch {
        $msg = "고치지 못했어요: $($_.Exception.Message)"
        $script:State.Done += "$($Action.Label) (실패)"
    }
    $script:Win.Cursor = $null
    # 고친 뒤 다시 점검해서 바뀐 상태를 보여 준다.
    try { $script:State.Result = & $script:State.Symptom.Check } catch { }
    $script:State.Notice = $msg
    Show-Result
}

# ───────────────────────── 밴드로 보내기 ─────────────────────────

function Read-RoomName {
    $d = New-Object System.Windows.Window
    $d.Title = $Config.AppName; $d.Width = 380; $d.SizeToContent = 'Height'; $d.ResizeMode = 'NoResize'
    $d.WindowStartupLocation = 'CenterOwner'; $d.Owner = $script:Win; $d.FontFamily = $FontFamily
    $d.Resources.MergedDictionaries.Add($Styles)
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Margin = New-Object System.Windows.Thickness 24
    $label = New-Text '우리 반(교실) 이름' 15 -Bold -Bottom 4
    [void]$p.Children.Add($label)
    [void]$p.Children.Add((New-Text '밴드 글 맨 앞에 붙어요. 한 번만 적으면 기억해요.' 13 $Colors.Sub -Bottom 10))
    $box = New-Object System.Windows.Controls.TextBox
    $box.FontSize = 16; $box.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
    $box.Text = $script:Settings.RoomName
    [System.Windows.Automation.AutomationProperties]::SetLabeledBy($box, $label)
    [void]$p.Children.Add($box)
    [void]$p.Children.Add((New-Text '예: 5-빛솔, 4학년 연구실, 돌봄3반' 13 $Colors.Faint -Bottom 14))
    $ok = New-Btn '확인' 'Primary' $null { $d.DialogResult = $true } 0
    $ok.IsDefault = $true
    [void]$p.Children.Add($ok)
    $d.Content = $p
    $d.Add_ContentRendered({ $box.Focus() | Out-Null })
    if ($d.ShowDialog()) { return $box.Text.Trim() }
    $null
}

function Send-ToBand([string]$Symptom) {
    if (-not $script:Settings.RoomName) {
        $name = Read-RoomName
        if (-not $name) { return }
        $script:Settings.RoomName = $name
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
    Start-Process $Config.BandUrl

    $script:State.Notice = "$($Config.BandName)를 열었어요. [글쓰기]를 누르고 Ctrl+V로 붙여 넣으세요. 점검 내용이 복사돼 있어요."
    if ($r) { Show-Result } else {
        $script:Body.Children.Clear()
        $n = New-Box $Colors.PrimaryLight
        [void]$n.Stack.Children.Add((New-Text $script:State.Notice 15 $Colors.PrimaryHover -Bold))
        [void]$script:Body.Children.Add($n.Border)
        [void]$script:Body.Children.Add((New-Text '증상을 자세히 적어 주세요. (언제부터, 어떤 화면이 뜨는지, 사진이 있으면 함께)' 15 $Colors.Sub))
    }
}

# ───────────────────────── 바탕화면 패널 ─────────────────────────

$panel = New-Object System.Windows.Window
$panel.WindowStyle = 'None'; $panel.ResizeMode = 'NoResize'; $panel.ShowInTaskbar = $false
$panel.SizeToContent = 'WidthAndHeight'; $panel.Background = Brush $Colors.Card
$panel.BorderBrush = Brush $Colors.Line; $panel.BorderThickness = New-Object System.Windows.Thickness 1
$panel.FontFamily = $FontFamily; $panel.Title = $Config.AppName
$panel.Resources.MergedDictionaries.Add($Styles)

$stack = New-Object System.Windows.Controls.StackPanel
$stack.Margin = New-Object System.Windows.Thickness 16, 14, 16, 8
$stack.Width = 196
$title = New-Text $Config.AppName 16 -Bold -Bottom 2
$title.Cursor = [System.Windows.Input.Cursors]::SizeAll
$title.ToolTip = '끌어서 옮길 수 있어요'
[void]$stack.Children.Add($title)
[void]$stack.Children.Add((New-Text '문제가 생기면 눌러 보세요' 12 $Colors.Sub -Bottom 10))
foreach ($key in $Groups.Keys) {
    $g = $Groups[$key]
    $b = New-Btn '' 'Item' $key { Show-Helper $this.Tag } 6
    $b.Padding = New-Object System.Windows.Thickness 14, 10, 14, 10
    $content = New-Object System.Windows.Controls.StackPanel
    [void]$content.Children.Add((New-Text $g.Name 15 -Bold))
    [void]$content.Children.Add((New-Text $g.Hint 12 $Colors.Faint))
    $b.Content = $content
    [void]$stack.Children.Add($b)
}
$panel.Content = $stack

$menu = New-Object System.Windows.Controls.ContextMenu
$reset = New-Object System.Windows.Controls.MenuItem; $reset.Header = '반 이름 다시 정하기'
$reset.Add_Click({ $script:Settings.RoomName = ''; Save-Settings })
$quit = New-Object System.Windows.Controls.MenuItem; $quit.Header = 'PC 도우미 끄기'
$quit.Add_Click({ [System.Windows.Application]::Current.Shutdown() })
[void]$menu.Items.Add($reset); [void]$menu.Items.Add($quit)
$panel.ContextMenu = $menu

$title.Add_MouseLeftButtonDown({
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

$panel.Show()
if ($Open -and $Groups.Contains($Open)) { Show-Helper $Open }
[void]$app.Run()
$mutex.ReleaseMutex()
