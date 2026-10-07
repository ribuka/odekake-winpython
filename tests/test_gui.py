"""Tests for odekake/gui.py. No dialogs are shown; only the start folder resolution (resolve_initial_dir) is tested."""

import os

import pytest

from odekake import BuildError
from odekake.gui import resolve_initial_dir


@pytest.mark.parametrize('value', [None, ''], ids=['None', 'empty string'])
def test_returns_none_when_not_set(value, logs):
    assert resolve_initial_dir(value) is None
    assert logs == []


def test_returns_an_existing_folder_as_it_is(tmp_path):
    folder = tmp_path / 'exists'
    folder.mkdir()
    assert resolve_initial_dir(str(folder)) == str(folder)


def test_normalizes_paths_that_contain_dots(tmp_path):
    folder = tmp_path / 'norm'
    (folder / 'sub').mkdir(parents=True)
    assert resolve_initial_dir(os.path.join(str(folder), 'sub', '..', '.')) == str(folder)


def test_expands_environment_variables(tmp_path, monkeypatch):
    (tmp_path / 'env').mkdir()
    monkeypatch.setenv('ODEKAKE_TEST_INITIAL_DIR', str(tmp_path))
    assert resolve_initial_dir(r'%ODEKAKE_TEST_INITIAL_DIR%\env') == str(tmp_path / 'env')


def test_warns_and_returns_none_for_a_missing_folder(tmp_path, logs):
    folder = str(tmp_path / 'missing')
    assert resolve_initial_dir(folder) is None
    assert len(logs) == 1
    assert 'initialDir' in logs[0] and folder in logs[0]


def test_warns_and_returns_none_when_the_path_is_a_file(tmp_path, logs):
    file = tmp_path / 'file.txt'
    file.write_text('x')
    assert resolve_initial_dir(str(file)) is None
    assert len(logs) == 1


@pytest.mark.parametrize('value', ['repos', r'.\repos', r'\repos', 'C:repos', r'%ODEKAKE_UNDEFINED_VAR%\repos'])
def test_fails_on_a_relative_path(value, monkeypatch):
    monkeypatch.delenv('ODEKAKE_UNDEFINED_VAR', raising=False)
    with pytest.raises(BuildError, match="Setting 'initialDir' must be an absolute path"):
        resolve_initial_dir(value)


def test_does_not_expand_dollar_names(tmp_path, monkeypatch):
    # An administrative share such as \\server\c$ must stay as it is
    monkeypatch.setenv('ODEKAKE_TEST_DOLLAR', 'expanded')
    folder = tmp_path / '$ODEKAKE_TEST_DOLLAR'
    folder.mkdir()
    assert resolve_initial_dir(str(folder)) == str(folder)
