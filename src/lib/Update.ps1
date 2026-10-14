# 자동 업데이트 — GitHub 릴리즈의 최신 버전을 받아 지금 설치된 폴더에 덮어쓴다.
#   https://github.com/<UpdateRepo>/releases/latest/download/version.txt   최신 버전 번호
#   https://github.com/<UpdateRepo>/releases/latest/download/app.zip       프로그램 묶음
# 저장소에서 바로 실행할 때(version.txt가 dev)는 업데이트하지 않는다.

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-AppVersion([string]$AppDir) {
    $path = Join-Path $AppDir 'version.txt'
    if (Test-Path $path) { (Get-Content $path -Raw).Trim() } else { '0.0.0-dev' }
}

function Get-LatestVersion([string]$Repo) {
    $url = "https://github.com/$Repo/releases/latest/download/version.txt"
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
    $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    $text.Trim()
}

# 새 버전이 있으면 받아서 설치하고 $true. 없거나 실패하면 $false (수업 중 방해하지 않게 조용히 넘어간다).
function Install-Update([string]$AppDir, [string]$Repo) {
    $current = Get-AppVersion $AppDir
    if ($current -match 'dev') { return $false }
    try {
        $latest = Get-LatestVersion $Repo
        if ([version]$latest -le [version]$current) { return $false }

        $work = Join-Path $env:TEMP "ClassroomPcHelper-update-$latest"
        if (Test-Path $work) { Remove-Item $work -Recurse -Force }
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $work 'app.zip'
        Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest/download/app.zip" -OutFile $zip -UseBasicParsing -TimeoutSec 60
        $unpacked = Join-Path $work 'app'
        Expand-Archive -Path $zip -DestinationPath $unpacked -Force

        # 받은 묶음이 온전한지 확인한 뒤에만 덮어쓴다.
        if (-not (Test-Path (Join-Path $unpacked 'PcHelper.ps1'))) { return $false }
        if ((Get-AppVersion $unpacked) -ne $latest) { return $false }

        Copy-Item (Join-Path $unpacked '*') $AppDir -Recurse -Force
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# 예전 버전이 만든 바로가기(톱니바퀴 아이콘)를 앱 아이콘으로 바꾼다. 이 설치본을 가리키는 바로가기만 건드린다.
function Update-ShortcutIcon([string]$AppDir) {
    $icon = Join-Path $AppDir 'icon.ico'
    if (-not (Test-Path $icon)) { return }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($folder in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop')) {
            $path = Join-Path $folder 'PC 도우미.lnk'
            if (-not (Test-Path $path)) { continue }
            $lnk = $shell.CreateShortcut($path)
            if ($lnk.Arguments -notlike "*$AppDir*" -or $lnk.IconLocation -like "$icon*") { continue }
            $lnk.IconLocation = "$icon,0"
            $lnk.Save()
        }
    } catch { }
}

function Get-LaunchArguments([string]$AppDir) {
    "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$(Join-Path $AppDir 'PcHelper.ps1')`""
}
