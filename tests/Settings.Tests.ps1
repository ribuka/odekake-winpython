# Tests for lib\Settings.ps1 (Pester 5). Writes settings.json / settings.local.json into a temporary folder and calls the functions.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Log.ps1')
    . (Join-Path $repo 'lib\Settings.ps1')

    # Setting keys and types come from the constant in build-offline.ps1. The script is not run; only the right-hand side of the assignment is evaluated.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'build-offline.ps1'), [ref]$null, [ref]$null)
    $assign = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$SettingTypes'
    }, $false)
    $SettingTypes = & ([scriptblock]::Create($assign.Right.Extent.Text))

    Mock Write-Log { }

    # Writes settings files into $Dir\config. A file whose value is $null is not created. Returns $Dir.
    function New-ConfigDir([string]$Dir, [string]$Settings, [string]$Local) {
        $configDir = Join-Path $Dir 'config'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        if ($null -ne $Settings) { [System.IO.File]::WriteAllText((Join-Path $configDir 'settings.json'), $Settings, $utf8) }
        if ($null -ne $Local) { [System.IO.File]::WriteAllText((Join-Path $configDir 'settings.local.json'), $Local, $utf8) }
        return $Dir
    }
}

Describe 'Get-EffectiveSettings' {
    It 'returns the defaults without settings files' {
        $root = Join-Path $TestDrive 'none'
        New-Item -ItemType Directory -Path $root | Out-Null
        $cfg = Get-EffectiveSettings @{} $SettingTypes $root
        @($cfg.Keys | Sort-Object) | Should -Be @($SettingTypes.Keys | Sort-Object)
        $cfg.pythonVersion | Should -BeNullOrEmpty
        $cfg.outputDir | Should -BeNullOrEmpty
        $cfg.trackedOnly | Should -BeFalse
        $cfg.pruneWinPython | Should -BeFalse
        , $cfg.groups | Should -BeOfType [string[]]
        $cfg.groups.Count | Should -Be 0
        $cfg.installer | Should -BeExactly 'uv'
        $cfg.winPythonArchiveFormat | Should -BeExactly 'zip'
    }

    It 'reads RepoRoot\config\settings.json without -ConfigPath' {
        $root = New-ConfigDir (Join-Path $TestDrive 'default') '{ "outputDir": "D:\\out" }' $null
        $cfg = Get-EffectiveSettings @{} $SettingTypes $root
        $cfg.outputDir | Should -Be 'D:\out'
    }

    It 'merges key by key with priority argument > settings.local.json > settings.json > defaults' {
        $root = New-ConfigDir (Join-Path $TestDrive 'priority') `
            '{ "outputDir": "from-settings", "importName": "from_settings", "groups": ["s"], "extras": ["s"], "trackedOnly": true }' `
            '{ "outputDir": "from-local", "groups": ["l"], "extras": ["l"] }'
        $bound = @{ ConfigPath = (Join-Path $root 'config\settings.json'); Groups = @('arg') }
        $cfg = Get-EffectiveSettings $bound $SettingTypes 'C:\nowhere'
        $cfg.groups | Should -Be @('arg')
        $cfg.extras | Should -Be @('l')
        $cfg.outputDir | Should -Be 'from-local'
        $cfg.importName | Should -Be 'from_settings'
        $cfg.trackedOnly | Should -BeTrue
        $cfg.noPopup | Should -BeFalse
    }

    It 'turns switch arguments into bool' {
        $root = New-ConfigDir (Join-Path $TestDrive 'switch') '{ "trackedOnly": false }' $null
        $cfg = Get-EffectiveSettings @{ TrackedOnly = [switch]$true } $SettingTypes $root
        $cfg.trackedOnly | Should -BeOfType [bool]
        $cfg.trackedOnly | Should -BeTrue
    }

    It "splits the array argument -Groups 'a,b' into a and b" {
        $root = Join-Path $TestDrive 'none'
        $cfg = Get-EffectiveSettings @{ Groups = @('a,b'); Extras = @(' x , y', 'z', ',') } $SettingTypes $root
        $cfg.groups | Should -Be @('a', 'b')
        $cfg.extras | Should -Be @('x', 'y', 'z')
    }

    It 'does not override with the pythonVersion argument (handled by Get-PythonMinor)' {
        $root = New-ConfigDir (Join-Path $TestDrive 'pyver') '{ "pythonVersion": "3.12" }' $null
        $cfg = Get-EffectiveSettings @{ PythonVersion = '3.14' } $SettingTypes $root
        $cfg.pythonVersion | Should -Be '3.12'
    }

    It 'switches installer with the settings file and the argument' {
        $root = New-ConfigDir (Join-Path $TestDrive 'installer') '{ "installer": "pip" }' $null
        (Get-EffectiveSettings @{} $SettingTypes $root).installer | Should -BeExactly 'pip'
        (Get-EffectiveSettings @{ Installer = 'uv' } $SettingTypes $root).installer | Should -BeExactly 'uv'
    }

    It 'fails on an invalid installer argument: <Value>' -ForEach @(
        @{ Value = 'conda' }
        @{ Value = 'UV' }
        @{ Value = '' }
    ) {
        $root = Join-Path $TestDrive 'none'
        { Get-EffectiveSettings @{ Installer = $Value } $SettingTypes $root } |
            Should -Throw "*Setting 'installer' must be one of `"uv`" / `"pip`" (argument -Installer)*"
    }

    It 'switches winPythonArchiveFormat with the settings file and the argument' {
        $root = New-ConfigDir (Join-Path $TestDrive 'archiveformat') '{ "winPythonArchiveFormat": "7z" }' $null
        (Get-EffectiveSettings @{} $SettingTypes $root).winPythonArchiveFormat | Should -BeExactly '7z'
        (Get-EffectiveSettings @{ WinPythonArchiveFormat = 'zip' } $SettingTypes $root).winPythonArchiveFormat | Should -BeExactly 'zip'
    }

    It 'fails on an invalid winPythonArchiveFormat argument: <Value>' -ForEach @(
        @{ Value = 'tar' }
        @{ Value = '7Z' }
        @{ Value = '' }
    ) {
        $root = Join-Path $TestDrive 'none'
        { Get-EffectiveSettings @{ WinPythonArchiveFormat = $Value } $SettingTypes $root } |
            Should -Throw "*Setting 'winPythonArchiveFormat' must be one of `"zip`" / `"7z`" (argument -WinPythonArchiveFormat)*"
    }

    It 'initialDir is empty by default and can be set in settings.local.json' {
        $root = Join-Path $TestDrive 'none'
        (Get-EffectiveSettings @{} $SettingTypes $root).initialDir | Should -BeNullOrEmpty
        $root = New-ConfigDir (Join-Path $TestDrive 'initialdir') $null '{ "initialDir": "%USERPROFILE%\\repos" }'
        (Get-EffectiveSettings @{} $SettingTypes $root).initialDir | Should -BeExactly '%USERPROFILE%\repos'
    }

    It 'fails when the -ConfigPath file does not exist' {
        $missing = Join-Path $TestDrive 'missing\settings.json'
        { Get-EffectiveSettings @{ ConfigPath = $missing } $SettingTypes $TestDrive } |
            Should -Throw "Settings file specified by -ConfigPath not found: $missing"
    }
}

Describe 'Read-SettingsFile' {
    BeforeAll {
        function Read-Json([string]$Json) {
            $path = Join-Path $TestDrive ('{0}.json' -f [guid]::NewGuid())
            [System.IO.File]::WriteAllText($path, $Json, (New-Object System.Text.UTF8Encoding($false)))
            return Read-SettingsFile $path $SettingTypes
        }
    }

    It 'returns nothing when the file does not exist' {
        $result = Read-SettingsFile (Join-Path $TestDrive 'nothing.json') $SettingTypes
        $result.Count | Should -Be 0
    }

    It 'returns nothing for an empty file' {
        (Read-Json "  `r`n").Count | Should -Be 0
    }

    It 'turns arrays into string[]' {
        $result = Read-Json '{ "exclude": ["docs/**", "tests"] }'
        , $result.exclude | Should -BeOfType [string[]]
        $result.exclude | Should -Be @('docs/**', 'tests')
    }

    It 'fails on an unknown key' {
        { Read-Json '{ "foo": 1 }' } | Should -Throw "*Unknown key 'foo'*"
    }

    It 'fails on a key that differs only in case (outputdir)' {
        { Read-Json '{ "outputdir": "x" }' } | Should -Throw "*Unknown key 'outputdir'*"
    }

    It 'fails on a wrong type: <Json>' -ForEach @(
        @{ Json = '{ "trackedOnly": "yes" }'; Message = "*Setting 'trackedOnly' must be true / false*" }
        @{ Json = '{ "groups": "dev" }'; Message = "*Setting 'groups' must be an array of strings*" }
        @{ Json = '{ "groups": [1] }'; Message = "*The items of setting 'groups' must be strings*" }
        @{ Json = '{ "pythonVersion": 3.13 }'; Message = "*Setting 'pythonVersion' must be a string*" }
        @{ Json = '{ "installer": "conda" }'; Message = "*Setting 'installer' must be one of `"uv`" / `"pip`"*" }
        @{ Json = '{ "installer": "Pip" }'; Message = "*Setting 'installer' must be one of `"uv`" / `"pip`"*" }
        @{ Json = '{ "installer": ["uv"] }'; Message = "*Setting 'installer' must be one of `"uv`" / `"pip`"*" }
        @{ Json = '{ "installer": null }'; Message = "*Setting 'installer' must be one of `"uv`" / `"pip`"*" }
        @{ Json = '{ "winPythonArchiveFormat": "ZIP" }'; Message = "*Setting 'winPythonArchiveFormat' must be one of `"zip`" / `"7z`"*" }
        @{ Json = '{ "winPythonArchiveFormat": 7 }'; Message = "*Setting 'winPythonArchiveFormat' must be one of `"zip`" / `"7z`"*" }
    ) {
        { Read-Json $Json } | Should -Throw $Message
    }

    It 'fails when the file cannot be read as JSON' {
        { Read-Json '{ "groups": ' } | Should -Throw '*Cannot read the settings file as JSON*'
    }

    It 'fails when the top level is not an object' {
        { Read-Json '["a"]' } | Should -Throw '*The top level of the settings file must be a { } object*'
    }
}
