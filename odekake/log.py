"""Logging (loguru) and running external commands."""

import os
import subprocess
import sys

from loguru import logger

from odekake import BuildError

# loguru color tags used by write_log(color=...)
_COLOR_TAGS = {
    "red": "red",
    "green": "green",
    "yellow": "yellow",
    "cyan": "cyan",
    "gray": "light-black",
}
_FILE_FORMAT = "{time:HH:mm:ss} {message}"

# The log file name needs <name>, so lines are buffered in memory until pyproject is read.
_buffer: list[str] = []
_buffer_sink_id: int | None = None
_path: str | None = None


def _console_format(record) -> str:
    # Only the format string is parsed for color tags, never the message itself
    tag = _COLOR_TAGS.get(record["extra"].get("color"))
    return f"<{tag}>{{message}}</{tag}>\n" if tag else "{message}\n"


def start() -> None:
    """Sets up loguru: the console (stderr) and the in-memory buffer that open_log_file writes to the log file."""
    global _buffer_sink_id
    logger.remove()
    # Colors only on a console. loguru's own detection colors redirected output too on Windows.
    logger.add(
        sys.stderr,
        format=_console_format,
        level="INFO",
        colorize=sys.stderr.isatty(),
    )
    _buffer_sink_id = logger.add(_buffer.append, format=_FILE_FORMAT, level="INFO")


def log_path() -> str | None:
    return _path


def write_log(message: str = "", color: str | None = None) -> None:
    logger.bind(color=color).info(message)


def write_step(message: str) -> None:
    write_log()
    write_log(f"== {message}", color="cyan")


def open_log_file(name: str | None, log_dir: str, timestamp: str) -> None:
    """Writes the buffered lines to <log_dir>\\<timestamp>_<name>.log and logs to that file from then on."""
    global _path, _buffer_sink_id
    os.makedirs(log_dir, exist_ok=True)
    file_name = f"{timestamp}_{name}.log" if name else f"{timestamp}.log"
    _path = os.path.join(log_dir, file_name)
    with open(_path, "a", encoding="utf-8") as f:
        f.writelines(_buffer)
    _buffer.clear()
    if _buffer_sink_id is not None:
        logger.remove(_buffer_sink_id)
        _buffer_sink_id = None
    logger.add(_path, format=_FILE_FORMAT, level="INFO", encoding="utf-8")


def run(
    file_path: str,
    args: list[str],
    capture: bool = False,
    input_text: str | None = None,
    env: dict[str, str] | None = None,
) -> str | None:
    """Runs an external command (without a shell) and writes stdout and stderr to the log.

    Raises BuildError if the exit code is not 0.
    With capture, returns stdout instead of logging it (stderr is still logged).
    input_text is passed to standard input.
    env is added to the current environment for this call only.
    """
    write_log(f"> {file_path} {' '.join(args)}", color="gray")
    command = [file_path, *args]
    child_env = {**os.environ, **env} if env else None
    # The output of uv, pip (PYTHONIOENCODING=utf-8), and git (core.quotepath=off) is UTF-8
    try:
        if capture:
            result = subprocess.run(
                command,
                input=input_text,
                capture_output=True,
                check=False,
                encoding="utf-8",
                errors="replace",
                env=child_env,
            )
            for line in result.stderr.splitlines():
                write_log(line)
            code = result.returncode
        else:
            with subprocess.Popen(
                command,
                stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                encoding="utf-8",
                errors="replace",
                env=child_env,
            ) as process:
                if input_text is not None:
                    process.stdin.write(input_text)
                    process.stdin.close()
                for line in process.stdout:
                    write_log(line.rstrip("\r\n"))
                code = process.wait()
    except OSError as e:
        raise BuildError(f"Cannot run the external command: {file_path}\n{e}") from e
    if code != 0:
        raise BuildError(
            f"External command failed (exit code {code}): {file_path} {' '.join(args)}"
        )
    return result.stdout if capture else None
