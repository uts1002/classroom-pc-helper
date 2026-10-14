# PC 도우미 설치 — 지금 로그인한 사용자에게만 설치한다 (관리자 권한 필요 없음).
#  1. 프로그램을 %LOCALAPPDATA%\ClassroomPcHelper\app 에 넣는다
#     - 옆에 src 폴더가 있으면 그것을 (저장소에서 직접 설치)
#     - 없으면 GitHub 최신 릴리즈의 app.zip 을 받아서 (PcHelper-Setup.cmd 로 설치)
#  2. 로그인할 때 자동으로 켜지게 시작 프로그램에 등록
#  3. 바탕화면에 바로가기 (실수로 껐을 때 다시 켜는 용도)
#  4. 바로 실행. 이후 새 버전은 프로그램이 알아서 받는다.

param([string]$Repo = 'uts1002/classroom-pc-helper')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$dest = Join-Path $env:LOCALAPPDATA 'ClassroomPcHelper\app'

# 이미 켜져 있으면 끄고 덮어쓴다.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object CommandLine -like '*ClassroomPcHelper*PcHelper.ps1*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

$localSrc = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'src' } else { $null }
if ($localSrc -and (Test-Path (Join-Path $localSrc 'PcHelper.ps1'))) {
    $src = $localSrc
} else {
    Write-Host '최신 버전을 받고 있어요...'
    $work = Join-Path $env:TEMP 'ClassroomPcHelper-setup'
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'app.zip'
    Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest/download/app.zip" -OutFile $zip -UseBasicParsing
    $src = Join-Path $work 'app'
    Expand-Archive -Path $zip -DestinationPath $src -Force
}

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
    $lnk.WorkingDirectory = $env:LOCALAPPDATA
    $lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,109"
    $lnk.Description = '교실 PC 문제 점검·수리 도우미'
    $lnk.Save()
}

Start-Process $target $arguments
$version = (Get-Content (Join-Path $dest 'version.txt') -Raw).Trim()
Write-Host "PC 도우미 $version 을(를) 설치했어요. 바탕화면 오른쪽 위에 떠요."
