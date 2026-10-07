"""Tests for odekake/project.py. get_project_files is tested with git repositories created in a temporary folder."""

import os
import subprocess
import uuid

import pytest

from conftest import write_text
from odekake import BuildError, log
from odekake.project import (
    get_non_pypi_requirements,
    get_project_files,
    get_project_version,
    get_python_minor,
    read_pyproject,
)


class TestReadPyproject:
    @staticmethod
    def read_toml(tmp_path, toml):
        path = tmp_path / f'{uuid.uuid4()}.toml'
        write_text(path, toml)
        return read_pyproject(str(path))

    def test_reads_a_plain_name_and_version(self, tmp_path):
        py = self.read_toml(tmp_path, '[project]\nname = "foo-bar"\nversion = "1.2.3"\n')
        assert py == {'name': 'foo-bar', 'version': '1.2.3', 'dynamic': []}

    def test_reads_single_quoted_values(self, tmp_path):
        py = self.read_toml(tmp_path, "[project]\nname = 'foo'\nversion = '0.1'\n")
        assert (py['name'], py['version']) == ('foo', '0.1')

    def test_reads_dynamic_version_including_multi_line(self, tmp_path):
        assert self.read_toml(tmp_path, '[project]\nname = "foo"\ndynamic = ["version"]\n')['dynamic'] == ['version']
        py = self.read_toml(tmp_path, '[project]\nname = "foo"\ndynamic = [\n    "readme",\n    \'version\',\n]\n')
        assert py['dynamic'] == ['readme', 'version']
        assert py['version'] is None

    def test_reads_values_that_are_not_single_line_strings(self, tmp_path):
        py = self.read_toml(tmp_path, '[project]\nname = """foo"""\nversion = "1"  # comment\n')
        assert (py['name'], py['version']) == ('foo', '1')
        py = self.read_toml(tmp_path, 'project = { name = "inline", version = "2" }\n')
        assert (py['name'], py['version']) == ('inline', '2')

    def test_ignores_name_in_other_tables(self, tmp_path):
        toml = '\n'.join([
            '[tool.x]', 'name = "tool-x"',
            '[project]  # comment', 'name = "right"', 'version = "1"',
            '[[tool.uv.index]]', 'name = "index"', 'version = "9"',
            '[build-system]', 'name = "build"',
        ])
        py = self.read_toml(tmp_path, toml)
        assert (py['name'], py['version']) == ('right', '1')

    def test_returns_none_when_project_has_no_name(self, tmp_path):
        assert self.read_toml(tmp_path, '[tool.x]\nname = "tool-x"\n[project]\nversion = "1"\n')['name'] is None

    def test_fails_on_invalid_toml(self, tmp_path):
        with pytest.raises(BuildError, match='Cannot read pyproject.toml as TOML'):
            self.read_toml(tmp_path, '[project\nname = "foo"\n')


class TestGetProjectVersion:
    DYNAMIC = {'name': 'foo', 'version': None, 'dynamic': ['version']}

    def test_uses_version_from_pyproject_when_present(self, tmp_path):
        assert get_project_version(str(tmp_path), {'name': 'foo', 'version': '1.0', 'dynamic': []}) == '1.0'

    def test_trims_whitespace_and_newlines_around_the_version_file(self, tmp_path):
        write_text(tmp_path / 'VERSION', '  2.3.4 \r\n\r\n')
        assert get_project_version(str(tmp_path), self.DYNAMIC) == '2.3.4'

    def test_fails_without_a_version_file(self, tmp_path):
        with pytest.raises(BuildError) as e:
            get_project_version(str(tmp_path), self.DYNAMIC)
        assert str(e.value) == (
            f"version in pyproject.toml is dynamic, but there is no VERSION file: {os.path.join(tmp_path, 'VERSION')}"
        )

    def test_fails_when_the_version_file_has_more_than_one_line(self, tmp_path):
        write_text(tmp_path / 'VERSION', '1.0\r\n2.0\r\n')
        with pytest.raises(BuildError, match='The VERSION file must contain the version on a single line'):
            get_project_version(str(tmp_path), self.DYNAMIC)

    def test_fails_without_version_or_dynamic(self, tmp_path):
        with pytest.raises(BuildError, match=r'has no version in \[project\]'):
            get_project_version(str(tmp_path), {'name': 'foo', 'version': None, 'dynamic': []})


class TestGetPythonMinor:
    def test_priority_argument_then_python_version_file_then_settings(self, tmp_path):
        assert get_python_minor(str(tmp_path), None, '3.12') == '3.12'
        write_text(tmp_path / '.python-version', '3.13\n')
        assert get_python_minor(str(tmp_path), None, '3.12') == '3.13'
        assert get_python_minor(str(tmp_path), '3.14', '3.12') == '3.14'

    @pytest.mark.parametrize('raw', ['3.13.5', 'cpython-3.13', 'cpython-3.13.5-windows-x86_64-none'])
    def test_reads_as_3_13(self, raw, tmp_path):
        write_text(tmp_path / '.python-version', f'# comment\n\n  {raw}  \n3.12\n')
        assert get_python_minor(str(tmp_path), None, None) == '3.13'
        assert get_python_minor(str(tmp_path / 'nowhere'), raw, None) == '3.13'

    def test_warns_when_the_argument_differs_from_the_python_version_file(self, tmp_path, logs):
        write_text(tmp_path / '.python-version', '3.13.1\n')
        assert get_python_minor(str(tmp_path), '3.12', None) == '3.12'
        warning = (
            'Warning: using Python 3.12 as specified by argument --python-version, '
            'which differs from .python-version (3.13.1).'
        )
        assert logs.count(warning) == 1

    def test_does_not_warn_when_the_argument_matches_the_python_version_file(self, tmp_path, logs):
        write_text(tmp_path / '.python-version', '3.13.1\n')
        assert get_python_minor(str(tmp_path), '3.13', None) == '3.13'
        assert not [m for m in logs if m.startswith('Warning:')]

    def test_fails_when_none_is_given(self, tmp_path):
        with pytest.raises(BuildError, match=r'^\.python-version not found\. '):
            get_python_minor(str(tmp_path), None, None)

    def test_fails_when_the_version_cannot_be_read(self, tmp_path):
        with pytest.raises(BuildError) as e:
            get_python_minor(str(tmp_path), 'latest', None)
        assert str(e.value) == "Cannot read the Python version (argument --python-version): 'latest'"


@pytest.fixture
def new_git_project(tmp_path, monkeypatch):
    """Returns a function that creates a git repository in a temporary folder and returns its path.

    tracked are files to git add, untracked are files only placed in the folder (paths separated by /).
    Each file contains its own path. With gitignore, a .gitignore with that content is created and added.
    """
    # Keep the user's git config (such as a global excludes file) from affecting the tests
    empty_config = tmp_path / 'empty.gitconfig'
    write_text(empty_config, '')
    monkeypatch.setenv('GIT_CONFIG_GLOBAL', str(empty_config))
    monkeypatch.setenv('GIT_CONFIG_NOSYSTEM', '1')

    def create(tracked, untracked=(), gitignore=None):
        root = tmp_path / str(uuid.uuid4())
        root.mkdir()
        subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
        tracked = list(tracked)
        for rel in [*tracked, *untracked]:
            write_text(root / rel, rel)
        if gitignore:
            write_text(root / '.gitignore', gitignore)
            tracked.append('.gitignore')
        if tracked:
            subprocess.run(['git', '-C', str(root), '-c', 'core.quotepath=off', 'add', '--', *tracked], check=True)
        return str(root)

    return create


class TestGetProjectFiles:
    @pytest.fixture
    def regular(self, new_git_project):
        return new_git_project(
            ['pyproject.toml', 'src/pkg/__init__.py', 'tests/test_a.py', 'debug.log', 'sub/deep.log'],
            ['new.py', 'ignored.txt', '日本語 のファイル.txt'],
            gitignore='ignored.txt\n',
        )

    def test_includes_files_not_yet_added_but_not_gitignored_files_by_default(self, regular):
        files = get_project_files(regular, False, [])
        assert 'new.py' in files
        assert 'src/pkg/__init__.py' in files
        assert 'ignored.txt' not in files

    def test_returns_only_added_files_with_tracked_only(self, regular):
        assert sorted(get_project_files(regular, True, [])) == [
            '.gitignore', 'debug.log', 'pyproject.toml', 'src/pkg/__init__.py', 'sub/deep.log', 'tests/test_a.py',
        ]

    @pytest.mark.parametrize(
        ('pattern', 'excluded', 'kept'),
        [
            ('tests', ['tests/test_a.py'], ['debug.log', 'sub/deep.log']),
            ('*.log', ['debug.log'], ['sub/deep.log', 'tests/test_a.py']),
            ('**/*.log', ['debug.log', 'sub/deep.log'], ['tests/test_a.py']),
        ],
    )
    def test_exclude(self, regular, pattern, excluded, kept):
        files = get_project_files(regular, False, [pattern])
        assert not set(excluded) & set(files)
        assert set(kept) <= set(files)

    def test_returns_japanese_file_names_as_they_are(self, regular):
        assert '日本語 のファイル.txt' in get_project_files(regular, False, [])

    def test_skips_deleted_files(self, new_git_project, logs):
        root = new_git_project(['keep.txt', 'gone.txt'])
        os.remove(os.path.join(root, 'gone.txt'))
        assert get_project_files(root, False, []) == ['keep.txt']
        assert logs.count('Skipped (not an existing file): gone.txt') == 1

    @pytest.mark.parametrize('rel', ['winpython.zip', 'winpython.7z', 'winpython/readme.txt', 'WinPython.ZIP'])
    def test_fails_because_the_file_conflicts_with_the_output(self, new_git_project, rel):
        root = new_git_project(['a.txt'], [rel])
        with pytest.raises(BuildError, match=f"^The target project has '{rel}', which conflicts "):
            get_project_files(root, False, [])

    def test_fails_when_there_are_no_files(self, new_git_project):
        root = new_git_project([])
        with pytest.raises(BuildError, match=r'^There are no files to put into the ZIP\.$'):
            get_project_files(root, False, [])


class TestGetProjectFilesExportIgnore:
    @pytest.fixture
    def root(self, new_git_project):
        root = new_git_project(
            [
                '.gitattributes', 'keep.py', 'tests/test_a.py', 'tests/sub/test_b.py', 'docs/a.md', 'a/tests/x.py',
                'a/docs/y.md', 'debug.log', 'sub/deep.log', 'only.txt', 'value.txt', 'unset.txt',
                'pkg/.gitattributes', 'pkg/gen.py', 'pkg/main.py',
            ],
            ['tests/new_test.py', 'new.log', '日本語/除外.txt'],
        )
        # /tests/ matches only the top-level folder; docs (without /) matches a folder at any level
        write_text(os.path.join(root, '.gitattributes'), '\n'.join([
            '/tests/ export-ignore',
            'docs export-ignore',
            '*.log export-ignore',
            '/only.txt export-ignore',
            '/value.txt export-ignore=yes',
            '/unset.txt -export-ignore',
            '.gitattributes export-ignore',
            '/日本語/ export-ignore',
            '',
        ]))
        write_text(os.path.join(root, 'pkg', '.gitattributes'), 'gen.py export-ignore\n')
        return root

    def test_leaves_out_export_ignore_files_and_folders_by_default(self, root):
        assert sorted(get_project_files(root, False, [])) == [
            'a/tests/x.py', 'keep.py', 'pkg/main.py', 'unset.txt', 'value.txt',
        ]

    def test_includes_them_with_include_export_ignored(self, root):
        files = get_project_files(root, False, [], True)
        for rel in ['tests/sub/test_b.py', 'tests/new_test.py', 'a/docs/y.md', '.gitattributes', 'pkg/gen.py', '日本語/除外.txt']:
            assert rel in files
        assert len(files) == 18

    def test_logs_the_files_left_out(self, root, logs):
        get_project_files(root, False, [])
        assert logs.count('Excluded (export-ignore): tests/sub/test_b.py') == 1
        assert logs.count('Excluded (export-ignore): 日本語/除外.txt') == 1

    def test_works_together_with_tracked_only_and_exclude(self, root):
        assert sorted(get_project_files(root, True, ['keep.py'])) == ['a/tests/x.py', 'pkg/main.py', 'unset.txt', 'value.txt']


def test_does_not_report_a_conflict_for_an_export_ignore_winpython_zip(new_git_project):
    root = new_git_project(['a.txt'], ['winpython.zip', 'winpython/readme.txt'])
    write_text(os.path.join(root, '.gitattributes'), 'winpython.zip export-ignore\n/winpython/ export-ignore\n')
    assert sorted(get_project_files(root, False, [])) == ['.gitattributes', 'a.txt']


def test_fails_when_everything_is_export_ignore(new_git_project):
    root = new_git_project(['.gitattributes', 'a.txt'])
    write_text(os.path.join(root, '.gitattributes'), '* export-ignore\n')
    with pytest.raises(BuildError, match=r'^There are no files to put into the ZIP\.$'):
        get_project_files(root, False, [])


def test_queries_many_paths_with_a_single_check_attr_call(new_git_project, monkeypatch):
    names = [f'dir_{i:03}/file_with_a_long_name_{i:03}.txt' for i in range(1, 401)]
    root = new_git_project(['.gitattributes'], names)
    write_text(os.path.join(root, '.gitattributes'), '/dir_400/ export-ignore\n*7.txt export-ignore\n')
    calls = []
    original_run = log.run
    monkeypatch.setattr(log, 'run', lambda file_path, args, **kw: calls.append(args) or original_run(file_path, args, **kw))
    files = get_project_files(root, False, [])
    assert len(files) == 360
    assert 'dir_400/file_with_a_long_name_400.txt' not in files
    assert 'dir_007/file_with_a_long_name_007.txt' not in files
    assert len([a for a in calls if 'check-attr' in a]) == 1


class TestGetNonPypiRequirements:
    PYPI = 'https://pypi.org/simple'
    LOCK = '''version = 1
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
'''

    @pytest.fixture
    def check(self, tmp_path):
        lock = tmp_path / 'uv.lock'
        write_text(lock, self.LOCK)

        def run(requirements, index=self.PYPI):
            path = tmp_path / f'{uuid.uuid4()}.txt'
            write_text(path, requirements)
            return get_non_pypi_requirements(str(lock), str(path), index)

        return run

    def test_returns_dependencies_from_a_registry_other_than_pypi_with_normalized_names(self, check):
        requirements = '\n'.join([
            '# This file was autogenerated by uv via the following command:',
            '#    uv export --frozen --no-emit-project',
            'My_Lib==0.1.0 \\',
            '    --hash=sha256:00',
            "requests==2.32.3 ; python_full_version >= '3.13' \\",
            '    --hash=sha256:11',
            './local-pkg',
            '',
        ])
        assert check(requirements) == ['my-lib==0.1.0 (https://hoge.example/simple)']

    def test_returns_nothing_for_pypi_only_dependencies(self, check):
        # A private package with the same name but another version, and dependencies not in requirements, are ignored
        assert check('my-lib==0.0.1 \\\n    --hash=sha256:00\nrequests==2.32.3\n') == []

    def test_returns_the_non_pypi_one_once_when_the_same_name_version_has_several_registries(self, check):
        requirements = "idna==3.10 ; sys_platform == 'win32' \\\n    --hash=sha256:22\nidna==3.10 ; sys_platform != 'win32'\n"
        assert check(requirements) == ['idna==3.10 (https://hoge.example/simple)']

    def test_ignores_a_trailing_slash_in_the_url(self, check):
        assert check('requests==2.32.3\n', 'https://pypi.org/simple/') == []
