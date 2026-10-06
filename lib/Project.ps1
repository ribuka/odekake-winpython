# 対象プロジェクトの情報
# build-offline.ps1 から dot-source される。単体では実行しない。

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
# $IncludeExportIgnoredFlag が false なら、.gitattributes で export-ignore が付いたファイルを除く(issue #12)。
function Get-ProjectFiles([string]$Root, [bool]$TrackedOnlyFlag, [string[]]$ExcludePatterns, [bool]$IncludeExportIgnoredFlag) {
    $gitArgs = @('-C', $Root, '-c', 'core.quotepath=off', 'ls-files', '-z', '--cached')
    if (-not $TrackedOnlyFlag) { $gitArgs += @('--others', '--exclude-standard') }
    $gitArgs += @('--', '.')
    foreach ($pattern in $ExcludePatterns) { $gitArgs += ":(exclude,glob)$pattern" }

    $out = Invoke-Native git $gitArgs -Capture
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($rel in (($out -join "`n") -split "`0")) {
        if (-not $rel) { continue }
        $full = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            # 削除済みでまだコミットしていないファイルや、サブモジュール
            Write-Log "スキップ(ファイルとして存在しない): $rel" -Color Yellow
            continue
        }
        $candidates.Add($rel)
    }

    $ignored = if ($IncludeExportIgnoredFlag) { $null } else { Get-ExportIgnoredPaths $Root $candidates.ToArray() }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $candidates) {
        if ($ignored -and $ignored.Contains($rel)) {
            Write-Log "除外(export-ignore): $rel"
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

# $Paths(/ 区切りの相対パス)のうち、export-ignore が付いたものを HashSet で返す。親フォルダに付いたものも含む。
# git check-attr は、フォルダに当たるパターン(/tests/ など)を中のファイルには効かせない。
# そこで親フォルダも末尾に / を付けて判定し、git archive がフォルダごと除くのと同じ結果にする。
# .gitattributes は作業ツリーのものを読む(git archive の既定は対象コミットのもの)。未 add のファイルも ZIP に入れるため。
function Get-ExportIgnoredPaths([string]$Root, [string[]]$Paths) {
    $ancestors = @{}
    $queries = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($rel in $Paths) {
        $parts = $rel -split '/'
        $dirs = @(for ($i = 1; $i -lt $parts.Count; $i++) { ($parts[0..($i - 1)] -join '/') + '/' })
        $ancestors[$rel] = $dirs
        foreach ($q in $dirs + $rel) { if ($seen.Add($q)) { $queries.Add($q) } }
    }

    # Invoke-Native は標準入力に対応しないので、--stdin ではなく引数で渡す。
    # Windows のコマンドラインの長さの上限(32767 文字)に収まるよう、分けて呼ぶ。
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $chunk = New-Object System.Collections.Generic.List[string]
    $length = 0
    $flush = {
        $out = Invoke-Native git (@('-C', $Root, 'check-attr', '-z', 'export-ignore', '--') + $chunk.ToArray()) -Capture
        # 出力は「パス NUL 属性名 NUL 値 NUL」の繰り返し。値が set のものだけ除く(git archive と同じ)。
        # 文字列値の export-ignore=set も set と出力されるので区別できず、除いてしまう(既知の制限。spec §2)。
        $fields = ($out -join "`n") -split "`0"
        for ($j = 0; $j + 2 -lt $fields.Count; $j += 3) {
            if ($fields[$j + 2] -eq 'set') { [void]$set.Add($fields[$j]) }
        }
        $chunk.Clear()
    }
    foreach ($q in $queries) {
        if ($chunk.Count -gt 0 -and $length + $q.Length -gt 8000) { . $flush; $length = 0 }
        $chunk.Add($q)
        $length += $q.Length + 3
    }
    if ($chunk.Count -gt 0) { . $flush }

    $result = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($rel in $Paths) {
        foreach ($q in $ancestors[$rel] + $rel) {
            if ($set.Contains($q)) { [void]$result.Add($rel); break }
        }
    }
    return , $result
}

# requirements.txt(uv export の出力)に含まれる依存のうち、uv.lock で PyPI 以外の index(registry)から取るものを返す。
# pip は requirements.txt の index を知らないので、pip モードでは入れられない(issue #10)。
# 返り値は "name==version (index の URL)" の配列。uv.lock は TOML パーサーがないため、行単位で読む。
# 環境マーカーで index を切り替えると、同じ name==version が registry 違いで複数ある。
# requirements.txt からはどれが選ばれたか分からないので、1つでも PyPI 以外があれば返す(安全側に倒す)。
function Get-NonPyPIRequirements([string]$LockPath, [string]$RequirementsPath, [string]$PyPIIndexUrl) {
    $normalize = { param([string]$n) ($n -replace '[-_.]+', '-').ToLowerInvariant() }

    # uv.lock の [[package]] ごとに、name / version / registry を集める(キーごとに registry の一覧)
    $registries = @{}
    $current = $null
    $flush = {
        if ($current -and $current.Name -and $current.Registry) {
            $key = "$(& $normalize $current.Name)==$($current.Version)"
            if (-not $registries.ContainsKey($key)) { $registries[$key] = New-Object System.Collections.Generic.List[string] }
            $registries[$key].Add($current.Registry)
        }
    }
    foreach ($line in [System.IO.File]::ReadAllLines($LockPath, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*\[') {
            . $flush
            $current = if ($line -match '^\s*\[\[\s*package\s*\]\]\s*$') { @{ Name = $null; Version = $null; Registry = $null } } else { $null }
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^name\s*=\s*"([^"]*)"') { $current.Name = $Matches[1] }
        elseif ($line -match '^version\s*=\s*"([^"]*)"') { $current.Version = $Matches[1] }
        elseif ($line -match '^source\s*=\s*\{.*\bregistry\s*=\s*"([^"]*)"') { $current.Registry = $Matches[1] }
    }
    . $flush

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($RequirementsPath, [System.Text.Encoding]::UTF8)) {
        if ($line -notmatch '^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)') { continue }
        $key = "$(& $normalize $Matches[1])==$($Matches[2])"
        if (-not $registries.ContainsKey($key) -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        foreach ($registry in $registries[$key]) {
            if ($registry.TrimEnd('/') -ne $PyPIIndexUrl.TrimEnd('/')) { $result.Add("$key ($registry)") }
        }
    }
    return , $result.ToArray()
}
