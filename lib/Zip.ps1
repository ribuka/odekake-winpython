# ZIP の作成
# build-offline.ps1 から dot-source される。単体では実行しない。

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

# 7z の作成には Windows 標準の tar.exe(bsdtar / libarchive)を使う(spec §16)。
# PATH の tar は Git for Windows の GNU tar のことがあり、7z を書けないので System32 のものに固定する。
function Get-SystemTarPath {
    return Join-Path $env:SystemRoot 'System32\tar.exe'
}

# フォルダの中身を、フォルダ自体は含めずに 7z(LZMA2)にする(空フォルダも含める)。
# tar に . を渡すとエントリ名が ./ で始まるので、最上位の項目を名前で並べて渡す。
function New-SevenZipFromDirectory([string]$Path, [string]$SourceDir, [string]$Tar) {
    $names = @(Get-ChildItem -LiteralPath $SourceDir -Force | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { throw "7z にするフォルダが空です: $SourceDir" }
    $partial = "$Path.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $tarArgs = @('-C', $SourceDir, '--format', '7zip', '--options', '7zip:compression=lzma2', '-cf', $partial) + $names
    Invoke-Native $Tar $tarArgs
    Move-Item -LiteralPath $partial -Destination $Path
}

# tar.exe で 7z を作れるかを、小さな 7z を試しに作って確かめる。作れなければ例外。
# 古い Windows の tar.exe は 7z(LZMA2)を書けないことがある(推測)ので、WinPython のダウンロード前に確かめる。
function Assert-SevenZipWritable([string]$Tar, [string]$WorkDir) {
    if (-not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
        throw "7z を作るための tar.exe がありません: $Tar`nwinPythonArchiveFormat を zip にしてください。"
    }
    $probeDir = Join-Path $WorkDir '7z-probe'
    $probe7z = Join-Path $WorkDir '7z-probe.7z'
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $probeDir 'probe.txt'), 'probe')
        try {
            New-SevenZipFromDirectory $probe7z $probeDir $Tar
        } catch {
            throw "この PC の tar.exe では 7z を作れません。winPythonArchiveFormat を zip にしてください。`n$($_.Exception.Message)"
        }
    } finally {
        foreach ($p in @($probeDir, $probe7z, "$probe7z.partial")) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
    }
}
