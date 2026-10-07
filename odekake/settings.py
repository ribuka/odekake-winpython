"""Loading settings."""

import json
import os
from collections.abc import Mapping

from odekake import BuildError, log

# A setting type is 'string' / 'bool' / 'array', or a tuple of values (choice).
# A choice accepts only the values in it (case-sensitive), and its default is the first value.
SettingType = str | tuple[str, ...]


def resolve_full_path(path: str) -> str:
    """Resolves a path relative to the current folder."""
    return os.path.abspath(path)


def _assert_choice(key: str, value: object, choices: tuple[str, ...], source: str) -> None:
    """Validates a choice value. Case-sensitive (same as unknown keys)."""
    if not isinstance(value, str) or value not in choices:
        listed = ' / '.join(f'"{c}"' for c in choices)
        raise BuildError(f"Setting '{key}' must be one of {listed} ({source}): '{value}'")


def read_settings_file(path: str, setting_types: Mapping[str, SettingType]) -> dict[str, object]:
    """Reads a settings file, checks the types, and returns a dict. Empty if the file does not exist."""
    result: dict[str, object] = {}
    if not os.path.isfile(path):
        return result
    log.write_log(f'Settings file: {path}')
    with open(path, encoding='utf-8-sig') as f:
        text = f.read()
    if not text.strip():
        return result
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise BuildError(f'Cannot read the settings file as JSON: {path}\n{e}') from e
    if not isinstance(data, dict):
        raise BuildError(f'The top level of the settings file must be a {{ }} object: {path}')
    for key, value in data.items():
        if key not in setting_types:
            raise BuildError(f"Unknown key '{key}' in the settings file: {path}\nValid keys: {', '.join(setting_types)}")
        kind = setting_types[key]
        if isinstance(kind, tuple):
            _assert_choice(key, value, kind, path)
        elif kind == 'string':
            if not isinstance(value, str):
                raise BuildError(f"Setting '{key}' must be a string: {path}")
        elif kind == 'bool':
            if not isinstance(value, bool):
                raise BuildError(f"Setting '{key}' must be true / false: {path}")
        elif kind == 'array':
            if not isinstance(value, list):
                raise BuildError(f"Setting '{key}' must be an array of strings ([\"...\"]): {path}")
            if not all(isinstance(item, str) for item in value):
                raise BuildError(f"The items of setting '{key}' must be strings: {path}")
        result[key] = value
    return result


def _default(kind: SettingType) -> object:
    if isinstance(kind, tuple):
        return kind[0]
    return {'string': None, 'bool': False, 'array': []}[kind]


def get_effective_settings(
    arguments: Mapping[str, object],
    config_path: str | None,
    setting_types: Mapping[str, SettingType],
    option_names: Mapping[str, str],
    repo_root: str,
) -> dict[str, object]:
    """Overrides key by key in the order defaults < settings.json < settings.local.json < arguments.

    arguments holds only the arguments given on the command line, keyed by setting key.
    option_names maps a setting key to its argument name (used in error messages).
    Without config_path, reads <repo_root>\\config\\settings.json.
    """
    settings = {key: _default(kind) for key, kind in setting_types.items()}

    if config_path is not None:
        config_file = resolve_full_path(config_path)
        if not os.path.isfile(config_file):
            raise BuildError(f'Settings file specified by --config-path not found: {config_file}')
    else:
        config_file = os.path.join(repo_root, 'config', 'settings.json')
    local_file = os.path.join(os.path.dirname(config_file), 'settings.local.json')

    for file in (config_file, local_file):
        settings.update(read_settings_file(file, setting_types))

    for key, kind in setting_types.items():
        if key not in arguments:
            continue
        # pythonVersion has a priority relative to .python-version, so the argument does not override it here
        # (see project.get_python_minor)
        if key == 'pythonVersion':
            continue
        value = arguments[key]
        if isinstance(kind, tuple):
            _assert_choice(key, value, kind, f'argument {option_names[key]}')
        elif kind == 'bool':
            value = bool(value)
        elif kind == 'array':
            # Accept comma-separated values too (--groups a,b)
            value = [part.strip() for item in value for part in item.split(',') if part.strip()]
        settings[key] = value
    return settings
