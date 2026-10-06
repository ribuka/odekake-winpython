# Tests for lib\Project.ps1 (Pester 5). Get-ProjectFiles is tested with git repositories created in a temporary folder.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Log.ps1')
    . (Join-Path $repo 'lib\Project.ps1')

    Mock Write-Log { }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    function Write-TextFile([string]$Path, [string]$Text) {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Text, $utf8)
    }
}

Describe 'Read-PyProject' {
    BeforeAll {
        function Read-Toml([string]$Toml) {
            $path = Join-Path $TestDrive ('{0}.toml' -f [guid]::NewGuid())
            Write-TextFile $path $Toml
            return Read-PyProject $path
        }
    }

    It 'reads a plain name / version' {
        $py = Read-Toml "[project]`nname = `"foo-bar`"`nversion = `"1.2.3`"`n"
        $py.Name | Should -Be 'foo-bar'
        $py.Version | Should -Be '1.2.3'
        $py.Dynamic.Count | Should -Be 0
    }

    It 'reads single-quoted values' {
        $py = Read-Toml "[project]`nname = 'foo'`nversion = '0.1'`n"
        $py.Name | Should -Be 'foo'
        $py.Version | Should -Be '0.1'
    }

    It 'reads dynamic = ["version"] (including multi-line)' {
        (Read-Toml "[project]`nname = `"foo`"`ndynamic = [`"version`"]`n").Dynamic | Should -Be @('version')
        $py = Read-Toml "[project]`nname = `"foo`"`ndynamic = [`n    `"readme`",`n    'version',`n]`n"
        $py.Dynamic | Should -Be @('readme', 'version')
        $py.Version | Should -BeNullOrEmpty
    }

    It 'ignores name in [tool.x] and [[tool.uv.index]]' {
        $toml = @(
            '[tool.x]', 'name = "tool-x"',
            '[project]  # comment', 'name = "right"', 'version = "1"',
            '[[tool.uv.index]]', 'name = "index"', 'version = "9"',
            '[build-system]', 'name = "build"'
        ) -join "`n"
        $py = Read-Toml $toml
        $py.Name | Should -Be 'right'
        $py.Version | Should -Be '1'
    }

    It 'returns $null when [project] has no name' {
        (Read-Toml "[tool.x]`nname = `"tool-x`"`n[project]`nversion = `"1`"`n").Name | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProjectVersion' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        $dynamic = @{ Name = 'foo'; Version = $null; Dynamic = @('version') }
    }

    It 'uses version from pyproject when present' {
        Get-ProjectVersion $root @{ Name = 'foo'; Version = '1.0'; Dynamic = @() } | Should -Be '1.0'
    }

    It 'trims whitespace and newlines around the VERSION file' {
        Write-TextFile (Join-Path $root 'VERSION') "  2.3.4 `r`n`r`n"
        Get-ProjectVersion $root $dynamic | Should -Be '2.3.4'
    }

    It 'fails without a VERSION file' {
        { Get-ProjectVersion $root $dynamic } |
            Should -Throw "version in pyproject.toml is dynamic, but there is no VERSION file: $(Join-Path $root 'VERSION')"
    }

    It 'fails when the VERSION file has more than one line' {
        Write-TextFile (Join-Path $root 'VERSION') "1.0`r`n2.0`r`n"
        { Get-ProjectVersion $root $dynamic } | Should -Throw '*The VERSION file must contain the version on a single line*'
    }

    It 'fails without version or dynamic' {
        { Get-ProjectVersion $root @{ Name = 'foo'; Version = $null; Dynamic = @() } } |
            Should -Throw '*has no version in `[project`]*'
    }
}

Describe 'Get-PythonMinor' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        $pv = Join-Path $root '.python-version'
    }

    It 'priority: argument > .python-version > settings file' {
        Get-PythonMinor $root '' '3.12' | Should -Be '3.12'
        Write-TextFile $pv "3.13`n"
        Get-PythonMinor $root '' '3.12' | Should -Be '3.13'
        Get-PythonMinor $root '3.14' '3.12' | Should -Be '3.14'
    }

    It "reads '<Raw>' as 3.13" -ForEach @(
        @{ Raw = '3.13.5' }
        @{ Raw = 'cpython-3.13' }
        @{ Raw = 'cpython-3.13.5-windows-x86_64-none' }
    ) {
        Write-TextFile $pv "# comment`n`n  $Raw  `n3.12`n"
        Get-PythonMinor $root '' '' | Should -Be '3.13'
        Get-PythonMinor (Join-Path $TestDrive 'nowhere') $Raw '' | Should -Be '3.13'
    }

    It 'warns when the argument differs from .python-version' {
        Write-TextFile $pv "3.13.1`n"
        Get-PythonMinor $root '3.12' '' | Should -Be '3.12'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Warning: using Python 3.12 as specified by argument -PythonVersion, which differs from .python-version (3.13.1).' }
    }

    It 'does not warn when the argument matches .python-version' {
        Write-TextFile $pv "3.13.1`n"
        Get-PythonMinor $root '3.13' '' | Should -Be '3.13'
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like 'Warning:*' }
    }

    It 'fails when none is given' {
        { Get-PythonMinor $root '' '' } | Should -Throw '.python-version not found. *'
    }

    It 'fails when the version cannot be read' {
        { Get-PythonMinor $root 'latest' '' } | Should -Throw "Cannot read the Python version (argument -PythonVersion): 'latest'"
    }
}

Describe 'Get-ProjectFiles' {
    BeforeAll {
        # Keep the user's git config (such as a global excludes file) from affecting the tests
        $savedEnv = @{}
        foreach ($key in 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM') { $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
        $emptyConfig = Join-Path $TestDrive 'empty.gitconfig'
        Write-TextFile $emptyConfig ''
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $emptyConfig, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_NOSYSTEM', '1', 'Process')
        # git output (core.quotepath=off) is UTF-8. Same as the main part of build-offline.ps1.
        $savedOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = $utf8

        # $Tracked are files to git add, $Untracked are files only placed in the folder (paths separated by /).
        # Each file contains its own path. With $GitIgnore, a .gitignore with that content is created and added.
        function New-GitProject([string[]]$Tracked, [string[]]$Untracked = @(), [string]$GitIgnore) {
            $root = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $root | Out-Null
            & git -C $root init -q
            foreach ($rel in $Tracked + $Untracked) { Write-TextFile (Join-Path $root ($rel -replace '/', '\')) $rel }
            if ($GitIgnore) {
                Write-TextFile (Join-Path $root '.gitignore') $GitIgnore
                $Tracked += '.gitignore'
            }
            if ($Tracked) { & git -C $root -c core.quotepath=off add -- $Tracked }
            return $root
        }
    }

    AfterAll {
        [Console]::OutputEncoding = $savedOutputEncoding
        foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    }

    Context 'regular project' {
        BeforeAll {
            $root = New-GitProject `
                -Tracked @('pyproject.toml', 'src/pkg/__init__.py', 'tests/test_a.py', 'debug.log', 'sub/deep.log') `
                -Untracked @('new.py', 'ignored.txt', '日本語 のファイル.txt') `
                -GitIgnore "ignored.txt`n"
        }

        It 'includes files not yet added but not .gitignore-d files by default' {
            $files = Get-ProjectFiles $root $false @()
            $files | Should -Contain 'new.py'
            $files | Should -Contain 'src/pkg/__init__.py'
            $files | Should -Not -Contain 'ignored.txt'
        }

        It 'returns only added files with trackedOnly' {
            $files = Get-ProjectFiles $root $true @()
            @($files | Sort-Object) | Should -Be @('.gitignore', 'debug.log', 'pyproject.toml', 'src/pkg/__init__.py', 'sub/deep.log', 'tests/test_a.py')
        }

        It "exclude '<Pattern>'" -ForEach @(
            @{ Pattern = 'tests'; Excluded = @('tests/test_a.py'); Kept = @('debug.log', 'sub/deep.log') }
            @{ Pattern = '*.log'; Excluded = @('debug.log'); Kept = @('sub/deep.log', 'tests/test_a.py') }
            @{ Pattern = '**/*.log'; Excluded = @('debug.log', 'sub/deep.log'); Kept = @('tests/test_a.py') }
        ) {
            $files = Get-ProjectFiles $root $false @($Pattern)
            foreach ($f in $Excluded) { $files | Should -Not -Contain $f }
            foreach ($f in $Kept) { $files | Should -Contain $f }
        }

        It 'returns Japanese file names as they are' {
            $files = Get-ProjectFiles $root $false @()
            $files | Should -Contain '日本語 のファイル.txt'
        }
    }

    It 'skips deleted files' {
        $root = New-GitProject -Tracked @('keep.txt', 'gone.txt')
        Remove-Item -LiteralPath (Join-Path $root 'gone.txt')
        $files = Get-ProjectFiles $root $false @()
        $files | Should -Be @('keep.txt')
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq 'Skipped (not an existing file): gone.txt' }
    }

    It "fails because '<Rel>' conflicts with the output" -ForEach @(
        @{ Rel = 'winpython.zip' }
        @{ Rel = 'winpython.7z' }
        @{ Rel = 'winpython/readme.txt' }
    ) {
        $root = New-GitProject -Tracked @('a.txt') -Untracked @($Rel)
        { Get-ProjectFiles $root $false @() } | Should -Throw "The target project has '$Rel', which conflicts *"
    }

    It 'fails when there are no files' {
        $root = New-GitProject -Tracked @() -Untracked @()
        { Get-ProjectFiles $root $false @() } | Should -Throw 'There are no files to put into the ZIP.'
    }

    Context 'export-ignore' {
        BeforeAll {
            $root = New-GitProject `
                -Tracked @('.gitattributes', 'keep.py', 'tests/test_a.py', 'tests/sub/test_b.py', 'docs/a.md', 'a/tests/x.py',
                    'a/docs/y.md', 'debug.log', 'sub/deep.log', 'only.txt', 'value.txt', 'unset.txt', 'pkg/.gitattributes', 'pkg/gen.py', 'pkg/main.py') `
                -Untracked @('tests/new_test.py', 'new.log', '日本語/除外.txt')
            # /tests/ matches only the top-level folder; docs (without /) matches a folder at any level
            Write-TextFile (Join-Path $root '.gitattributes') @"
/tests/ export-ignore
docs export-ignore
*.log export-ignore
/only.txt export-ignore
/value.txt export-ignore=yes
/unset.txt -export-ignore
.gitattributes export-ignore
/日本語/ export-ignore
"@
            Write-TextFile (Join-Path $root 'pkg\.gitattributes') "gen.py export-ignore`n"
        }

        It 'leaves out export-ignore files and folders by default' {
            $files = Get-ProjectFiles $root $false @()
            @($files | Sort-Object) | Should -Be @('a/tests/x.py', 'keep.py', 'pkg/main.py', 'unset.txt', 'value.txt')
        }

        It 'includes them with includeExportIgnored' {
            $files = Get-ProjectFiles $root $false @() $true
            $files | Should -Contain 'tests/sub/test_b.py'
            $files | Should -Contain 'tests/new_test.py'
            $files | Should -Contain 'a/docs/y.md'
            $files | Should -Contain '.gitattributes'
            $files | Should -Contain 'pkg/gen.py'
            $files | Should -Contain '日本語/除外.txt'
            $files.Count | Should -Be 18
        }

        It 'logs the files left out' {
            $null = Get-ProjectFiles $root $false @()
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq 'Excluded (export-ignore): tests/sub/test_b.py' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq 'Excluded (export-ignore): 日本語/除外.txt' }
        }

        It 'works together with trackedOnly and exclude' {
            $files = Get-ProjectFiles $root $true @('keep.py')
            @($files | Sort-Object) | Should -Be @('a/tests/x.py', 'pkg/main.py', 'unset.txt', 'value.txt')
        }
    }

    It 'does not report a conflict for an export-ignore winpython.zip' {
        $root = New-GitProject -Tracked @('a.txt') -Untracked @('winpython.zip', 'winpython/readme.txt')
        Write-TextFile (Join-Path $root '.gitattributes') "winpython.zip export-ignore`n/winpython/ export-ignore`n"
        $files = Get-ProjectFiles $root $false @()
        @($files | Sort-Object) | Should -Be @('.gitattributes', 'a.txt')
    }

    It 'fails when everything is export-ignore' {
        $root = New-GitProject -Tracked @('.gitattributes', 'a.txt')
        Write-TextFile (Join-Path $root '.gitattributes') "* export-ignore`n"
        { Get-ProjectFiles $root $false @() } | Should -Throw 'There are no files to put into the ZIP.'
    }

    It 'queries in chunks when there are many paths' {
        $names = @(1..400 | ForEach-Object { 'dir_{0:d3}/file_with_a_long_name_{0:d3}.txt' -f $_ })
        $root = New-GitProject -Tracked @('.gitattributes') -Untracked $names
        Write-TextFile (Join-Path $root '.gitattributes') "/dir_400/ export-ignore`n*7.txt export-ignore`n"
        $files = Get-ProjectFiles $root $false @()
        $files.Count | Should -Be 360
        $files | Should -Not -Contain 'dir_400/file_with_a_long_name_400.txt'
        $files | Should -Not -Contain 'dir_007/file_with_a_long_name_007.txt'
        # Invoke-Native writes the command line with Write-Log
        Should -Invoke Write-Log -ParameterFilter { $Message -like '> git * check-attr *' } -Times 2
    }
}

Describe 'Get-NonPyPIRequirements' {
    BeforeAll {
        $pypi = 'https://pypi.org/simple'
        $lock = Join-Path $TestDrive 'uv.lock'
        Write-TextFile $lock @'
version = 1
revision = 3
requires-python = ">=3.13"

[[package]]
name = "app"
version = "0.1.0"
source = { editable = "." }
dependencies = [
    { name = "my-lib" },
    { name = "requests" },
]

[package.metadata]
requires-dist = [{ name = "my-lib", index = "https://hoge.example/simple" }]

[[package]]
name = "my-lib"
version = "0.1.0"
source = { registry = "https://hoge.example/simple" }
wheels = [
    { url = "https://hoge.example/my_lib-0.1.0-py3-none-any.whl", hash = "sha256:00" },
]

[[package]]
name = "my-lib"
version = "0.0.1"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "dev-only"
version = "1.0.0"
source = { registry = "https://hoge.example/simple" }

[[package]]
name = "requests"
version = "2.32.3"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "idna"
version = "3.10"
source = { registry = "https://hoge.example/simple" }
resolution-markers = [
    "sys_platform == 'win32'",
]

[[package]]
name = "idna"
version = "3.10"
source = { registry = "https://pypi.org/simple" }
resolution-markers = [
    "sys_platform != 'win32'",
]

[[package]]
name = "local-pkg"
version = "0.1.0"
source = { directory = "../local-pkg" }
'@
        function Write-Requirements([string]$Text) {
            $path = Join-Path $TestDrive ('{0}.txt' -f [guid]::NewGuid())
            Write-TextFile $path $Text
            return $path
        }
    }

    It 'returns dependencies from a registry other than PyPI (names are normalized before matching)' {
        $req = Write-Requirements @'
# This file was autogenerated by uv via the following command:
#    uv export --frozen --no-emit-project
My_Lib==0.1.0 \
    --hash=sha256:00
requests==2.32.3 ; python_full_version >= '3.13' \
    --hash=sha256:11
./local-pkg
'@
        $result = Get-NonPyPIRequirements $lock $req $pypi
        $result | Should -Be @('my-lib==0.1.0 (https://hoge.example/simple)')
    }

    It 'returns nothing for PyPI-only dependencies (ignores a private package with the same name but another version, and dependencies not in requirements)' {
        $req = Write-Requirements "my-lib==0.0.1 \`n    --hash=sha256:00`nrequests==2.32.3`n"
        $result = Get-NonPyPIRequirements $lock $req $pypi
        , $result | Should -BeOfType [string[]]
        $result.Count | Should -Be 0
    }

    It 'returns the non-PyPI one once when the same name==version has several registries' {
        $req = Write-Requirements "idna==3.10 ; sys_platform == 'win32' \`n    --hash=sha256:22`nidna==3.10 ; sys_platform != 'win32'`n"
        $result = Get-NonPyPIRequirements $lock $req $pypi
        $result | Should -Be @('idna==3.10 (https://hoge.example/simple)')
    }

    It 'ignores a trailing / in the URL' {
        $req = Write-Requirements "requests==2.32.3`n"
        (Get-NonPyPIRequirements $lock $req 'https://pypi.org/simple/').Count | Should -Be 0
    }
}
