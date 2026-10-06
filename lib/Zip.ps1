# Creating ZIP files
# Dot-sourced by build-offline.ps1. Not meant to be run on its own.

# Creates a ZIP. $Entries is an array of @{ Name = 'a/b.txt'; Source = 'C:\...\b.txt'; Store = $false }.
# An entry whose Source is $null is an empty folder (Name ends with /).
# Entry names always use / as the separator. ZipFile.CreateFromDirectory in 5.1 (.NET Framework) uses \, so it is not used.
# Writes to .partial and then renames it, so that a failure does not leave a broken ZIP behind.
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

# Zips the contents of a folder without the folder itself (empty folders included).
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

# 7z files are created with the tar.exe that comes with Windows (bsdtar / libarchive) (spec §16).
# The tar on PATH may be GNU tar from Git for Windows, which cannot write 7z, so the one in System32 is used.
function Get-SystemTarPath {
    return Join-Path $env:SystemRoot 'System32\tar.exe'
}

# Packs the contents of a folder into a 7z (LZMA2) without the folder itself (empty folders included).
# Passing . to tar makes entry names start with ./, so the top-level items are passed by name.
function New-SevenZipFromDirectory([string]$Path, [string]$SourceDir, [string]$Tar) {
    $names = @(Get-ChildItem -LiteralPath $SourceDir -Force | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { throw "The folder to pack into 7z is empty: $SourceDir" }
    $partial = "$Path.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $tarArgs = @('-C', $SourceDir, '--format', '7zip', '--options', '7zip:compression=lzma2', '-cf', $partial) + $names
    Invoke-Native $Tar $tarArgs
    Move-Item -LiteralPath $partial -Destination $Path
}

# Checks that tar.exe can create 7z by creating a small test 7z. Throws if it cannot.
# tar.exe on older Windows may not be able to write 7z (LZMA2) (unverified), so this is checked before downloading WinPython.
function Assert-SevenZipWritable([string]$Tar, [string]$WorkDir) {
    if (-not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
        throw "tar.exe, needed to create 7z, not found: $Tar`nSet winPythonArchiveFormat to zip."
    }
    $probeDir = Join-Path $WorkDir '7z-probe'
    $probe7z = Join-Path $WorkDir '7z-probe.7z'
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $probeDir 'probe.txt'), 'probe')
        try {
            New-SevenZipFromDirectory $probe7z $probeDir $Tar
        } catch {
            throw "tar.exe on this PC cannot create 7z. Set winPythonArchiveFormat to zip.`n$($_.Exception.Message)"
        }
    } finally {
        foreach ($p in @($probeDir, $probe7z, "$probe7z.partial")) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
    }
}
