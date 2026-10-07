"""Tests for odekake/log.py. External commands are run with the Python running the tests."""

import re
import sys

import pytest
from loguru import logger

from odekake import BuildError, log

# conftest replaces log.write_log in every test, so keep the real one here
real_write_log = log.write_log


@pytest.fixture
def fresh_log(monkeypatch):
    """Resets the log state and removes the loguru handlers afterwards.

    Tests call log.start() themselves: pytest swaps sys.stderr between the setup and call phases,
    so the console handler must be added during the call to write to the captured stderr.
    """
    monkeypatch.setattr(log, "_path", None)
    monkeypatch.setattr(log, "_buffer", [])
    yield
    logger.remove()


def test_buffers_lines_until_the_log_file_is_opened_and_then_appends_to_it(
    fresh_log, tmp_path, capsys
):
    log.start()
    real_write_log("before")
    real_write_log("red {braces} <tags>", color="red")
    assert log.log_path() is None
    log.open_log_file("my-project", str(tmp_path / "logs"), "20261007T120000")
    real_write_log("after")
    logger.remove()  # closes the file

    path = tmp_path / "logs" / "20261007T120000_my-project.log"
    assert log.log_path() == str(path)
    lines = path.read_text(encoding="utf-8").splitlines()
    assert [re.sub(r"^\d\d:\d\d:\d\d ", "", line) for line in lines] == [
        "before",
        "red {braces} <tags>",
        "after",
    ]
    assert all(re.match(r"^\d\d:\d\d:\d\d ", line) for line in lines)
    assert capsys.readouterr().err.splitlines() == [
        "before",
        "red {braces} <tags>",
        "after",
    ]


def test_names_the_log_file_with_the_timestamp_only_without_a_name(fresh_log, tmp_path):
    log.start()
    log.open_log_file(None, str(tmp_path), "20261007T120000")
    assert log.log_path() == str(tmp_path / "20261007T120000.log")


class TestRun:
    def test_logs_the_command_line_and_the_output(self, logs):
        log.run(
            sys.executable,
            ["-c", "import sys; print('out'); print('err', file=sys.stderr)"],
        )
        assert logs[0].startswith(f"> {sys.executable} -c ")
        assert sorted(logs[1:]) == ["err", "out"]

    def test_returns_stdout_with_capture_and_logs_only_stderr(self, logs):
        out = log.run(
            sys.executable,
            ["-c", "import sys; print('out'); print('err', file=sys.stderr)"],
            capture=True,
        )
        assert out.splitlines() == ["out"]
        assert logs[1:] == ["err"]

    def test_passes_input_and_environment_variables(self):
        code = (
            "import os, sys; print(sys.stdin.read() + os.environ['ODEKAKE_TEST_VALUE'])"
        )
        env = {"ODEKAKE_TEST_VALUE": "!", "PYTHONIOENCODING": "utf-8"}
        out = log.run(
            sys.executable, ["-c", code], capture=True, input_text="日本語\0", env=env
        )
        assert out.rstrip("\r\n") == "日本語\0!"

    def test_fails_on_a_non_zero_exit_code(self):
        with pytest.raises(
            BuildError, match=r"^External command failed \(exit code 3\): "
        ):
            log.run(sys.executable, ["-c", "raise SystemExit(3)"])

    def test_fails_when_the_command_cannot_be_run(self, tmp_path):
        with pytest.raises(BuildError, match="^Cannot run the external command: "):
            log.run(str(tmp_path / "no-such-command"), [])
