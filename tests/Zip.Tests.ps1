# lib\Zip.ps1 のテスト(Pester 5)

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Zip.ps1')
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
