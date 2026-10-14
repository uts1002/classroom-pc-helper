# PC 도우미 제거 — 프로그램, 시작 프로그램 등록, 바탕화면 바로가기를 지운다.
# 반 이름 등 설정(%APPDATA%\ClassroomPcHelper)은 남겨 둔다. 다시 설치하면 그대로 쓴다.

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object CommandLine -like '*ClassroomPcHelper*PcHelper.ps1*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop')) {
    $lnk = Join-Path $folder 'PC 도우미.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
}
$app = Join-Path $env:LOCALAPPDATA 'ClassroomPcHelper'
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
Write-Host 'PC 도우미를 지웠어요.'
