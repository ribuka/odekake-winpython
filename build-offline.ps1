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
    [switch]$NoPopup
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # 5.1 の Invoke-WebRequest は進捗表示があると極端に遅い

# ---------------------------------------------------------------------------
# 固定値
# ---------------------------------------------------------------------------

# WinPython dot 版(2026-03 リリース)。URL は規則から組み立てず完全な形で持つ(spec §5)。
$WinPythonTable = @{
    '3.13' = @{
        Url    = 'https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.13.15.0dot.zip'
        Sha256 = '28e36408f0140c50b207ea059a599c664564e68a3cbb835f03a71f4601efd8f1'
    }
    '3.14' = @{
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
$SettingTypes = [ordered]@{
    pythonVersion    = 'string'
    outputDir        = 'string'
    trackedOnly      = 'bool'
    groups           = 'array'
    extras           = 'array'
    exclude          = 'array'
    pruneWinPython   = 'bool'
    importName       = 'string'
    noPopup          = 'bool'
}

$PthFileName = 'odekake-src.pth'
$PthContent  = '..\..\..\..\src'

$RepoRoot = $PSScriptRoot
$BuildDir = Join-Path $RepoRoot '.build'
$WorkDir  = Join-Path $BuildDir 'work'
$LogDir   = Join-Path $RepoRoot 'logs'

$StartTime = Get-Date
$Timestamp = $StartTime.ToString("yyyyMMdd'T'HHmmss")
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# ログ
# ---------------------------------------------------------------------------

# ログファイル名には <name> が要るので、pyproject を読むまではメモリに溜める。
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:LogPath = $null

function Write-Log {
    param([string]$Message = '', [string]$Color)
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $Message
    if ($script:LogPath) {
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $Utf8NoBom)
    } else {
        $script:LogBuffer.Add($line)
    }
}

function Write-Step([string]$Message) {
    Write-Log ''
    Write-Log "== $Message" -Color Cyan
}

function Open-LogFile([string]$Name) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $fileName = if ($Name) { "${Timestamp}_$Name.log" } else { "$Timestamp.log" }
    $script:LogPath = Join-Path $LogDir $fileName
    [System.IO.File]::AppendAllLines($script:LogPath, $script:LogBuffer, $Utf8NoBom)
    $script:LogBuffer.Clear()
}

# ---------------------------------------------------------------------------
# 外部コマンド
# ---------------------------------------------------------------------------

# 外部コマンドを実行し、stdout と stderr をログに書く。終了コードが 0 以外なら例外。
# -Capture を付けると、stdout をログに書かずに返す(stderr はログに書く)。
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    Write-Log ("> {0} {1}" -f $FilePath, ($Arguments -join ' ')) -Color DarkGray
    $stdout = New-Object System.Collections.Generic.List[string]
    # 5.1 では Stop のまま stderr をリダイレクトすると、stderr の1行目で例外になる
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Log ([string]$_.Exception.Message)
            } elseif ($Capture) {
                $stdout.Add([string]$_)
            } else {
                Write-Log ([string]$_)
            }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        throw "外部コマンドが失敗しました(終了コード $code): $FilePath $($Arguments -join ' ')"
    }
    if ($Capture) { return , $stdout.ToArray() }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

# ダイアログがコンソールの裏に隠れないよう、最前面の見えないフォームを親にする。
function New-TopMostOwner {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.StartPosition = 'CenterScreen'
    $owner.Size = New-Object System.Drawing.Size(0, 0)
    $owner.Opacity = 0
    $owner.Show()
    $owner.Activate()
    return $owner
}

function Select-ProjectFolder {
    $owner = New-TopMostOwner
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = '持ち出す uv プロジェクトのフォルダ(pyproject.toml があるフォルダ)を選んでください'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.PSObject.Properties['UseDescriptionForTitle']) { $dialog.UseDescriptionForTitle = $true }
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.SelectedPath
    } finally {
        $owner.Dispose()
    }
}

function Show-Popup([string]$Text, [bool]$IsError) {
    try {
        $owner = New-TopMostOwner
        try {
            $icon = if ($IsError) { 'Error' } else { 'Information' }
            $title = if ($IsError) { 'odekake-winpython: 失敗' } else { 'odekake-winpython: 完了' }
            [System.Windows.Forms.MessageBox]::Show($owner, $Text, $title, 'OK', $icon) | Out-Null
        } finally {
            $owner.Dispose()
        }
    } catch {
        Write-Log "ポップアップを表示できませんでした: $($_.Exception.Message)" -Color Yellow
    }
}

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# 設定ファイルを読み、型を確認して hashtable で返す。ファイルがなければ空。
function Read-SettingsFile([string]$Path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    Write-Log "設定ファイル: $Path"
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $text.Trim()) { return $result }
    try {
        $json = $text | ConvertFrom-Json
    } catch {
        throw "設定ファイルを JSON として読めません: $Path`n$($_.Exception.Message)"
    }
    if ($json -isnot [System.Management.Automation.PSCustomObject]) {
        throw "設定ファイルの最上位は { } のオブジェクトにしてください: $Path"
    }
    foreach ($prop in $json.PSObject.Properties) {
        $key = $prop.Name
        if (-not (@($SettingTypes.Keys) -ccontains $key)) {
            throw "設定ファイルに未知のキー '$key' があります: $Path`n使えるキー: $($SettingTypes.Keys -join ', ')"
        }
        $value = $prop.Value
        switch ($SettingTypes[$key]) {
            'string' {
                if ($value -isnot [string]) { throw "設定 '$key' は文字列にしてください: $Path" }
            }
            'bool' {
                if ($value -isnot [bool]) { throw "設定 '$key' は true / false にしてください: $Path" }
            }
            'array' {
                if ($value -is [string]) { throw "設定 '$key' は文字列の配列([`"...`"])にしてください: $Path" }
                $value = @($value)
                foreach ($item in $value) {
                    if ($item -isnot [string]) { throw "設定 '$key' の要素は文字列にしてください: $Path" }
                }
                $value = [string[]]$value
            }
        }
        $result[$key] = $value
    }
    return $result
}

# 既定値 < settings.json < settings.local.json < 引数 の順に、キー単位で上書きする。
function Get-EffectiveSettings([hashtable]$BoundParameters) {
    $settings = @{}
    foreach ($key in $SettingTypes.Keys) {
        switch ($SettingTypes[$key]) {
            'string' { $settings[$key] = $null }
            'bool'   { $settings[$key] = $false }
            'array'  { $settings[$key] = [string[]]@() }
        }
    }

    $configFile = if ($BoundParameters.ContainsKey('ConfigPath')) {
        Resolve-FullPath $BoundParameters['ConfigPath']
    } else {
        Join-Path $RepoRoot 'config\settings.json'
    }
    if ($BoundParameters.ContainsKey('ConfigPath') -and -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "-ConfigPath で指定された設定ファイルがありません: $configFile"
    }
    $localFile = Join-Path (Split-Path -Parent $configFile) 'settings.local.json'

    foreach ($file in @($configFile, $localFile)) {
        $fromFile = Read-SettingsFile $file
        foreach ($key in $fromFile.Keys) { $settings[$key] = $fromFile[$key] }
    }

    foreach ($key in $SettingTypes.Keys) {
        $paramName = $key.Substring(0, 1).ToUpper() + $key.Substring(1)
        if (-not $BoundParameters.ContainsKey($paramName)) { continue }
        # pythonVersion は .python-version との間に優先順位があるので、ここでは引数で上書きしない(Get-PythonMinor)
        if ($key -eq 'pythonVersion') { continue }
        $value = $BoundParameters[$paramName]
        switch ($SettingTypes[$key]) {
            'bool' { $value = [bool]$value }
            'array' {
                # .bat 経由(-File)だと -Groups a,b が1つの文字列で届くので、カンマで分ける
                $value = [string[]]@($value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        $settings[$key] = $value
    }
    return $settings
}

# ---------------------------------------------------------------------------
# 対象プロジェクトの情報
# ---------------------------------------------------------------------------

# pyproject.toml の [project] から name / version / dynamic を読む。
# TOML パーサーがないため、正規表現で必要な値だけ取り出す(1行の文字列値のみ対応)。
function Read-PyProject([string]$Path) {
    $body = New-Object System.Text.StringBuilder
    $inProject = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*\[\[') { $inProject = $false; continue }
        if ($line -match '^\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$') { $inProject = ($Matches[1] -eq 'project'); continue }
        if ($inProject) { [void]$body.AppendLine($line) }
    }
    $text = $body.ToString()

    $getString = {
        param([string]$Key)
        $m = [regex]::Match($text, "(?m)^\s*$Key\s*=\s*(?:`"([^`"]*)`"|'([^']*)')")
        if (-not $m.Success) { return $null }
        if ($m.Groups[1].Success) { return $m.Groups[1].Value } else { return $m.Groups[2].Value }
    }

    $dynamic = @()
    $m = [regex]::Match($text, '(?ms)^\s*dynamic\s*=\s*\[(.*?)\]')
    if ($m.Success) {
        $dynamic = @([regex]::Matches($m.Groups[1].Value, "[`"']([^`"']*)[`"']") | ForEach-Object { $_.Groups[1].Value })
    }

    return @{
        Name    = & $getString 'name'
        Version = & $getString 'version'
        Dynamic = $dynamic
    }
}

function Get-ProjectVersion([string]$Root, [hashtable]$PyProject) {
    if ($PyProject.Version) { return $PyProject.Version }
    if ($PyProject.Dynamic -contains 'version') {
        $versionFile = Join-Path $Root 'VERSION'
        if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
            throw "pyproject.toml の version が dynamic ですが、VERSION ファイルがありません: $versionFile"
        }
        $version = ([System.IO.File]::ReadAllText($versionFile)).Trim()
        if (-not $version -or $version.Contains("`n")) {
            throw "VERSION ファイルには、バージョンを1行だけ書いてください: $versionFile"
        }
        return $version
    }
    throw 'pyproject.toml の [project] に version がありません(dynamic にも version がありません)。'
}

# Python のマイナーバージョン(3.13 など)を決める。
# 優先順位: 引数 -PythonVersion > .python-version > 設定ファイルの pythonVersion
function Get-PythonMinor([string]$Root, [string]$FromArgument, [string]$FromSettings) {
    $fromFile = $null
    $pvFile = Join-Path $Root '.python-version'
    if (Test-Path -LiteralPath $pvFile -PathType Leaf) {
        $fromFile = [System.IO.File]::ReadAllLines($pvFile) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Select-Object -First 1
    }

    if ($FromArgument) {
        $source = '引数 -PythonVersion'
        $raw = $FromArgument
    } elseif ($fromFile) {
        $source = '.python-version'
        $raw = $fromFile
    } elseif ($FromSettings) {
        $source = '設定ファイルの pythonVersion'
        $raw = $FromSettings
    } else {
        throw ".python-version がありません。pythonVersion(-PythonVersion)で 3.13 のように指定してください。"
    }

    $m = [regex]::Match($raw, '(\d+)\.(\d+)')
    if (-not $m.Success) { throw "Python のバージョンを読み取れません($source): '$raw'" }
    $minor = "$($m.Groups[1].Value).$($m.Groups[2].Value)"

    if ($FromArgument -and $fromFile) {
        $fm = [regex]::Match($fromFile, '(\d+)\.(\d+)')
        if ($fm.Success -and "$($fm.Groups[1].Value).$($fm.Groups[2].Value)" -ne $minor) {
            Write-Log "注意: .python-version ($fromFile) と異なる Python $minor を、引数 -PythonVersion の指定に従って使います。" -Color Yellow
        }
    }
    Write-Log "Python バージョン: $minor ($source`: $raw)"
    return $minor
}

# ZIP に入れるファイルを git で列挙する(対象プロジェクトからの相対パス、区切りは /)。
function Get-ProjectFiles([string]$Root, [bool]$TrackedOnlyFlag, [string[]]$ExcludePatterns) {
    $gitArgs = @('-C', $Root, '-c', 'core.quotepath=off', 'ls-files', '-z', '--cached')
    if (-not $TrackedOnlyFlag) { $gitArgs += @('--others', '--exclude-standard') }
    $gitArgs += @('--', '.')
    foreach ($pattern in $ExcludePatterns) { $gitArgs += ":(exclude,glob)$pattern" }

    $out = Invoke-Native git $gitArgs -Capture
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($rel in (($out -join "`n") -split "`0")) {
        if (-not $rel) { continue }
        $full = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            # 削除済みでまだコミットしていないファイルや、サブモジュール
            Write-Log "スキップ(ファイルとして存在しない): $rel" -Color Yellow
            continue
        }
        if ($rel -eq 'winpython.zip' -or $rel -like 'winpython/*') {
            throw "対象プロジェクトに '$rel' があり、成果物の winpython.zip / winpython\ と衝突します。exclude で除外してください。"
        }
        $files.Add($rel)
    }
    if ($files.Count -eq 0) { throw 'ZIP に入れるファイルが1つもありません。' }
    return , $files.ToArray()
}

# ---------------------------------------------------------------------------
# WinPython
# ---------------------------------------------------------------------------

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# .build\downloads にキャッシュした WinPython の zip を返す。ハッシュが合わなければ取り直す。
function Get-WinPythonArchive([hashtable]$Entry) {
    $downloadDir = Join-Path $BuildDir 'downloads'
    if (-not (Test-Path -LiteralPath $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir | Out-Null }
    $fileName = [System.IO.Path]::GetFileName(([Uri]$Entry.Url).AbsolutePath)
    $path = Join-Path $downloadDir $fileName

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ((Get-Sha256 $path) -eq $Entry.Sha256) {
            Write-Log "キャッシュを使います: $path"
            return $path
        }
        Write-Log "キャッシュの SHA-256 が一致しないため、ダウンロードし直します: $path" -Color Yellow
        Remove-Item -LiteralPath $path -Force
    }

    Write-Log "ダウンロード: $($Entry.Url)"
    Write-Log "保存先: $path"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $partial = "$path.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    Invoke-WebRequest -Uri $Entry.Url -OutFile $partial -UseBasicParsing
    $actual = Get-Sha256 $partial
    if ($actual -ne $Entry.Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw "ダウンロードした WinPython の SHA-256 が一致しません。`n期待値: $($Entry.Sha256)`n実際: $actual"
    }
    Move-Item -LiteralPath $partial -Destination $path
    return $path
}

# WinPython を展開し、最上位フォルダ(WPy64-xxxx)を取り除いて $Destination に置く。
function Expand-WinPython([string]$Archive, [string]$Destination) {
    $extractDir = Join-Path $WorkDir 'extract'
    Write-Log "展開: $Archive"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $extractDir)
    $top = @(Get-ChildItem -LiteralPath $extractDir -Force)
    if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) {
        throw "WinPython の zip の最上位がフォルダ1つではありません: $Archive"
    }
    Write-Log "最上位フォルダ $($top[0].Name) を取り除いて、winpython\ に置きます"
    Move-Item -LiteralPath $top[0].FullName -Destination $Destination
    Remove-Item -LiteralPath $extractDir -Force
}

# ---------------------------------------------------------------------------
# 出力先
# ---------------------------------------------------------------------------

function Get-DownloadsFolder {
    if (-not ('OdekakeKnownFolder' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OdekakeKnownFolder {
    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint dwFlags, IntPtr hToken, out IntPtr ppszPath);

    public static string GetDownloads() {
        IntPtr p;
        int hr = SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out p);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try { return Marshal.PtrToStringUni(p); } finally { Marshal.FreeCoTaskMem(p); }
    }
}
'@
    }
    return [OdekakeKnownFolder]::GetDownloads()
}

# ---------------------------------------------------------------------------
# ZIP
# ---------------------------------------------------------------------------

# ZIP を作る。$Entries は @{ Name = 'a/b.txt'; Source = 'C:\....txt'; Store = $false } の配列。
# Source が $null のものは空フォルダ(Name は / で終わる)。
# エントリ名の区切りは必ず / にする。5.1(.NET Framework)の ZipFile.CreateFromDirectory は \ を使うため使わない。
# 途中で失敗しても半端な ZIP が残らないよう、.partial に書いてから名前を変える。
function New-ZipFile([string]$Path, [object[]]$Entries) {
    $partial = "$Path.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $stream = [System.IO.File]::Open($partial, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $Entries) {
                if ($null -eq $entry.Source) {
                    [void]$zip.CreateEntry($entry.Name)
                    continue
                }
                $level = if ($entry.Store) { [System.IO.Compression.CompressionLevel]::NoCompression } else { [System.IO.Compression.CompressionLevel]::Optimal }
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $entry.Source, $entry.Name, $level)
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    Move-Item -LiteralPath $partial -Destination $Path
}

# フォルダの中身を、フォルダ自体は含めずに ZIP にする(空フォルダも含める)。
function New-ZipFromDirectory([string]$Path, [string]$SourceDir) {
    $base = (Get-Item -LiteralPath $SourceDir).FullName.TrimEnd('\') + '\'
    $entries = foreach ($item in Get-ChildItem -LiteralPath $SourceDir -Recurse -Force) {
        $name = $item.FullName.Substring($base.Length) -replace '\\', '/'
        if ($item.PSIsContainer) {
            if (-not (Get-ChildItem -LiteralPath $item.FullName -Force | Select-Object -First 1)) {
                @{ Name = "$name/"; Source = $null }
            }
        } else {
            @{ Name = $name; Source = $item.FullName; Store = $false }
        }
    }
    New-ZipFile $Path @($entries)
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

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

function Invoke-Build {
    param([hashtable]$bound)
    $script:NoPopupEffective = [bool]$NoPopup

    Write-Log "odekake-winpython ビルド開始: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "PowerShell $($PSVersionTable.PSVersion)"

    # --- 設定と対象プロジェクト ---
    $cfg = Get-EffectiveSettings $bound
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
    Open-LogFile $name
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
    Write-Log ("groups: [{0}] / extras: [{1}] / exclude: [{2}] / trackedOnly: {3} / pruneWinPython: {4}" -f
        ($cfg.groups -join ', '), ($cfg.extras -join ', '), ($cfg.exclude -join ', '), $cfg.trackedOnly, $cfg.pruneWinPython)

    # --- 作業用フォルダ ---
    if (Test-Path -LiteralPath $WorkDir) {
        Write-Log "前回の作業用フォルダを削除: $WorkDir"
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    $stageDir = Join-Path $WorkDir 'stage'
    New-Item -ItemType Directory -Path $stageDir | Out-Null

    # --- 依存の書き出し ---
    Write-Step '依存を書き出す(uv export)'
    $requirements = Join-Path $WorkDir 'requirements.txt'
    $uvArgs = @('export', '--project', $root, '--frozen', '--no-emit-project', '--no-default-groups')
    foreach ($g in $cfg.groups) { $uvArgs += @('--group', $g) }
    foreach ($e in $cfg.extras) { $uvArgs += @('--extra', $e) }
    $uvArgs += @('--format', 'requirements-txt', '--output-file', $requirements, '--quiet')
    Invoke-Native uv $uvArgs

    # --- WinPython ---
    Write-Step "WinPython を用意する(Python $minor)"
    $archive = Get-WinPythonArchive $winPython
    $wpDir = Join-Path $stageDir 'winpython'
    Expand-WinPython $archive $wpDir
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
    Write-Step '依存をインストールする(pip install)'
    Invoke-Native $python @('-X', 'utf8', '-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '-r', $requirements)

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
    if (-not $script:LogPath) { Open-LogFile $null }
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
