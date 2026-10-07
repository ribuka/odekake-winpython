"""Tests for odekake/settings.py. Writes settings.json / settings.local.json into a temporary folder and calls the functions."""

import os

import pytest
from conftest import write_text

from build_offline import OPTION_NAMES, SETTING_TYPES, parse_arguments
from odekake import BuildError
from odekake.settings import get_effective_settings, read_settings_file


def new_config_dir(folder, settings_json=None, local_json=None) -> str:
    """Writes settings files into <folder>\\config. A file whose value is None is not created. Returns folder."""
    config = os.path.join(folder, "config")
    os.makedirs(config, exist_ok=True)
    if settings_json is not None:
        write_text(os.path.join(config, "settings.json"), settings_json)
    if local_json is not None:
        write_text(os.path.join(config, "settings.local.json"), local_json)
    return str(folder)


def effective(arguments, repo_root, config_path=None):
    return get_effective_settings(
        arguments, config_path, SETTING_TYPES, OPTION_NAMES, str(repo_root)
    )


class TestGetEffectiveSettings:
    def test_returns_the_defaults_without_settings_files(self, tmp_path):
        cfg = effective({}, tmp_path)
        assert sorted(cfg) == sorted(SETTING_TYPES)
        assert cfg["pythonVersion"] is None
        assert cfg["outputDir"] is None
        assert cfg["trackedOnly"] is False
        assert cfg["pruneWinPython"] is False
        assert cfg["groups"] == []
        assert cfg["installer"] == "uv"
        assert cfg["winPythonArchiveFormat"] == "zip"

    def test_reads_config_settings_json_without_config_path(self, tmp_path):
        root = new_config_dir(tmp_path, '{ "outputDir": "D:\\\\out" }')
        assert effective({}, root)["outputDir"] == "D:\\out"

    def test_merges_key_by_key_with_priority(self, tmp_path):
        # argument > settings.local.json > settings.json > defaults
        root = new_config_dir(
            tmp_path,
            '{ "outputDir": "from-settings", "importName": "from_settings", "groups": ["s"], "extras": ["s"], '
            '"trackedOnly": true }',
            '{ "outputDir": "from-local", "groups": ["l"], "extras": ["l"] }',
        )
        config_path = os.path.join(root, "config", "settings.json")
        cfg = effective({"groups": ["arg"]}, "C:\\nowhere", config_path)
        assert cfg["groups"] == ["arg"]
        assert cfg["extras"] == ["l"]
        assert cfg["outputDir"] == "from-local"
        assert cfg["importName"] == "from_settings"
        assert cfg["trackedOnly"] is True
        assert cfg["noPopup"] is False

    def test_bool_arguments_override_the_settings_file_both_ways(self, tmp_path):
        root = new_config_dir(
            tmp_path, '{ "trackedOnly": false, "pruneWinPython": true }'
        )
        cfg = effective({"trackedOnly": True, "pruneWinPython": False}, root)
        assert cfg["trackedOnly"] is True
        assert cfg["pruneWinPython"] is False

    def test_splits_comma_separated_array_arguments(self, tmp_path):
        cfg = effective({"groups": ["a,b"], "extras": [" x , y", "z", ","]}, tmp_path)
        assert cfg["groups"] == ["a", "b"]
        assert cfg["extras"] == ["x", "y", "z"]

    def test_does_not_override_with_the_python_version_argument(self, tmp_path):
        # Handled by project.get_python_minor
        root = new_config_dir(tmp_path, '{ "pythonVersion": "3.12" }')
        assert effective({"pythonVersion": "3.14"}, root)["pythonVersion"] == "3.12"

    def test_switches_installer_with_the_settings_file_and_the_argument(self, tmp_path):
        root = new_config_dir(tmp_path, '{ "installer": "pip" }')
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
        root = new_config_dir(tmp_path, '{ "winPythonArchiveFormat": "7z" }')
        assert effective({}, root)["winPythonArchiveFormat"] == "7z"
        assert (
            effective({"winPythonArchiveFormat": "zip"}, root)["winPythonArchiveFormat"]
            == "zip"
        )

    @pytest.mark.parametrize("value", ["tar", "7Z", ""])
    def test_fails_on_an_invalid_winpython_archive_format_argument(
        self, value, tmp_path
    ):
        expected = 'Setting \'winPythonArchiveFormat\' must be one of "zip" / "7z" (argument --winpython-archive-format)'
        with pytest.raises(BuildError) as e:
            effective({"winPythonArchiveFormat": value}, tmp_path)
        assert expected in str(e.value)

    def test_initial_dir_is_empty_by_default_and_can_be_set_in_settings_local_json(
        self, tmp_path
    ):
        assert effective({}, tmp_path / "none")["initialDir"] is None
        root = new_config_dir(
            tmp_path / "initialdir", None, '{ "initialDir": "%USERPROFILE%\\\\repos" }'
        )
        assert effective({}, root)["initialDir"] == "%USERPROFILE%\\repos"

    def test_fails_when_the_config_path_file_does_not_exist(self, tmp_path):
        missing = str(tmp_path / "missing" / "settings.json")
        with pytest.raises(BuildError) as e:
            effective({}, tmp_path, missing)
        assert (
            str(e.value)
            == f"Settings file specified by --config-path not found: {missing}"
        )


class TestReadSettingsFile:
    @staticmethod
    def read_json(tmp_path, text):
        path = tmp_path / "settings.json"
        write_text(path, text)
        return read_settings_file(str(path), SETTING_TYPES)

    def test_returns_nothing_when_the_file_does_not_exist(self, tmp_path):
        assert read_settings_file(str(tmp_path / "nothing.json"), SETTING_TYPES) == {}

    def test_returns_nothing_for_an_empty_file(self, tmp_path):
        assert self.read_json(tmp_path, "  \r\n") == {}

    def test_reads_a_file_with_a_bom(self, tmp_path):
        assert self.read_json(tmp_path, '\ufeff{ "noPopup": true }') == {
            "noPopup": True
        }

    def test_reads_arrays_as_lists_of_strings(self, tmp_path):
        assert self.read_json(tmp_path, '{ "exclude": ["docs/**", "tests"] }')[
            "exclude"
        ] == ["docs/**", "tests"]

    def test_fails_on_an_unknown_key(self, tmp_path):
        with pytest.raises(BuildError, match="Unknown key 'foo'"):
            self.read_json(tmp_path, '{ "foo": 1 }')

    def test_fails_on_a_key_that_differs_only_in_case(self, tmp_path):
        with pytest.raises(BuildError, match="Unknown key 'outputdir'"):
            self.read_json(tmp_path, '{ "outputdir": "x" }')

    @pytest.mark.parametrize(
        ("text", "message"),
        [
            ('{ "trackedOnly": "yes" }', "Setting 'trackedOnly' must be true / false"),
            ('{ "trackedOnly": 1 }', "Setting 'trackedOnly' must be true / false"),
            ('{ "groups": "dev" }', "Setting 'groups' must be an array of strings"),
            ('{ "groups": [1] }', "The items of setting 'groups' must be strings"),
            ('{ "pythonVersion": 3.13 }', "Setting 'pythonVersion' must be a string"),
            (
                '{ "installer": "conda" }',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                '{ "installer": "Pip" }',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                '{ "installer": ["uv"] }',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                '{ "installer": null }',
                'Setting \'installer\' must be one of "uv" / "pip"',
            ),
            (
                '{ "winPythonArchiveFormat": "ZIP" }',
                'Setting \'winPythonArchiveFormat\' must be one of "zip" / "7z"',
            ),
            (
                '{ "winPythonArchiveFormat": 7 }',
                'Setting \'winPythonArchiveFormat\' must be one of "zip" / "7z"',
            ),
        ],
    )
    def test_fails_on_a_wrong_type(self, tmp_path, text, message):
        with pytest.raises(BuildError) as e:
            self.read_json(tmp_path, text)
        assert message in str(e.value)

    def test_fails_when_the_file_cannot_be_read_as_json(self, tmp_path):
        with pytest.raises(BuildError, match="Cannot read the settings file as JSON"):
            self.read_json(tmp_path, '{ "groups": ')

    def test_fails_when_the_top_level_is_not_an_object(self, tmp_path):
        with pytest.raises(
            BuildError,
            match=r"The top level of the settings file must be a \{ \} object",
        ):
            self.read_json(tmp_path, '["a"]')


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
        assert given == {"groups": ["a", "b", "c"], "pruneWinPython": False}

    def test_maps_every_option(self):
        args, given = parse_arguments(
            [
                "--config-path",
                "c.json",
                "--python-version",
                "3.13",
                "--output-dir",
                "out",
                "--tracked-only",
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
        assert args.config_path == "c.json"
        assert given == {
            "pythonVersion": "3.13",
            "outputDir": "out",
            "trackedOnly": True,
            "includeExportIgnored": True,
            "extras": ["x"],
            "exclude": ["docs/**", "tests"],
            "pruneWinPython": True,
            "importName": "pkg",
            "installer": "pip",
            "winPythonArchiveFormat": "7z",
            "noPopup": True,
        }

    def test_every_setting_except_initial_dir_has_an_option(self):
        assert sorted(OPTION_NAMES) == sorted(
            k for k in SETTING_TYPES if k != "initialDir"
        )
