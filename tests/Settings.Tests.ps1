# lib\Settings.ps1 のテスト(Pester 5)。一時フォルダに settings.json / settings.local.json を書いて呼ぶ。

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Log.ps1')
    . (Join-Path $repo 'lib\Settings.ps1')

    # 設定キーと型は build-offline.ps1 の固定値を使う。スクリプトは実行せず、代入文の右辺だけ評価する。
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'build-offline.ps1'), [ref]$null, [ref]$null)
    $assign = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$SettingTypes'
    }, $false)
    $SettingTypes = & ([scriptblock]::Create($assign.Right.Extent.Text))

    Mock Write-Log { }

    # $Dir\config に設定ファイルを書く。値が $null のファイルは作らない。返り値は $Dir。
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
    It '設定ファイルがなくても既定値が返る' {
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

    It '-ConfigPath がなければ RepoRoot\config\settings.json を読む' {
        $root = New-ConfigDir (Join-Path $TestDrive 'default') '{ "outputDir": "D:\\out" }' $null
        $cfg = Get-EffectiveSettings @{} $SettingTypes $root
        $cfg.outputDir | Should -Be 'D:\out'
    }

    It '優先順位は 引数 > settings.local.json > settings.json > 既定値 で、キー単位でマージされる' {
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

    It 'スイッチの引数は bool になる' {
        $root = New-ConfigDir (Join-Path $TestDrive 'switch') '{ "trackedOnly": false }' $null
        $cfg = Get-EffectiveSettings @{ TrackedOnly = [switch]$true } $SettingTypes $root
        $cfg.trackedOnly | Should -BeOfType [bool]
        $cfg.trackedOnly | Should -BeTrue
    }

    It "配列の引数 -Groups 'a,b' は a と b に分かれる" {
        $root = Join-Path $TestDrive 'none'
        $cfg = Get-EffectiveSettings @{ Groups = @('a,b'); Extras = @(' x , y', 'z', ',') } $SettingTypes $root
        $cfg.groups | Should -Be @('a', 'b')
        $cfg.extras | Should -Be @('x', 'y', 'z')
    }

    It '引数の pythonVersion では上書きしない(Get-PythonMinor で扱う)' {
        $root = New-ConfigDir (Join-Path $TestDrive 'pyver') '{ "pythonVersion": "3.12" }' $null
        $cfg = Get-EffectiveSettings @{ PythonVersion = '3.14' } $SettingTypes $root
        $cfg.pythonVersion | Should -Be '3.12'
    }

    It 'installer は設定ファイルと引数で切り替えられる' {
        $root = New-ConfigDir (Join-Path $TestDrive 'installer') '{ "installer": "pip" }' $null
        (Get-EffectiveSettings @{} $SettingTypes $root).installer | Should -BeExactly 'pip'
        (Get-EffectiveSettings @{ Installer = 'uv' } $SettingTypes $root).installer | Should -BeExactly 'uv'
    }

    It '引数の installer が不正ならエラー: <Value>' -ForEach @(
        @{ Value = 'conda' }
        @{ Value = 'UV' }
        @{ Value = '' }
    ) {
        $root = Join-Path $TestDrive 'none'
        { Get-EffectiveSettings @{ Installer = $Value } $SettingTypes $root } |
            Should -Throw "*設定 'installer' は `"uv`" / `"pip`" のどれかにしてください(引数 -Installer)*"
    }

    It 'winPythonArchiveFormat は設定ファイルと引数で切り替えられる' {
        $root = New-ConfigDir (Join-Path $TestDrive 'archiveformat') '{ "winPythonArchiveFormat": "7z" }' $null
        (Get-EffectiveSettings @{} $SettingTypes $root).winPythonArchiveFormat | Should -BeExactly '7z'
        (Get-EffectiveSettings @{ WinPythonArchiveFormat = 'zip' } $SettingTypes $root).winPythonArchiveFormat | Should -BeExactly 'zip'
    }

    It '引数の winPythonArchiveFormat が不正ならエラー: <Value>' -ForEach @(
        @{ Value = 'tar' }
        @{ Value = '7Z' }
        @{ Value = '' }
    ) {
        $root = Join-Path $TestDrive 'none'
        { Get-EffectiveSettings @{ WinPythonArchiveFormat = $Value } $SettingTypes $root } |
            Should -Throw "*設定 'winPythonArchiveFormat' は `"zip`" / `"7z`" のどれかにしてください(引数 -WinPythonArchiveFormat)*"
    }

    It '-ConfigPath のファイルがないとエラー' {
        $missing = Join-Path $TestDrive 'missing\settings.json'
        { Get-EffectiveSettings @{ ConfigPath = $missing } $SettingTypes $TestDrive } |
            Should -Throw "-ConfigPath で指定された設定ファイルがありません: $missing"
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

    It 'ファイルがなければ空' {
        $result = Read-SettingsFile (Join-Path $TestDrive 'nothing.json') $SettingTypes
        $result.Count | Should -Be 0
    }

    It '空のファイルは空' {
        (Read-Json "  `r`n").Count | Should -Be 0
    }

    It '配列は string[] になる' {
        $result = Read-Json '{ "exclude": ["docs/**", "tests"] }'
        , $result.exclude | Should -BeOfType [string[]]
        $result.exclude | Should -Be @('docs/**', 'tests')
    }

    It '未知のキーはエラー' {
        { Read-Json '{ "foo": 1 }' } | Should -Throw "*未知のキー 'foo'*"
    }

    It '大文字小文字だけ違うキー(outputdir)もエラー' {
        { Read-Json '{ "outputdir": "x" }' } | Should -Throw "*未知のキー 'outputdir'*"
    }

    It '型違い: <Json>' -ForEach @(
        @{ Json = '{ "trackedOnly": "yes" }'; Message = "*設定 'trackedOnly' は true / false にしてください*" }
        @{ Json = '{ "groups": "dev" }'; Message = "*設定 'groups' は文字列の配列*" }
        @{ Json = '{ "groups": [1] }'; Message = "*設定 'groups' の要素は文字列にしてください*" }
        @{ Json = '{ "pythonVersion": 3.13 }'; Message = "*設定 'pythonVersion' は文字列にしてください*" }
        @{ Json = '{ "installer": "conda" }'; Message = "*設定 'installer' は `"uv`" / `"pip`" のどれかにしてください*" }
        @{ Json = '{ "installer": "Pip" }'; Message = "*設定 'installer' は `"uv`" / `"pip`" のどれかにしてください*" }
        @{ Json = '{ "installer": ["uv"] }'; Message = "*設定 'installer' は `"uv`" / `"pip`" のどれかにしてください*" }
        @{ Json = '{ "installer": null }'; Message = "*設定 'installer' は `"uv`" / `"pip`" のどれかにしてください*" }
        @{ Json = '{ "winPythonArchiveFormat": "ZIP" }'; Message = "*設定 'winPythonArchiveFormat' は `"zip`" / `"7z`" のどれかにしてください*" }
        @{ Json = '{ "winPythonArchiveFormat": 7 }'; Message = "*設定 'winPythonArchiveFormat' は `"zip`" / `"7z`" のどれかにしてください*" }
    ) {
        { Read-Json $Json } | Should -Throw $Message
    }

    It 'JSON として読めなければエラー' {
        { Read-Json '{ "groups": ' } | Should -Throw '*設定ファイルを JSON として読めません*'
    }

    It '最上位がオブジェクトでなければエラー' {
        { Read-Json '["a"]' } | Should -Throw '*最上位は { } のオブジェクトにしてください*'
    }
}
