# lib\Gui.ps1 のテスト(Pester 5)。ダイアログは出さず、初期位置の解決(Resolve-InitialDir)だけを見る。

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Log.ps1')
    . (Join-Path $repo 'lib\Gui.ps1')

    Mock Write-Log { }
}

Describe 'Resolve-InitialDir' {
    It '未指定なら $null: <Name>' -ForEach @(
        @{ Name = 'null'; Value = $null }
        @{ Name = '空文字'; Value = '' }
    ) {
        Resolve-InitialDir $Value | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 0
    }

    It '存在するフォルダはそのまま返る' {
        $dir = Join-Path $TestDrive 'exists'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Resolve-InitialDir $dir | Should -Be $dir
    }

    It '. や .. を含むパスは正規化する' {
        $dir = Join-Path $TestDrive 'norm'
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') | Out-Null
        Resolve-InitialDir (Join-Path $dir 'sub\..\.') | Should -Be $dir
    }

    It '環境変数を展開する' {
        $dir = Join-Path $TestDrive 'env'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $env:ODEKAKE_TEST_INITIAL_DIR = $TestDrive
        try {
            Resolve-InitialDir '%ODEKAKE_TEST_INITIAL_DIR%\env' | Should -Be $dir
        } finally {
            Remove-Item Env:ODEKAKE_TEST_INITIAL_DIR
        }
    }

    It '存在しないフォルダは警告して $null' {
        $dir = Join-Path $TestDrive 'missing'
        Resolve-InitialDir $dir | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like "*initialDir*$dir*" }
    }

    It 'ファイルを指していたら警告して $null' {
        $file = Join-Path $TestDrive 'file.txt'
        Set-Content -LiteralPath $file -Value 'x'
        Resolve-InitialDir $file | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1
    }

    It '相対パスはエラー: <Value>' -ForEach @(
        @{ Value = 'repos' }
        @{ Value = '.\repos' }
        @{ Value = '\repos' }
        @{ Value = 'C:repos' }
        @{ Value = '%ODEKAKE_UNDEFINED_VAR%\repos' }
    ) {
        { Resolve-InitialDir $Value } | Should -Throw "*設定 'initialDir' は絶対パス*"
    }
}
