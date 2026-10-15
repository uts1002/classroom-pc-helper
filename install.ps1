# PC 도우미 설치 — 지금 로그인한 사용자에게만 설치한다 (관리자 권한 필요 없음).
#  1. 프로그램을 %LOCALAPPDATA%\ClassroomPcHelper\app 에 넣는다
#     - 옆에 src 폴더가 있으면 그것을 (저장소에서 직접 설치)
#     - 없으면 GitHub 최신 릴리즈의 app.zip 을 받아서 (PcHelper-Setup.cmd 로 설치)
#  2. 로그인할 때 자동으로 켜지게 시작 프로그램에 등록
#  3. 바탕화면에 바로가기 (실수로 껐을 때 다시 켜는 용도)
#  4. 윈도우 '설치된 앱' 목록에 등록 (거기서 [제거]로 지울 수 있게)
#  5. 바로 실행. 이후 새 버전은 프로그램이 알아서 받는다.
#
#  -General: 다른 학교용. 문의 링크(다정초 밴드)를 비워 두어 처음 문의할 때 선생님이 주소를 적게 한다.
#            설정은 프로그램 폴더 밖(%APPDATA%)에 두므로 자동 업데이트로 덮어써지지 않는다.

param([string]$Repo = 'uts1002/classroom-pc-helper', [switch]$General)

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

. (Join-Path $dest 'lib\Update.ps1')

# 윈도우 켤 때 자동 실행(기본으로 켬, 알림 영역 메뉴에서 끌 수 있음) + 바탕화면 바로가기
Set-AutoStart $dest $true
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'PC 도우미.lnk'))
$lnk.TargetPath = $target
$lnk.Arguments = $arguments
$lnk.WorkingDirectory = $env:LOCALAPPDATA
$lnk.IconLocation = "$(Join-Path $dest 'icon.ico'),0"
$lnk.Description = '교실 PC 문제 점검·수리 도우미'
$lnk.Save()

# 윈도우 '설치된 앱' 목록에 올려서 거기서 지울 수 있게 한다.
Register-AppEntry $dest

# 다른 학교용: 문의 링크를 빈 값으로 적어 둔다. 이미 링크를 적어 둔 PC는 그대로 둔다.
if ($General) {
    $settingsPath = Join-Path $env:APPDATA 'ClassroomPcHelper\settings.json'
    $settings = [ordered]@{}
    if (Test-Path $settingsPath) {
        try { (Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } } catch { }
    }
    if ($null -eq $settings['BandUrl']) {
        $settings['BandUrl'] = ''
        New-Item -ItemType Directory -Path (Split-Path $settingsPath) -Force | Out-Null
        [pscustomobject]$settings | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
    }
}

Start-Process $target $arguments
$version = (Get-Content (Join-Path $dest 'version.txt') -Raw).Trim()
Write-Host "PC 도우미 $version 을(를) 설치했어요. 바탕화면 오른쪽 위에 떠요."
