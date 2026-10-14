# 새 버전 내보내기: 태그를 만들어 올리면 GitHub가 릴리즈를 만들고,
# 설치된 PC들은 6시간 안에(또는 다음 로그인 때) 알아서 새 버전을 받는다.
#   .\release.ps1 0.2.0 "터치 갈래 추가"

param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Notes
)
$ErrorActionPreference = 'Stop'
[void][version]$Version
if (git status --porcelain) { throw '커밋하지 않은 변경이 있어요. 먼저 커밋하세요.' }
git tag -a "v$Version" -m $Notes
git push origin HEAD
git push origin "v$Version"
Write-Host "v$Version 태그를 올렸어요. 릴리즈는 1~2분 뒤 https://github.com/uts1002/classroom-pc-helper/releases 에 생겨요."
