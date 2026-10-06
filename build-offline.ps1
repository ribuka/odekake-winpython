<#
.SYNOPSIS
    uv プロジェクトを、WinPython 同梱のオフライン持ち出し用 ZIP にする。

.DESCRIPTION
    仕様は docs/spec.md を参照。
    設定の優先順位: 引数 > config\settings.local.json > config\settings.json > 既定値

.EXAMPLE
    .\build-offline.ps1 -ProjectRoot D:\work\foo -Groups gui -Exclude 'docs/**','tests'
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ConfigPath,
    [string]$PythonVersion,
    [string]$OutputDir,
    [switch]$TrackedOnly,
    [string[]]$Groups,
    [string[]]$Extras,
    [string[]]$Exclude,
    [switch]$PruneWinPython,
    [string]$ImportName,
    [string]$Installer,
    [switch]$NoPopup
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # 5.1 の Invoke-WebRequest は進捗表示があると極端に遅い

# ---------------------------------------------------------------------------
# 固定値
# ---------------------------------------------------------------------------

# WinPython dot 版。リリースは行ごとに固定する(spec §5)。URL は規則から組み立てず完全な形で持つ。
$WinPythonTable = @{
    '3.12' = @{   # 2025-03 リリース(3.12 がある最後の安定版)
        Url    = 'https://github.com/winpython/winpython/releases/download/16.6.20250620final/Winpython64-3.12.10.1dot.zip'
        Sha256 = '7a1f004aec39615977b2b245423a50115530d16af3418df77977186a555d0a40'
    }
    '3.13' = @{   # 2026-03 リリース
        Url    = 'https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.13.15.0dot.zip'
        Sha256 = '28e36408f0140c50b207ea059a599c664564e68a3cbb835f03a71f4601efd8f1'
    }
    '3.14' = @{   # 2026-03 リリース
        Url    = 'https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.14.7.0dot.zip'
        Sha256 = 'dbabedfb50eeb3c2c63dc43c9cb6239eae4a582c3bfd9a5f2ffd00a09b49a527'
    }
}

# pruneWinPython で消す、WinPython 最上位の項目(spec §8)
$PruneTargets = @(
    'Jupyter Lab.exe', 'Jupyter Notebook.exe', 'Spyder.exe', 'Spyder reset.exe', 'VS Code.exe',
    'notebooks', 'wheelhouse'
)

# 設定キーと型。引数名はキーの先頭を大文字にしたもの。
# 型が配列のキーは、その中の値だけを受け付ける(大文字小文字も区別する)。既定値は先頭の値。
$SettingTypes = [ordered]@{
    pythonVersion    = 'string'
    outputDir        = 'string'
    trackedOnly      = 'bool'
    groups           = 'array'
    extras           = 'array'
    exclude          = 'array'
    pruneWinPython   = 'bool'
    importName       = 'string'
    installer        = @('uv', 'pip')
    noPopup          = 'bool'
}

# pip モードで入れられる index(uv.lock の registry)。これ以外の index の依存があればエラーにする。
$PyPIIndexUrl = 'https://pypi.org/simple'

$PthFileName = 'odekake-src.pth'
$PthContent  = '..\..\..\..\src'

# 子プロセス(uv, pip, python)に影響する環境変数。終了時に元に戻す。
$EnvOverrides = @{
    PYTHONPATH       = $null
    PYTHONHOME       = $null
    PYTHONSTARTUP    = $null
    VIRTUAL_ENV      = $null
    PYTHONNOUSERSITE = '1'
    PYTHONIOENCODING = 'utf-8'
    PYTHONUTF8       = '1'
}

$RepoRoot = $PSScriptRoot
$BuildDir = Join-Path $RepoRoot '.build'
$WorkDir  = Join-Path $BuildDir 'work'
$LogDir   = Join-Path $RepoRoot 'logs'

$StartTime = Get-Date
$Timestamp = $StartTime.ToString("yyyyMMdd'T'HHmmss")
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 関数は lib\*.ps1 に分けてある(spec §14)
foreach ($f in 'Log', 'Settings', 'Project', 'WinPython', 'Zip', 'Gui') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

function Invoke-Build {
    param([hashtable]$bound)
    $script:NoPopupEffective = [bool]$NoPopup

    Write-Log "odekake-winpython ビルド開始: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "PowerShell $($PSVersionTable.PSVersion)"

    # --- 設定と対象プロジェクト ---
    $cfg = Get-EffectiveSettings $bound $SettingTypes $RepoRoot
    $script:NoPopupEffective = $cfg.noPopup

    if ($bound.ContainsKey('ProjectRoot')) {
        $root = Resolve-FullPath $bound['ProjectRoot']
    } else {
        $selected = Select-ProjectFolder
        if (-not $selected) {
            Write-Host 'フォルダが選ばれなかったので、何もせず終了します。'
            $script:Cancelled = $true
            return
        }
        $root = $selected
    }
    $root = $root.TrimEnd('\')
    Write-Log "対象プロジェクト: $root"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "対象プロジェクトのフォルダがありません: $root" }
    foreach ($required in @('pyproject.toml', 'uv.lock')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) {
            throw "対象プロジェクトに $required がありません: $root"
        }
    }

    foreach ($tool in @('git', 'uv')) {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "$tool が見つかりません。インストールして PATH を通してください。"
        }
    }
    $insideGit = $false
    try { $insideGit = ((Invoke-Native git @('-C', $root, 'rev-parse', '--is-inside-work-tree') -Capture) -join '') -eq 'true' } catch { }
    if (-not $insideGit) { throw "対象プロジェクトが git リポジトリではありません(ZIP に入れるファイルを .gitignore で決めるため必要です): $root" }

    # --- 名前・バージョン ---
    $py = Read-PyProject (Join-Path $root 'pyproject.toml')
    if (-not $py.Name) { throw 'pyproject.toml の [project] に name がありません。' }
    $name = $py.Name -replace '_', '-'
    Open-LogFile $name $LogDir $Timestamp
    $version = Get-ProjectVersion $root $py
    $importName = if ($cfg.importName) { $cfg.importName } else { $py.Name -replace '-', '_' }
    Write-Log "name: $name / version: $version / import 確認: $importName"

    $minor = Get-PythonMinor $root $bound['PythonVersion'] $cfg.pythonVersion
    if (-not $WinPythonTable.ContainsKey($minor)) {
        throw "Python $minor に対応する WinPython は登録されていません。対応: $(($WinPythonTable.Keys | Sort-Object) -join ', ')"
    }
    $winPython = $WinPythonTable[$minor]

    $outDir = if ($cfg.outputDir) { Resolve-FullPath $cfg.outputDir } else { Get-DownloadsFolder }
    if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { throw "出力先フォルダがありません: $outDir" }
    $zipPath = Join-Path $outDir "$name-${version}_$Timestamp.zip"
    Write-Log "出力先: $zipPath"
    Write-Log ("groups: [{0}] / extras: [{1}] / exclude: [{2}] / trackedOnly: {3} / pruneWinPython: {4} / installer: {5}" -f
        ($cfg.groups -join ', '), ($cfg.extras -join ', '), ($cfg.exclude -join ', '), $cfg.trackedOnly, $cfg.pruneWinPython, $cfg.installer)
    Write-Log "uv: $((Invoke-Native uv @('--version') -Capture) -join ' ')"

    # --- 作業用フォルダ ---
    if (Test-Path -LiteralPath $WorkDir) {
        Write-Log "前回の作業用フォルダを削除: $WorkDir"
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    $stageDir = Join-Path $WorkDir 'stage'
    New-Item -ItemType Directory -Path $stageDir | Out-Null

    # --- 依存の書き出し ---
    # uv モードでも行う。WinPython のダウンロード前に lock の不備に気づくためと、入れる依存をログに残すため。
    Write-Step '依存を書き出す(uv export)'
    $requirements = Join-Path $WorkDir 'requirements.txt'
    $selectArgs = @('--no-default-groups')
    foreach ($g in $cfg.groups) { $selectArgs += @('--group', $g) }
    foreach ($e in $cfg.extras) { $selectArgs += @('--extra', $e) }
    $uvArgs = @('export', '--project', $root, '--frozen', '--no-emit-project') + $selectArgs
    $uvArgs += @('--format', 'requirements-txt', '--output-file', $requirements, '--quiet')
    Invoke-Native uv $uvArgs
    foreach ($line in [System.IO.File]::ReadAllLines($requirements, [System.Text.Encoding]::UTF8)) {
        # ハッシュの行は長いので省く
        if ($line -match '^\s*(#|--hash)' -or -not $line.Trim()) { continue }
        Write-Log "  $($line.TrimEnd(' ', '\'))"
    }

    if ($cfg.installer -eq 'pip') {
        $nonPyPI = Get-NonPyPIRequirements (Join-Path $root 'uv.lock') $requirements $PyPIIndexUrl
        if ($nonPyPI.Count -gt 0) {
            throw ("PyPI 以外の index から取る依存があり、installer が pip では入れられません。installer を uv にしてください:`n" +
                (($nonPyPI | ForEach-Object { "  $_" }) -join "`n"))
        }
    }

    # --- WinPython ---
    Write-Step "WinPython を用意する(Python $minor)"
    $archive = Get-WinPythonArchive $winPython $BuildDir
    $wpDir = Join-Path $stageDir 'winpython'
    Expand-WinPython $archive $wpDir $WorkDir
    $python = Join-Path $wpDir 'python\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "WinPython に python\python.exe がありません: $python" }

    # --- 対象プロジェクトのファイル ---
    Write-Step '対象プロジェクトのファイルを集める'
    $files = Get-ProjectFiles $root $cfg.trackedOnly $cfg.exclude
    foreach ($rel in $files) {
        $src = Join-Path $root ($rel -replace '/', '\')
        $dst = Join-Path $stageDir ($rel -replace '/', '\')
        $dstParent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst
        Write-Log "  $rel"
    }
    Write-Log "$($files.Count) ファイル"

    # --- 依存のインストール ---
    if ($cfg.installer -eq 'uv') {
        # WinPython の python フォルダを、プロジェクトの環境として uv sync する。
        # --inexact: lock にないもの(WinPython 同梱の pip, wppm 等)を消さない。
        # --link-mode copy: uv のキャッシュへのハードリンクにしない。--no-editable: path 依存を開発機のパスで参照させない。
        Write-Step '依存をインストールする(uv sync)'
        $syncArgs = @('sync', '--project', $root, '--frozen', '--inexact', '--no-install-project') + $selectArgs
        $syncArgs += @('--python', $python, '--link-mode', 'copy', '--no-editable')
        $savedProjectEnv = [Environment]::GetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', 'Process')
        [Environment]::SetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', (Join-Path $wpDir 'python'), 'Process')
        try {
            Invoke-Native uv $syncArgs
        } finally {
            [Environment]::SetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', $savedProjectEnv, 'Process')
        }
    } else {
        Write-Step '依存をインストールする(pip install)'
        Invoke-Native $python @('-X', 'utf8', '-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '-r', $requirements)
    }

    $sitePackages = Join-Path $wpDir 'python\Lib\site-packages'
    $pthPath = Join-Path $sitePackages $PthFileName
    [System.IO.File]::WriteAllText($pthPath, $PthContent + "`r`n", $Utf8NoBom)
    Write-Log "$PthFileName を作成: $PthContent"

    # --- 動作確認 ---
    Write-Step '動作確認'
    Invoke-Native $python @('--version')
    Invoke-Native $python @('-X', 'utf8', '-m', 'pip', 'check', '--disable-pip-version-check')
    # -I: カレントフォルダを sys.path に入れない。.pth 経由で import できることを確かめるため。
    Invoke-Native $python @('-I', '-X', 'utf8', '-c', "import $importName; print('import OK:', $importName.__file__)")

    # --- 不要物の削除 ---
    if ($cfg.pruneWinPython) {
        Write-Step 'WinPython の不要なランチャー等を削除する'
        foreach ($target in $PruneTargets) {
            $path = Join-Path $wpDir $target
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
                Write-Log "  削除: $target"
            } else {
                Write-Log "  (なし): $target"
            }
        }
    }

    # --- ZIP ---
    Write-Step 'ZIP を作る'
    $winPythonZip = Join-Path $WorkDir 'winpython.zip'
    Write-Log "winpython.zip を作成中..."
    New-ZipFromDirectory $winPythonZip $wpDir
    Write-Log ("winpython.zip: {0:N1} MB" -f ((Get-Item -LiteralPath $winPythonZip).Length / 1MB))
    Write-Log "外側 ZIP を作成中..."
    # winpython.zip は中身が zip なので圧縮しない
    $outerEntries = @(@{ Name = 'winpython.zip'; Source = $winPythonZip; Store = $true })
    foreach ($rel in $files) {
        $outerEntries += @{ Name = $rel; Source = (Join-Path $stageDir ($rel -replace '/', '\')); Store = $false }
    }
    New-ZipFile $zipPath $outerEntries

    $sha256 = Get-Sha256 $zipPath
    $size = (Get-Item -LiteralPath $zipPath).Length

    Write-Step '後片付け'
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
    Write-Log "作業用フォルダを削除: $WorkDir"

    $elapsed = (Get-Date) - $StartTime
    Write-Log ''
    Write-Log '完了しました。' -Color Green
    Write-Log "出力: $zipPath" -Color Green
    Write-Log ("サイズ: {0:N0} バイト ({1:N1} MB)" -f $size, ($size / 1MB)) -Color Green
    Write-Log "SHA-256: $sha256" -Color Green
    Write-Log ("所要時間: {0:mm\:ss}" -f $elapsed)
    Write-Log "ログ: $script:LogPath"

    $script:ResultText = "出力:`n$zipPath`n`nSHA-256:`n$sha256"
}

$boundCopy = @{}
foreach ($key in $PSBoundParameters.Keys) { $boundCopy[$key] = $PSBoundParameters[$key] }
$script:NoPopupEffective = [bool]$NoPopup
$script:Cancelled = $false
$script:ResultText = $null

$savedEnv = @{}
foreach ($key in $EnvOverrides.Keys) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $EnvOverrides[$key], 'Process')
}
$savedOutputEncoding = [Console]::OutputEncoding
$exitCode = 0
try {
    # uv, pip, git(core.quotepath=off)の出力は UTF-8
    [Console]::OutputEncoding = $Utf8NoBom
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    Invoke-Build $boundCopy
    if (-not $script:Cancelled -and -not $script:NoPopupEffective) {
        Show-Popup $script:ResultText $false
    }
} catch {
    $exitCode = 1
    $message = $_.Exception.Message
    if (-not $script:LogPath) { Open-LogFile $null $LogDir $Timestamp }
    Write-Log ''
    Write-Log "失敗しました: $message" -Color Red
    Write-Log ($_.ScriptStackTrace) -Color DarkGray
    if (Test-Path -LiteralPath $WorkDir) { Write-Log "作業用フォルダは調査用に残しています: $WorkDir" }
    Write-Log "ログ: $script:LogPath"
    if (-not $script:NoPopupEffective) {
        Show-Popup "$message`n`nログ:`n$script:LogPath" $true
    }
} finally {
    [Console]::OutputEncoding = $savedOutputEncoding
    foreach ($key in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process')
    }
}
exit $exitCode
