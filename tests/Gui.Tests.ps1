# Tests for lib\Gui.ps1 (Pester 5). No dialogs are shown; only the start folder resolution (Resolve-InitialDir) is tested.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Log.ps1')
    . (Join-Path $repo 'lib\Gui.ps1')

    Mock Write-Log { }
}

Describe 'Resolve-InitialDir' {
    It 'returns $null when not set: <Name>' -ForEach @(
        @{ Name = 'null'; Value = $null }
        @{ Name = 'empty string'; Value = '' }
    ) {
        Resolve-InitialDir $Value | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 0
    }

    It 'returns an existing folder as it is' {
        $dir = Join-Path $TestDrive 'exists'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Resolve-InitialDir $dir | Should -Be $dir
    }

    It 'normalizes paths that contain . or ..' {
        $dir = Join-Path $TestDrive 'norm'
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') | Out-Null
        Resolve-InitialDir (Join-Path $dir 'sub\..\.') | Should -Be $dir
    }

    It 'expands environment variables' {
        $dir = Join-Path $TestDrive 'env'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $env:ODEKAKE_TEST_INITIAL_DIR = $TestDrive
        try {
            Resolve-InitialDir '%ODEKAKE_TEST_INITIAL_DIR%\env' | Should -Be $dir
        } finally {
            Remove-Item Env:ODEKAKE_TEST_INITIAL_DIR
        }
    }

    It 'warns and returns $null for a missing folder' {
        $dir = Join-Path $TestDrive 'missing'
        Resolve-InitialDir $dir | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like "*initialDir*$dir*" }
    }

    It 'warns and returns $null when the path is a file' {
        $file = Join-Path $TestDrive 'file.txt'
        Set-Content -LiteralPath $file -Value 'x'
        Resolve-InitialDir $file | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1
    }

    It 'fails on a relative path: <Value>' -ForEach @(
        @{ Value = 'repos' }
        @{ Value = '.\repos' }
        @{ Value = '\repos' }
        @{ Value = 'C:repos' }
        @{ Value = '%ODEKAKE_UNDEFINED_VAR%\repos' }
    ) {
        { Resolve-InitialDir $Value } | Should -Throw "*Setting 'initialDir' must be an absolute path*"
    }
}
