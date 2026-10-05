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
