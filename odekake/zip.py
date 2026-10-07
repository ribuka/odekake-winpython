"""Creating ZIP and 7z files."""

import os
import zipfile
from typing import NamedTuple

from odekake import BuildError, log, remove_tree


class ZipEntry(NamedTuple):
    """An entry of new_zip_file. An entry whose source is None is an empty folder (name ends with /)."""

    name: str
    source: str | None
    store: bool = False


def new_zip_file(path: str, entries: list[ZipEntry]) -> None:
    """Creates a ZIP. Entry names always use / as the separator.

    Writes to .partial and then renames it, so that a failure does not leave a broken ZIP behind.
    """
    partial = path + ".partial"
    if os.path.exists(partial):
        os.remove(partial)
    # strict_timestamps=False: files dated before 1980 get 1980-01-01 instead of failing
    with zipfile.ZipFile(
        partial, "x", compression=zipfile.ZIP_DEFLATED, strict_timestamps=False
    ) as zf:
        for entry in entries:
            if entry.source is None:
                zf.mkdir(entry.name)
                continue
            compress_type = zipfile.ZIP_STORED if entry.store else zipfile.ZIP_DEFLATED
            zf.write(entry.source, entry.name, compress_type=compress_type)
    os.rename(partial, path)


def new_zip_from_directory(path: str, source_dir: str) -> None:
    """Zips the contents of a folder without the folder itself (empty folders included)."""
    entries = []
    for current, dirs, files in os.walk(source_dir):
        dirs.sort()
        rel_dir = os.path.relpath(current, source_dir).replace("\\", "/")
        prefix = "" if rel_dir == "." else rel_dir + "/"
        if prefix and not dirs and not files:
            entries.append(ZipEntry(prefix, None))
        for name in sorted(files):
            entries.append(ZipEntry(prefix + name, os.path.join(current, name)))
    new_zip_file(path, entries)


def get_system_tar_path() -> str:
    """7z files are created with the tar.exe that comes with Windows (bsdtar / libarchive) (spec §16).

    The tar on PATH may be GNU tar from Git for Windows, which cannot write 7z, so the one in System32 is used.
    """
    return os.path.join(
        os.environ.get("SystemRoot", r"C:\Windows"), "System32", "tar.exe"
    )


def new_seven_zip_from_directory(path: str, source_dir: str, tar: str) -> None:
    """Packs the contents of a folder into a 7z (LZMA2) without the folder itself (empty folders included).

    Passing . to tar makes entry names start with ./, so the top-level items are passed by name.
    """
    names = sorted(os.listdir(source_dir))
    if not names:
        raise BuildError(f"The folder to pack into 7z is empty: {source_dir}")
    partial = path + ".partial"
    if os.path.exists(partial):
        os.remove(partial)
    log.run(
        tar,
        [
            "-C",
            source_dir,
            "--format",
            "7zip",
            "--options",
            "7zip:compression=lzma2",
            "-cf",
            partial,
            *names,
        ],
    )
    os.rename(partial, path)


def assert_seven_zip_writable(tar: str, work_dir: str) -> None:
    """Checks that tar.exe can create 7z by creating a small test 7z. Raises BuildError if it cannot.

    tar.exe on older Windows may not be able to write 7z (LZMA2) (unverified), so this is checked before downloading WinPython.
    """
    if not os.path.isfile(tar):
        raise BuildError(
            f"tar.exe, needed to create 7z, not found: {tar}\nSet winPythonArchiveFormat to zip."
        )
    probe_dir = os.path.join(work_dir, "7z-probe")
    probe_7z = os.path.join(work_dir, "7z-probe.7z")
    os.makedirs(probe_dir, exist_ok=True)
    try:
        with open(os.path.join(probe_dir, "probe.txt"), "w", encoding="utf-8") as f:
            f.write("probe")
        try:
            new_seven_zip_from_directory(probe_7z, probe_dir, tar)
        except BuildError as e:
            raise BuildError(
                f"tar.exe on this PC cannot create 7z. Set winPythonArchiveFormat to zip.\n{e}"
            ) from e
    finally:
        remove_tree(probe_dir)
        for p in (probe_7z, probe_7z + ".partial"):
            if os.path.exists(p):
                os.remove(p)
