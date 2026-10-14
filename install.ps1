# PC 도우미 설치 — 지금 로그인한 사용자에게만 설치한다 (관리자 권한 필요 없음).
#  1. 프로그램을 %LOCALAPPDATA%\ClassroomPcHelper\app 으로 복사
#  2. 로그인할 때 자동으로 켜지게 시작 프로그램에 등록
#  3. 바탕화면에 바로가기 (실수로 껐을 때 다시 켜는 용도)
#  4. 바로 실행

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
$dest = Join-Path $env:LOCALAPPDATA 'ClassroomPcHelper\app'

# 이미 켜져 있으면 끄고 덮어쓴다.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object CommandLine -like '*ClassroomPcHelper*PcHelper.ps1*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item (Join-Path $src '*') $dest -Recurse -Force

$script = Join-Path $dest 'PcHelper.ps1'
$target = Join-Path $env:WINDIR 'System32\conhost.exe'
$arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$script`""

$shell = New-Object -ComObject WScript.Shell
foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop')) {
    $lnk = $shell.CreateShortcut((Join-Path $folder 'PC 도우미.lnk'))
    $lnk.TargetPath = $target
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = $dest
    $lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,109"
    $lnk.Description = '교실 PC 문제 점검·수리 도우미'
    $lnk.Save()
}

Start-Process $target $arguments
Write-Host '설치했어요. 바탕화면 오른쪽 위에 PC 도우미가 떠요.'
