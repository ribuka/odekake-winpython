"""Tests for odekake/settings.py. Writes settings.toml / settings.local.toml into a temporary folder and calls the functions."""

import os

import pytest
from conftest import write_text

from build_offline import OPTION_NAMES, SETTING_DEFAULTS, SETTING_TYPES, parse_arguments
from odekake import BuildError
from odekake.settings import get_effective_settings, read_settings_file


def new_config_dir(folder, settings_toml=None, local_toml=None) -> str:
    """Writes settings files into <folder>\\config. A file whose value is None is not created. Returns folder."""
    config = os.path.join(folder, "config")
    os.makedirs(config, exist_ok=True)
    if settings_toml is not None:
        write_text(os.path.join(config, "settings.toml"), settings_toml)
    if local_toml is not None:
        write_text(os.path.join(config, "settings.local.toml"), local_toml)
    return str(folder)


def effective(arguments, repo_root, config_path=None):
    return get_effective_settings(
        arguments,
        config_path,
        SETTING_TYPES,
        OPTION_NAMES,
        str(repo_root),
        SETTING_DEFAULTS,
    )


class TestGetEffectiveSettings:
    def test_returns_the_defaults_without_settings_files(self, tmp_path):
        cfg = effective({}, tmp_path)
        assert sorted(cfg) == sorted(SETTING_TYPES)
        assert cfg["python_version"] is None
        assert cfg["output_dir"] is None
        assert cfg["include_export_ignored"] is False
        assert cfg["prune_winpython"] is False
        assert cfg["groups"] == []
        assert cfg["installer"] == "uv"
        assert cfg["winpython_archive_format"] == "zip"
        assert cfg["source"] == "worktree"
        assert cfg["remote_ref"] == "origin/main"

    def test_source_arguments_override_remote_settings(self, tmp_path):
        root = new_config_dir(
            tmp_path, 'source = "remote"\nremote_ref = "upstream/main"'
        )
        _args, given = parse_arguments(
            ["--source", "worktree", "--remote-ref", "origin/master"]
        )
        cfg = effective(given, root)
        assert cfg["source"] == "worktree"
        assert cfg["remote_ref"] == "origin/master"
        assert effective({}, root)["source"] == "remote"

    @pytest.mark.parametrize("value", ["REMOTE", "local", ""])
    def test_rejects_invalid_source_arguments(self, value, tmp_path):
        with pytest.raises(BuildError, match="Setting 'source' must be one of"):
            effective({"source": value}, tmp_path)

    def test_rejects_invalid_source_and_remote_ref_settings(self, tmp_path):
        root = new_config_dir(tmp_path, 'source = "REMOTE"')
        with pytest.raises(BuildError, match="Setting 'source' must be one of"):
            effective({}, root)
        root = new_config_dir(tmp_path, "remote_ref = false")
        with pytest.raises(BuildError, match="Setting 'remote_ref' must be a string"):
            effective({}, root)

    def test_reads_config_settings_toml_without_config_path(self, tmp_path):
        root = new_config_dir(tmp_path, 'output_dir = "D:\\\\out"')
        assert effective({}, root)["output_dir"] == "D:\\out"

    def test_merges_key_by_key_with_priority(self, tmp_path):
        # argument > settings.local.toml > settings.toml > defaults
        root = new_config_dir(
            tmp_path,
            'output_dir = "from-settings"\nimport_name = "from_settings"\ngroups = ["s"]\nextras = ["s"]\ninclude_export_ignored = true',
            'output_dir = "from-local"\ngroups = ["l"]\nextras = ["l"]',
        )
        config_path = os.path.join(root, "config", "settings.toml")
        cfg = effective({"groups": ["arg"]}, "C:\\nowhere", config_path)
        assert cfg["groups"] == ["arg"]
        assert cfg["extras"] == ["l"]
        assert cfg["output_dir"] == "from-local"
        assert cfg["import_name"] == "from_settings"
        assert cfg["include_export_ignored"] is True
        assert cfg["no_popup"] is False

    def test_bool_arguments_override_the_settings_file_both_ways(self, tmp_path):
        root = new_config_dir(
            tmp_path, "include_export_ignored = false\nprune_winpython = true"
        )
        cfg = effective(
            {"include_export_ignored": True, "prune_winpython": False}, root
        )
        assert cfg["include_export_ignored"] is True
        assert cfg["prune_winpython"] is False

    def test_splits_comma_separated_array_arguments(self, tmp_path):
        cfg = effective({"groups": ["a,b"], "extras": [" x , y", "z", ","]}, tmp_path)
        assert cfg["groups"] == ["a", "b"]
        assert cfg["extras"] == ["x", "y", "z"]

    def test_does_not_override_with_the_python_version_argument(self, tmp_path):
        # Handled by project.get_python_minor
        root = new_config_dir(tmp_path, 'python_version = "3.12"')
        assert effective({"python_version": "3.14"}, root)["python_version"] == "3.12"

    def test_switches_installer_with_the_settings_file_and_the_argument(self, tmp_path):
        root = new_config_dir(tmp_path, 'installer = "pip"')
        assert effective({}, root)["installer"] == "pip"
        assert effective({"installer": "uv"}, root)["installer"] == "uv"

    @pytest.mark.parametrize("value", ["conda", "UV", ""])
    def test_fails_on_an_invalid_installer_argument(self, value, tmp_path):
        expected = (
            'Setting \'installer\' must be one of "uv" / "pip" (argument --installer)'
        )
        with pytest.raises(BuildError) as e:
            effective({"installer": value}, tmp_path)
        assert expected in str(e.value)

    def test_switches_winpython_archive_format_with_the_settings_file_and_the_argument(
        self, tmp_path
    ):
        root = new_config_dir(tmp_path, 'winpython_archive_format = "7z"')
        assert effective({}, root)["winpython_archive_format"] == "7z"
        assert (
            effective({"winpython_archive_format": "zip"}, root)[
                "winpython_archive_format"
            ]
            == "zip"
        )

    @pytest.mark.parametrize("value", ["tar", "7Z", ""])
    def test_fails_on_an_invalid_winpython_archive_format_argument(
        self, value, tmp_path
    ):
        expected = 'Setting \'winpython_archive_format\' must be one of "zip" / "7z" (argument --winpython-archive-format)'
        with pytest.raises(BuildError) as e:
            effective({"winpython_archive_format": value}, tmp_path)
        assert expected in str(e.value)

    def test_initial_dir_is_empty_by_default_and_can_be_set_in_settings_local_toml(
        self, tmp_path
    ):
        assert effective({}, tmp_path / "none")["initial_dir"] is None
        root = new_config_dir(
            tmp_path / "initialdir", None, 'initial_dir = "%USERPROFILE%\\\\repos"'
        )
        assert effective({}, root)["initial_dir"] == "%USERPROFILE%\\repos"

    def test_fails_when_the_config_path_file_does_not_exist(self, tmp_path):
        missing = str(tmp_path / "missing" / "settings.toml")
        with pytest.raises(BuildError) as e:
            effective({}, tmp_path, missing)
        assert (
            str(e.value)
            == f"Settings file specified by --config-path not found: {missing}"
        )


class TestReadSettingsFile:
    @staticmethod
    def read_toml(tmp_path, text):
        path = tmp_path / "settings.toml"
        write_text(path, text)
        return read_settings_file(str(path), SETTING_TYPES)

    def test_returns_nothing_when_the_file_does_not_exist(self, tmp_path):
        assert read_settings_file(str(tmp_path / "nothing.toml"), SETTING_TYPES) == {}

    def test_returns_nothing_for_an_empty_file(self, tmp_path):
        assert self.read_toml(tmp_path, "  \r\n") == {}

    def test_reads_a_file_with_a_bom(self, tmp_path):
        assert self.read_toml(tmp_path, "\ufeffno_popup = true") == {"no_popup": True}

    def test_reads_arrays_as_lists_of_strings(self, tmp_path):
        assert self.read_toml(tmp_path, 'exclude = ["docs/**", "tests"]')[
            "exclude"
        ] == ["docs/**", "tests"]

    def test_fails_on_an_unknown_key(self, tmp_path):
        with pytest.raises(BuildError, match="Unknown key 'foo'"):
            self.read_toml(tmp_path, "foo = 1")

    def test_fails_on_a_key_that_differs_only_in_case(self, tmp_path):
        with pytest.raises(BuildError, match="Unknown key 'Output_dir'"):
            self.read_toml(tmp_path, 'Output_dir = "x"')

    @pytest.mark.parametrize(
        ("text", "message"),
        [
            (
                'include_export_ignored = "yes"',
                "Setting 'include_export_ignored' must be true / false",
            ),
            (
                "include_export_ignored = 1",
                "Setting 'include_export_ignored' must be true / false",
            ),
            ('groups = "dev"', "Setting 'groups' must be an array of strings"),
            ("groups = [1]", "The items of setting 'groups' must be strings"),
            ("python_version = 3.13", "Setting 'python_version' must be a string"),
            (
                'installer = "conda"',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                'installer = "Pip"',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                'installer = ["uv"]',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                "installer = {}",
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                'winpython_archive_format = "ZIP"',
                'Setting \'winpython_archive_format\' must be one of "zip" / "7z"',
            ),
            (
                "winpython_archive_format = 7",
                'Setting \'winpython_archive_format\' must be one of "zip" / "7z"',
            ),
        ],
    )
    def test_fails_on_a_wrong_type(self, tmp_path, text, message):
        with pytest.raises(BuildError) as e:
            self.read_toml(tmp_path, text)
        assert message in str(e.value)

    def test_fails_when_the_file_cannot_be_read_as_toml(self, tmp_path):
        with pytest.raises(BuildError, match="Cannot read the settings file as TOML"):
            self.read_toml(tmp_path, '{ "groups": ')

    def test_rejects_an_unknown_table(self, tmp_path):
        with pytest.raises(BuildError, match="Unknown key 'a'"):
            self.read_toml(tmp_path, "[a]")

    def test_reads_comments_and_literal_windows_paths(self, tmp_path):
        text = "# Personal settings\ninitial_dir = '%USERPROFILE%\\repos'\noutput_dir = 'D:\\export' # Output folder\n"
        assert self.read_toml(tmp_path, text) == {
            "initial_dir": "%USERPROFILE%\\repos",
            "output_dir": "D:\\export",
        }

    @pytest.mark.parametrize(
        "text",
        ["groups = [", 'source = "remote"\nsource = "worktree"', "installer = null"],
    )
    def test_rejects_invalid_toml(self, tmp_path, text):
        with pytest.raises(BuildError, match="Cannot read the settings file as TOML"):
            self.read_toml(tmp_path, text)

    @pytest.mark.parametrize(
        "key",
        [
            "pythonVersion",
            "outputDir",
            "initialDir",
            "remoteRef",
            "pruneWinPython",
            "winPythonArchiveFormat",
            "noPopup",
            "virusScan",
            "includeExportIgnored",
            "importName",
        ],
    )
    def test_rejects_old_camel_case_keys(self, tmp_path, key):
        with pytest.raises(BuildError, match=f"Unknown key '{key}'"):
            self.read_toml(tmp_path, f'{key} = "old"')


class TestParseArguments:
    def test_returns_only_the_given_settings(self):
        args, given = parse_arguments(
            [
                "--project-root",
                "D:\\p",
                "--groups",
                "a",
                "b",
                "--groups",
                "c",
                "--no-prune-winpython",
            ]
        )
        assert args.project_root == "D:\\p"
        assert args.config_path is None
        assert given == {"groups": ["a", "b", "c"], "prune_winpython": False}

    def test_maps_every_option(self):
        args, given = parse_arguments(
            [
                "--config-path",
                "c.toml",
                "--python-version",
                "3.13",
                "--output-dir",
                "out",
                "--include-export-ignored",
                "--extras",
                "x",
                "--exclude",
                "docs/**",
                "tests",
                "--prune-winpython",
                "--import-name",
                "pkg",
                "--installer",
                "pip",
                "--winpython-archive-format",
                "7z",
                "--no-popup",
            ]
        )
        assert args.config_path == "c.toml"
        assert given == {
            "python_version": "3.13",
            "output_dir": "out",
            "include_export_ignored": True,
            "extras": ["x"],
            "exclude": ["docs/**", "tests"],
            "prune_winpython": True,
            "import_name": "pkg",
            "installer": "pip",
            "winpython_archive_format": "7z",
            "no_popup": True,
        }

    def test_every_setting_except_initial_dir_has_an_option(self):
        assert sorted(OPTION_NAMES) == sorted(
            k for k in SETTING_TYPES if k != "initial_dir"
        )


@pytest.mark.parametrize("option", ["--tracked-only", "--no-tracked-only"])
def test_rejects_removed_tracked_only_option(option):
    with pytest.raises(SystemExit):
        parse_arguments([option])


def test_rejects_removed_tracked_only_setting(tmp_path):
    root = new_config_dir(tmp_path, "trackedOnly = true")
    with pytest.raises(BuildError, match="Unknown key 'trackedOnly'"):
        effective({}, root)


def test_ignores_old_json_files_without_warnings(tmp_path, monkeypatch):
    root = new_config_dir(tmp_path, 'installer = "pip"')
    write_text(tmp_path / "config" / "settings.json", '{"installer": "invalid"}')
    write_text(tmp_path / "config" / "settings.local.json", "invalid JSON")
    messages = []
    monkeypatch.setattr(
        "odekake.settings.log.write_log", lambda message: messages.append(message)
    )
    assert effective({}, root)["installer"] == "pip"
    assert len(messages) == 1
    assert messages[0].endswith("settings.toml")


def test_rejects_json_given_by_config_path(tmp_path):
    path = tmp_path / "old.json"
    write_text(path, '{"installer": "pip"}')
    with pytest.raises(BuildError, match="Cannot read the settings file as TOML"):
        effective({}, tmp_path, str(path))


def test_loads_local_toml_next_to_custom_config(tmp_path):
    path = tmp_path / "custom.toml"
    write_text(path, 'installer = "pip"')
    write_text(tmp_path / "settings.local.toml", 'installer = "uv"')
    assert effective({}, tmp_path / "unused", str(path))["installer"] == "uv"
