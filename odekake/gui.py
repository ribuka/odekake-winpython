"""GUI (folder selection dialog and popups) and the default output folder."""

import ctypes
import os
import re
import uuid

from odekake import BuildError, log


def _expand_environment_variables(value: str) -> str:
    """Expands %NAME% like Windows does. Undefined variables are left as they are ($NAME is not expanded)."""
    return re.sub(r"%([^%]+)%", lambda m: os.environ.get(m.group(1), m.group(0)), value)


def resolve_initial_dir(value: str | None) -> str | None:
    """Turns the initialDir setting into the path where the folder selection dialog starts (spec §8).

    Returns None if not set (empty). Environment variables (such as %USERPROFILE%) are expanded.
    A relative path is an error (when started from the .bat, its base is unclear).
    If the folder does not exist, warns and returns None.
    """
    if not value:
        return None
    path = _expand_environment_variables(value)
    if not re.match(r"^([A-Za-z]:[\\/]|\\\\)", path):
        raise BuildError(
            f"Setting 'initialDir' must be an absolute path (C:\\... or \\\\server\\...): '{value}'"
        )
    if not os.path.isdir(path):
        log.write_log(
            f"The folder in setting 'initialDir' does not exist, so the dialog opens without a start folder: {path}",
            color="yellow",
        )
        return None
    return os.path.abspath(path)


def select_project_folder(initial_dir: str | None) -> str | None:
    """Shows the folder selection dialog. Returns None if cancelled. If initial_dir is given, the dialog opens there."""
    try:
        import tkinter
        from tkinter import filedialog
    except ImportError as e:
        raise BuildError(
            "tkinter is not available in this Python, so the folder selection dialog cannot be shown. "
            "Specify the folder with --project-root."
        ) from e
    # A hidden topmost window is the owner, so that the dialog does not hide behind the console
    root = tkinter.Tk()
    try:
        root.withdraw()
        root.attributes("-topmost", True)
        root.update()
        selected = filedialog.askdirectory(
            parent=root,
            title="Select the folder of the uv project to pack (the folder that contains pyproject.toml)",
            initialdir=initial_dir or None,
            mustexist=True,
        )
    finally:
        root.destroy()
    return os.path.normpath(selected) if selected else None


_MB_OK = 0x0
_MB_ICONERROR = 0x10
_MB_ICONINFORMATION = 0x40
_MB_SETFOREGROUND = 0x10000
_MB_TOPMOST = 0x40000


def show_popup(text: str, is_error: bool) -> None:
    try:
        icon = _MB_ICONERROR if is_error else _MB_ICONINFORMATION
        title = "odekake-winpython: Failed" if is_error else "odekake-winpython: Done"
        ctypes.windll.user32.MessageBoxW(
            None, text, title, _MB_OK | icon | _MB_SETFOREGROUND | _MB_TOPMOST
        )
    except (AttributeError, OSError) as e:
        log.write_log(f"Could not show the popup: {e}", color="yellow")


class _GUID(ctypes.Structure):
    _fields_ = [
        ("Data1", ctypes.c_uint32),
        ("Data2", ctypes.c_uint16),
        ("Data3", ctypes.c_uint16),
        ("Data4", ctypes.c_ubyte * 8),
    ]


_FOLDERID_DOWNLOADS = uuid.UUID("374DE290-123F-4565-9164-39C4925E467B")


def get_downloads_folder() -> str:
    """Returns the Downloads known folder (follows the user's relocation of the folder)."""
    guid = _GUID.from_buffer_copy(_FOLDERID_DOWNLOADS.bytes_le)
    path_ptr = ctypes.c_void_p()
    shell32 = ctypes.windll.shell32
    shell32.SHGetKnownFolderPath.argtypes = [
        ctypes.POINTER(_GUID),
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    shell32.SHGetKnownFolderPath.restype = ctypes.c_long
    hr = shell32.SHGetKnownFolderPath(
        ctypes.byref(guid), 0, None, ctypes.byref(path_ptr)
    )
    try:
        if hr != 0:
            raise OSError(
                f"SHGetKnownFolderPath failed (HRESULT 0x{hr & 0xFFFFFFFF:08X})"
            )
        return ctypes.wstring_at(path_ptr.value)
    finally:
        ctypes.windll.ole32.CoTaskMemFree(path_ptr)
