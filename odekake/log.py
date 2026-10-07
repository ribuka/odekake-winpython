"""Logging and running external commands."""

import datetime
import os
import subprocess
import sys

from odekake import BuildError

# The log is a single state for the whole build, so it is kept at module level.
# The log file name needs <name>, so lines are buffered in memory until pyproject is read.
_buffer: list[str] = []
_path: str | None = None

_COLORS = {
    'red': '\x1b[91m',
    'green': '\x1b[92m',
    'yellow': '\x1b[93m',
    'cyan': '\x1b[96m',
    'gray': '\x1b[90m',
}
_RESET = '\x1b[0m'
_use_color: bool | None = None


def _color_enabled() -> bool:
    """Enables ANSI colors on the Windows console. Returns False when the output is not a console."""
    global _use_color
    if _use_color is None:
        _use_color = False
        if sys.stdout.isatty():
            try:
                import ctypes

                kernel32 = ctypes.windll.kernel32
                handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
                mode = ctypes.c_uint32()
                if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                    # ENABLE_VIRTUAL_TERMINAL_PROCESSING
                    _use_color = bool(kernel32.SetConsoleMode(handle, mode.value | 0x0004))
            except (AttributeError, OSError):
                pass
    return _use_color


def log_path() -> str | None:
    return _path


def write_log(message: str = '', color: str | None = None) -> None:
    if color and _color_enabled():
        print(f'{_COLORS[color]}{message}{_RESET}', flush=True)
    else:
        print(message, flush=True)
    line = f'{datetime.datetime.now():%H:%M:%S} {message}'
    if _path:
        with open(_path, 'a', encoding='utf-8', newline='') as f:
            f.write(line + '\r\n')
    else:
        _buffer.append(line)


def write_step(message: str) -> None:
    write_log()
    write_log(f'== {message}', color='cyan')


def open_log_file(name: str | None, log_dir: str, timestamp: str) -> None:
    """Writes the buffered lines to <log_dir>\\<timestamp>_<name>.log and appends to that file from then on."""
    global _path
    os.makedirs(log_dir, exist_ok=True)
    file_name = f'{timestamp}_{name}.log' if name else f'{timestamp}.log'
    _path = os.path.join(log_dir, file_name)
    with open(_path, 'a', encoding='utf-8', newline='') as f:
        for line in _buffer:
            f.write(line + '\r\n')
    _buffer.clear()


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
    input_text is passed to standard input. env is added to the current environment for this call only.
    """
    write_log(f'> {file_path} {" ".join(args)}', color='gray')
    command = [file_path, *args]
    child_env = {**os.environ, **env} if env else None
    # The output of uv, pip (PYTHONIOENCODING=utf-8), and git (core.quotepath=off) is UTF-8
    try:
        if capture:
            result = subprocess.run(
                command,
                input=input_text,
                capture_output=True,
                encoding='utf-8',
                errors='replace',
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
                encoding='utf-8',
                errors='replace',
                env=child_env,
            ) as process:
                if input_text is not None:
                    process.stdin.write(input_text)
                    process.stdin.close()
                for line in process.stdout:
                    write_log(line.rstrip('\r\n'))
                code = process.wait()
    except OSError as e:
        raise BuildError(f'Cannot run the external command: {file_path}\n{e}') from e
    if code != 0:
        raise BuildError(f'External command failed (exit code {code}): {file_path} {" ".join(args)}')
    return result.stdout if capture else None
