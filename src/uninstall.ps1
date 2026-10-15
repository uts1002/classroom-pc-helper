# PC 도우미 제거 — 프로그램, 시작 프로그램 등록, 바탕화면 바로가기, '설치된 앱' 목록 등록을 지운다.
# 윈도우 설정 > 앱 > 설치된 앱에서 [제거]를 누르면 이 파일이 실행된다.
# 반 이름 등 설정(%APPDATA%\ClassroomPcHelper)은 남겨 둔다. 다시 설치하면 그대로 쓴다.

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object CommandLine -like '*ClassroomPcHelper*PcHelper.ps1*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop')) {
    $lnk = Join-Path $folder 'PC 도우미.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassroomPcHelper' -Recurse -Force -ErrorAction SilentlyContinue

# 이 파일이 들어 있는 폴더를 지우므로 다른 곳으로 옮겨 놓고 지운다.
Set-Location $env:TEMP
Start-Sleep -Milliseconds 500
$app = Join-Path $env:LOCALAPPDATA 'ClassroomPcHelper'
if (Test-Path $app) { Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue }

# 설정 창 뒤에 숨으면 지워진 줄 모르므로 맨 앞에 띄운다.
Add-Type -AssemblyName PresentationFramework
$w = New-Object System.Windows.Window
$w.Title = 'PC 도우미'; $w.Topmost = $true; $w.SizeToContent = 'WidthAndHeight'; $w.ResizeMode = 'NoResize'
$w.WindowStartupLocation = 'CenterScreen'; $w.FontFamily = 'Malgun Gothic'
$p = New-Object System.Windows.Controls.StackPanel
$p.Margin = New-Object System.Windows.Thickness 28, 24, 28, 20
$t = New-Object System.Windows.Controls.TextBlock
$t.Text = 'PC 도우미를 지웠어요.'; $t.FontSize = 16
$ok = New-Object System.Windows.Controls.Button
$ok.Content = '확인'; $ok.Width = 96; $ok.Padding = New-Object System.Windows.Thickness 0, 6, 0, 6
$ok.Margin = New-Object System.Windows.Thickness 0, 18, 0, 0; $ok.HorizontalAlignment = 'Right'
$ok.IsDefault = $true; $ok.IsCancel = $true
$ok.Add_Click({ $w.Close() })
[void]$p.Children.Add($t); [void]$p.Children.Add($ok)
$w.Content = $p
$w.Add_ContentRendered({ $w.Activate() | Out-Null })
[void]$w.ShowDialog()
