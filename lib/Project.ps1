# Information about the target project
# Dot-sourced by build-offline.ps1. Not meant to be run on its own.

# Reads name / version / dynamic from [project] in pyproject.toml.
# There is no TOML parser, so only the needed values are extracted with regular expressions (single-line string values only).
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
            throw "version in pyproject.toml is dynamic, but there is no VERSION file: $versionFile"
        }
        $version = ([System.IO.File]::ReadAllText($versionFile)).Trim()
        if (-not $version -or $version.Contains("`n")) {
            throw "The VERSION file must contain the version on a single line: $versionFile"
        }
        return $version
    }
    throw 'pyproject.toml has no version in [project] (and version is not in dynamic either).'
}

# Decides the Python minor version (such as 3.13).
# Priority: argument -PythonVersion > .python-version > pythonVersion in the settings file
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
        $source = 'argument -PythonVersion'
        $raw = $FromArgument
    } elseif ($fromFile) {
        $source = '.python-version'
        $raw = $fromFile
    } elseif ($FromSettings) {
        $source = 'pythonVersion in the settings file'
        $raw = $FromSettings
    } else {
        throw ".python-version not found. Specify the version with pythonVersion (-PythonVersion), such as 3.13."
    }

    $m = [regex]::Match($raw, '(\d+)\.(\d+)')
    if (-not $m.Success) { throw "Cannot read the Python version ($source): '$raw'" }
    $minor = "$($m.Groups[1].Value).$($m.Groups[2].Value)"

    if ($FromArgument -and $fromFile) {
        $fm = [regex]::Match($fromFile, '(\d+)\.(\d+)')
        if ($fm.Success -and "$($fm.Groups[1].Value).$($fm.Groups[2].Value)" -ne $minor) {
            Write-Log "Warning: using Python $minor as specified by argument -PythonVersion, which differs from .python-version ($fromFile)." -Color Yellow
        }
    }
    Write-Log "Python version: $minor ($source`: $raw)"
    return $minor
}

# Lists the files to put into the ZIP with git (paths relative to the target project, separated by /).
# If $IncludeExportIgnoredFlag is false, files marked export-ignore in .gitattributes are left out (issue #12).
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
            # Files deleted but not yet committed, or submodules
            Write-Log "Skipped (not an existing file): $rel" -Color Yellow
            continue
        }
        $candidates.Add($rel)
    }

    $ignored = if ($IncludeExportIgnoredFlag) { $null } else { Get-ExportIgnoredPaths $Root $candidates.ToArray() }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $candidates) {
        if ($ignored -and $ignored.Contains($rel)) {
            Write-Log "Excluded (export-ignore): $rel"
            continue
        }
        if ($rel -eq 'winpython.zip' -or $rel -eq 'winpython.7z' -or $rel -like 'winpython/*') {
            throw "The target project has '$rel', which conflicts with winpython.zip / winpython.7z / winpython\ in the output. Leave it out with exclude."
        }
        $files.Add($rel)
    }
    if ($files.Count -eq 0) { throw 'There are no files to put into the ZIP.' }
    return , $files.ToArray()
}

# Returns, as a HashSet, the $Paths (relative paths separated by /) marked export-ignore, including those whose parent folder is marked.
# git check-attr does not apply a pattern that matches a folder (such as /tests/) to the files inside it.
# So parent folders are also checked with a trailing /, giving the same result as git archive leaving out the whole folder.
# .gitattributes is read from the working tree (git archive uses the target commit by default), because files not yet added also go into the ZIP.
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

    # Invoke-Native does not support standard input, so paths are passed as arguments instead of --stdin.
    # Call in chunks to stay within the Windows command-line length limit (32767 characters).
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $chunk = New-Object System.Collections.Generic.List[string]
    $length = 0
    $flush = {
        $out = Invoke-Native git (@('-C', $Root, 'check-attr', '-z', 'export-ignore', '--') + $chunk.ToArray()) -Capture
        # The output repeats "path NUL attribute NUL value NUL". Only entries whose value is set are left out (same as git archive).
        # The string value export-ignore=set is also printed as set and cannot be told apart, so it is left out too (known limitation; spec §2).
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

# Returns the dependencies in requirements.txt (the output of uv export) that uv.lock takes from an index (registry) other than PyPI.
# pip does not know the index from requirements.txt, so pip mode cannot install them (issue #10).
# Returns an array of "name==version (index URL)". There is no TOML parser, so uv.lock is read line by line.
# When environment markers switch the index, the same name==version appears more than once with different registries.
# requirements.txt does not tell which one was chosen, so it is returned if any of them is not PyPI (to be safe).
function Get-NonPyPIRequirements([string]$LockPath, [string]$RequirementsPath, [string]$PyPIIndexUrl) {
    $normalize = { param([string]$n) ($n -replace '[-_.]+', '-').ToLowerInvariant() }

    # Collect name / version / registry for each [[package]] in uv.lock (a list of registries per key)
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
