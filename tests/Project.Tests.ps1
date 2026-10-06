# lib\Project.ps1 のテスト(Pester 5)。Get-ProjectFiles は一時フォルダに git リポジトリを作って確かめる。

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

    It '通常の name / version を読む' {
        $py = Read-Toml "[project]`nname = `"foo-bar`"`nversion = `"1.2.3`"`n"
        $py.Name | Should -Be 'foo-bar'
        $py.Version | Should -Be '1.2.3'
        $py.Dynamic.Count | Should -Be 0
    }

    It 'シングルクォートの値を読む' {
        $py = Read-Toml "[project]`nname = 'foo'`nversion = '0.1'`n"
        $py.Name | Should -Be 'foo'
        $py.Version | Should -Be '0.1'
    }

    It 'dynamic = ["version"] を読む(複数行も)' {
        (Read-Toml "[project]`nname = `"foo`"`ndynamic = [`"version`"]`n").Dynamic | Should -Be @('version')
        $py = Read-Toml "[project]`nname = `"foo`"`ndynamic = [`n    `"readme`",`n    'version',`n]`n"
        $py.Dynamic | Should -Be @('readme', 'version')
        $py.Version | Should -BeNullOrEmpty
    }

    It '[tool.x] や [[tool.uv.index]] の name を拾わない' {
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

    It '[project] に name がなければ $null' {
        (Read-Toml "[tool.x]`nname = `"tool-x`"`n[project]`nversion = `"1`"`n").Name | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProjectVersion' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        $dynamic = @{ Name = 'foo'; Version = $null; Dynamic = @('version') }
    }

    It 'pyproject の version があればそれを使う' {
        Get-ProjectVersion $root @{ Name = 'foo'; Version = '1.0'; Dynamic = @() } | Should -Be '1.0'
    }

    It 'VERSION ファイルの前後の空白・改行を除く' {
        Write-TextFile (Join-Path $root 'VERSION') "  2.3.4 `r`n`r`n"
        Get-ProjectVersion $root $dynamic | Should -Be '2.3.4'
    }

    It 'VERSION ファイルがないとエラー' {
        { Get-ProjectVersion $root $dynamic } |
            Should -Throw "pyproject.toml の version が dynamic ですが、VERSION ファイルがありません: $(Join-Path $root 'VERSION')"
    }

    It 'VERSION ファイルが2行以上あるとエラー' {
        Write-TextFile (Join-Path $root 'VERSION') "1.0`r`n2.0`r`n"
        { Get-ProjectVersion $root $dynamic } | Should -Throw '*VERSION ファイルには、バージョンを1行だけ書いてください*'
    }

    It 'version も dynamic もないとエラー' {
        { Get-ProjectVersion $root @{ Name = 'foo'; Version = $null; Dynamic = @() } } |
            Should -Throw '*`[project`] に version がありません*'
    }
}

Describe 'Get-PythonMinor' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        $pv = Join-Path $root '.python-version'
    }

    It '優先順位: 引数 > .python-version > 設定ファイル' {
        Get-PythonMinor $root '' '3.12' | Should -Be '3.12'
        Write-TextFile $pv "3.13`n"
        Get-PythonMinor $root '' '3.12' | Should -Be '3.13'
        Get-PythonMinor $root '3.14' '3.12' | Should -Be '3.14'
    }

    It "'<Raw>' を 3.13 と読む" -ForEach @(
        @{ Raw = '3.13.5' }
        @{ Raw = 'cpython-3.13' }
        @{ Raw = 'cpython-3.13.5-windows-x86_64-none' }
    ) {
        Write-TextFile $pv "# comment`n`n  $Raw  `n3.12`n"
        Get-PythonMinor $root '' '' | Should -Be '3.13'
        Get-PythonMinor (Join-Path $TestDrive 'nowhere') $Raw '' | Should -Be '3.13'
    }

    It '引数と .python-version が違うと警告する' {
        Write-TextFile $pv "3.13.1`n"
        Get-PythonMinor $root '3.12' '' | Should -Be '3.12'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '注意: .python-version (3.13.1) と異なる Python 3.12 を*' }
    }

    It '引数と .python-version が同じなら警告しない' {
        Write-TextFile $pv "3.13.1`n"
        Get-PythonMinor $root '3.13' '' | Should -Be '3.13'
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '注意:*' }
    }

    It 'どれもないとエラー' {
        { Get-PythonMinor $root '' '' } | Should -Throw '.python-version がありません。*'
    }

    It '読み取れないとエラー' {
        { Get-PythonMinor $root 'latest' '' } | Should -Throw "Python のバージョンを読み取れません(引数 -PythonVersion): 'latest'"
    }
}

Describe 'Get-ProjectFiles' {
    BeforeAll {
        # 利用者の git 設定(グローバルな除外ファイルなど)に左右されないようにする
        $savedEnv = @{}
        foreach ($key in 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM') { $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
        $emptyConfig = Join-Path $TestDrive 'empty.gitconfig'
        Write-TextFile $emptyConfig ''
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $emptyConfig, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_NOSYSTEM', '1', 'Process')
        # git の出力(core.quotepath=off)は UTF-8。build-offline.ps1 の本体と同じにする。
        $savedOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = $utf8

        # $Tracked は git add するファイル、$Untracked は置くだけのファイル(パスは / 区切り)。
        # 中身はパスと同じ文字列。$GitIgnore を渡すと、その中身の .gitignore を作って add する。
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

    Context '通常のプロジェクト' {
        BeforeAll {
            $root = New-GitProject `
                -Tracked @('pyproject.toml', 'src/pkg/__init__.py', 'tests/test_a.py', 'debug.log', 'sub/deep.log') `
                -Untracked @('new.py', 'ignored.txt', '日本語 のファイル.txt') `
                -GitIgnore "ignored.txt`n"
        }

        It '既定は未 add のファイルを含み、.gitignore のファイルは含まない' {
            $files = Get-ProjectFiles $root $false @()
            $files | Should -Contain 'new.py'
            $files | Should -Contain 'src/pkg/__init__.py'
            $files | Should -Not -Contain 'ignored.txt'
        }

        It 'trackedOnly では add 済みのファイルだけ' {
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

        It '日本語のファイル名をそのまま返す' {
            $files = Get-ProjectFiles $root $false @()
            $files | Should -Contain '日本語 のファイル.txt'
        }
    }

    It '削除済みのファイルはスキップする' {
        $root = New-GitProject -Tracked @('keep.txt', 'gone.txt')
        Remove-Item -LiteralPath (Join-Path $root 'gone.txt')
        $files = Get-ProjectFiles $root $false @()
        $files | Should -Be @('keep.txt')
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq 'スキップ(ファイルとして存在しない): gone.txt' }
    }

    It "'<Rel>' があると成果物と衝突するのでエラー" -ForEach @(
        @{ Rel = 'winpython.zip' }
        @{ Rel = 'winpython.7z' }
        @{ Rel = 'winpython/readme.txt' }
    ) {
        $root = New-GitProject -Tracked @('a.txt') -Untracked @($Rel)
        { Get-ProjectFiles $root $false @() } | Should -Throw "対象プロジェクトに '$Rel' があり、*"
    }

    It 'ファイルが1つもないとエラー' {
        $root = New-GitProject -Tracked @() -Untracked @()
        { Get-ProjectFiles $root $false @() } | Should -Throw 'ZIP に入れるファイルが1つもありません。'
    }

    Context 'export-ignore' {
        BeforeAll {
            $root = New-GitProject `
                -Tracked @('.gitattributes', 'keep.py', 'tests/test_a.py', 'tests/sub/test_b.py', 'docs/a.md', 'a/tests/x.py',
                    'a/docs/y.md', 'debug.log', 'sub/deep.log', 'only.txt', 'value.txt', 'unset.txt', 'pkg/.gitattributes', 'pkg/gen.py', 'pkg/main.py') `
                -Untracked @('tests/new_test.py', 'new.log', '日本語/除外.txt')
            # /tests/ は最上位のフォルダだけ、docs(/ なし)はどの階層のフォルダにも当たる
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

        It '既定では export-ignore のファイル・フォルダを含めない' {
            $files = Get-ProjectFiles $root $false @()
            @($files | Sort-Object) | Should -Be @('a/tests/x.py', 'keep.py', 'pkg/main.py', 'unset.txt', 'value.txt')
        }

        It 'includeExportIgnored では含める' {
            $files = Get-ProjectFiles $root $false @() $true
            $files | Should -Contain 'tests/sub/test_b.py'
            $files | Should -Contain 'tests/new_test.py'
            $files | Should -Contain 'a/docs/y.md'
            $files | Should -Contain '.gitattributes'
            $files | Should -Contain 'pkg/gen.py'
            $files | Should -Contain '日本語/除外.txt'
            $files.Count | Should -Be 18
        }

        It '除いたファイルをログに出す' {
            $null = Get-ProjectFiles $root $false @()
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq '除外(export-ignore): tests/sub/test_b.py' }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq '除外(export-ignore): 日本語/除外.txt' }
        }

        It 'trackedOnly・exclude と併用できる' {
            $files = Get-ProjectFiles $root $true @('keep.py')
            @($files | Sort-Object) | Should -Be @('a/tests/x.py', 'pkg/main.py', 'unset.txt', 'value.txt')
        }
    }

    It 'export-ignore の winpython.zip は衝突のエラーにしない' {
        $root = New-GitProject -Tracked @('a.txt') -Untracked @('winpython.zip', 'winpython/readme.txt')
        Write-TextFile (Join-Path $root '.gitattributes') "winpython.zip export-ignore`n/winpython/ export-ignore`n"
        $files = Get-ProjectFiles $root $false @()
        @($files | Sort-Object) | Should -Be @('.gitattributes', 'a.txt')
    }

    It 'すべて export-ignore ならエラー' {
        $root = New-GitProject -Tracked @('.gitattributes', 'a.txt')
        Write-TextFile (Join-Path $root '.gitattributes') "* export-ignore`n"
        { Get-ProjectFiles $root $false @() } | Should -Throw 'ZIP に入れるファイルが1つもありません。'
    }

    It 'パスが多くても分けて問い合わせる' {
        $names = @(1..400 | ForEach-Object { 'dir_{0:d3}/file_with_a_long_name_{0:d3}.txt' -f $_ })
        $root = New-GitProject -Tracked @('.gitattributes') -Untracked $names
        Write-TextFile (Join-Path $root '.gitattributes') "/dir_400/ export-ignore`n*7.txt export-ignore`n"
        $files = Get-ProjectFiles $root $false @()
        $files.Count | Should -Be 360
        $files | Should -Not -Contain 'dir_400/file_with_a_long_name_400.txt'
        $files | Should -Not -Contain 'dir_007/file_with_a_long_name_007.txt'
        # Invoke-Native はコマンドラインを Write-Log に出す
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

    It 'PyPI 以外の registry の依存を返す(名前は正規化して照合する)' {
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

    It 'PyPI の依存だけなら空(同名で版違いの非公開パッケージや、requirements にない依存は見ない)' {
        $req = Write-Requirements "my-lib==0.0.1 \`n    --hash=sha256:00`nrequests==2.32.3`n"
        $result = Get-NonPyPIRequirements $lock $req $pypi
        , $result | Should -BeOfType [string[]]
        $result.Count | Should -Be 0
    }

    It '同じ name==version が registry 違いで複数あれば、PyPI 以外のものを1回だけ返す' {
        $req = Write-Requirements "idna==3.10 ; sys_platform == 'win32' \`n    --hash=sha256:22`nidna==3.10 ; sys_platform != 'win32'`n"
        $result = Get-NonPyPIRequirements $lock $req $pypi
        $result | Should -Be @('idna==3.10 (https://hoge.example/simple)')
    }

    It 'URL の末尾の / は区別しない' {
        $req = Write-Requirements "requests==2.32.3`n"
        (Get-NonPyPIRequirements $lock $req 'https://pypi.org/simple/').Count | Should -Be 0
    }
}
