# lib\Zip.ps1 のテスト(Pester 5)

BeforeDiscovery {
    # tar.exe で 7z を作れない PC(古い Windows など)では、7z のテストを飛ばす
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('odekake-7z-probe-{0}' -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $probeDir | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $probeDir 'a.txt'), 'a')
        & $tar -C $probeDir --format 7zip --options 7zip:compression=lzma2 -cf (Join-Path $probeDir 'p.7z') a.txt 2>&1 | Out-Null
        $NoSevenZip = $LASTEXITCODE -ne 0
    } catch {
        $NoSevenZip = $true
    } finally {
        Remove-Item -LiteralPath $probeDir -Recurse -Force
    }
}

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Log.ps1')
    . (Join-Path $repo 'lib\Zip.ps1')
    Mock Write-Log { }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    # ZIP のエントリを @{ 名前 = エントリ } で返す
    function Get-ZipEntries([string]$Path) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $result = @{}
            foreach ($e in $zip.Entries) {
                $result[$e.FullName] = [pscustomobject]@{ Length = $e.Length; CompressedLength = $e.CompressedLength }
            }
            return $result
        } finally {
            $zip.Dispose()
        }
    }

    function New-SourceFile([string]$Path, [string]$Text) {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Text)
    }
}

Describe 'New-ZipFromDirectory' {
    BeforeAll {
        $src = Join-Path $TestDrive 'src'
        New-SourceFile (Join-Path $src 'top.txt') 'top'
        New-SourceFile (Join-Path $src 'a\b\c.txt') 'c'
        New-SourceFile (Join-Path $src '日本語\ファイル.txt') 'jp'
        New-Item -ItemType Directory -Path (Join-Path $src 'empty\inner') -Force | Out-Null
        $zipPath = Join-Path $TestDrive 'dir.zip'
        New-ZipFromDirectory $zipPath $src
        $entries = Get-ZipEntries $zipPath
    }

    It 'エントリ名の区切りは / だけ(フォルダ自体は含めない)' {
        @($entries.Keys | Sort-Object) | Should -Be @('a/b/c.txt', 'empty/inner/', 'top.txt', '日本語/ファイル.txt')
        @($entries.Keys | Where-Object { $_.Contains('\') }).Count | Should -Be 0
    }

    It '空フォルダが入る' {
        $entries['empty/inner/'].Length | Should -Be 0
    }

    It '.partial が残らない' {
        Test-Path -LiteralPath "$zipPath.partial" | Should -BeFalse
    }
}

Describe 'New-ZipFile' {
    BeforeAll {
        # よく縮むファイル。Store の有無で圧縮後のサイズが変わるかを見る。
        $source = Join-Path $TestDrive 'repeat.txt'
        New-SourceFile $source ('a' * 100000)
    }

    It 'Store のエントリは圧縮せず、それ以外は圧縮する' {
        $zipPath = Join-Path $TestDrive 'store.zip'
        New-ZipFile $zipPath @(
            @{ Name = 'stored.txt'; Source = $source; Store = $true }
            @{ Name = 'dir/deflated.txt'; Source = $source; Store = $false }
            @{ Name = 'empty/'; Source = $null }
        )
        $entries = Get-ZipEntries $zipPath
        @($entries.Keys | Sort-Object) | Should -Be @('dir/deflated.txt', 'empty/', 'stored.txt')
        # .NET Framework(5.1)の NoCompression は無圧縮ブロックの deflate になり、元より数バイト大きくなる
        $entries['stored.txt'].CompressedLength | Should -BeGreaterOrEqual 100000
        $entries['dir/deflated.txt'].CompressedLength | Should -BeLessThan 10000
    }

    It '前回の .partial が残っていても作れる' {
        $zipPath = Join-Path $TestDrive 'retry.zip'
        New-SourceFile "$zipPath.partial" 'broken'
        New-ZipFile $zipPath @(@{ Name = 'a.txt'; Source = $source; Store = $false })
        @((Get-ZipEntries $zipPath).Keys) | Should -Be @('a.txt')
        Test-Path -LiteralPath "$zipPath.partial" | Should -BeFalse
    }
}

Describe 'New-SevenZipFromDirectory' -Skip:$NoSevenZip {
    BeforeAll {
        $tar = Get-SystemTarPath
        $src = Join-Path $TestDrive 'src7'
        New-SourceFile (Join-Path $src 'top.txt') 'top'
        New-SourceFile (Join-Path $src 'a b\c.txt') ('c' * 100000)
        New-SourceFile (Join-Path $src '日本語\ファイル.txt') 'jp'
        New-Item -ItemType Directory -Path (Join-Path $src 'empty\inner') -Force | Out-Null
        $archive = Join-Path $TestDrive 'dir.7z'
        New-SevenZipFromDirectory $archive $src $tar
    }

    It '7z の形式で書かれ、圧縮される' {
        $bytes = [System.IO.File]::ReadAllBytes($archive)
        $bytes[0..5] | Should -Be @(0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)
        $bytes.Length | Should -BeLessThan 10000
    }

    It 'エントリ名は ./ で始まらず、フォルダ自体は含めない' {
        # tar -tf はコンソールのコードページで出力するので、日本語の名前は比べない(展開して確かめる)
        $names = @(& $tar -tf $archive | ForEach-Object { $_.TrimEnd('/') })
        $names.Count | Should -Be 7
        @($names | Where-Object { $_ -match '^[\x20-\x7e]+$' } | Sort-Object) | Should -Be @('a b', 'a b/c.txt', 'empty', 'empty/inner', 'top.txt')
    }

    It '展開すると元と同じ中身になる(空フォルダも)' {
        $out = Join-Path $TestDrive 'out7'
        New-Item -ItemType Directory -Path $out | Out-Null
        & $tar -C $out -xf $archive
        $LASTEXITCODE | Should -Be 0
        [System.IO.File]::ReadAllText((Join-Path $out 'a b\c.txt')) | Should -Be ('c' * 100000)
        [System.IO.File]::ReadAllText((Join-Path $out '日本語\ファイル.txt')) | Should -Be 'jp'
        Test-Path -LiteralPath (Join-Path $out 'empty\inner') -PathType Container | Should -BeTrue
    }

    It '.partial が残らない' {
        Test-Path -LiteralPath "$archive.partial" | Should -BeFalse
    }

    It '空のフォルダはエラー' {
        $empty = Join-Path $TestDrive 'empty7'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { New-SevenZipFromDirectory (Join-Path $TestDrive 'empty.7z') $empty $tar } | Should -Throw '7z にするフォルダが空です: *'
    }
}

Describe 'Assert-SevenZipWritable' {
    It 'tar.exe がなければエラー' {
        { Assert-SevenZipWritable (Join-Path $TestDrive 'no\tar.exe') $TestDrive } | Should -Throw '7z を作るための tar.exe がありません: *'
    }

    It 'tar.exe が 7z を書けなければエラーにし、試しに作ったものを残さない' {
        # 7z を書けない tar の代わりに、必ず失敗するコマンドを使う
        $fakeTar = Join-Path $env:SystemRoot 'System32\where.exe'
        $work = Join-Path $TestDrive 'work-fail'
        New-Item -ItemType Directory -Path $work | Out-Null
        { Assert-SevenZipWritable $fakeTar $work } | Should -Throw 'この PC の tar.exe では 7z を作れません。*'
        @(Get-ChildItem -LiteralPath $work -Force).Count | Should -Be 0
    }

    It '7z を作れれば何も残さない' -Skip:$NoSevenZip {
        $work = Join-Path $TestDrive 'work-ok'
        New-Item -ItemType Directory -Path $work | Out-Null
        Assert-SevenZipWritable (Get-SystemTarPath) $work
        @(Get-ChildItem -LiteralPath $work -Force).Count | Should -Be 0
    }
}
