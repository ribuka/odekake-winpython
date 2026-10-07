import os

import pytest

from odekake import log


@pytest.fixture(autouse=True)
def logs(monkeypatch):
    """Replaces log.write_log and returns the list of logged messages. Nothing is printed or written to a file."""
    messages: list[str] = []
    monkeypatch.setattr(log, 'write_log', lambda message='', color=None: messages.append(message))
    return messages


def write_text(path, text: str) -> None:
    """Writes UTF-8 text (no BOM, newlines as they are), creating the parent folders."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
