"""Downloading and extracting WinPython."""

import hashlib
import os
import shutil
import time
import urllib.parse
import urllib.request
import zipfile

from odekake import BuildError, log


def get_sha256(path: str) -> str:
    """Returns the SHA-256 of a file in upper-case hex (same as Get-FileHash)."""
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest().upper()


def get_winpython_archive(entry: dict, build_dir: str) -> str:
    """Returns the WinPython zip cached in <build_dir>\\downloads. Downloads it again if the hash does not match.

    entry is {'url': ..., 'sha256': ...}.
    """
    download_dir = os.path.join(build_dir, 'downloads')
    os.makedirs(download_dir, exist_ok=True)
    file_name = os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(entry['url']).path))
    path = os.path.join(download_dir, file_name)
    expected = entry['sha256'].upper()

    if os.path.isfile(path):
        if get_sha256(path) == expected:
            log.write_log(f'Using the cache: {path}')
            return path
        log.write_log(f'The SHA-256 of the cache does not match. Downloading again: {path}', color='yellow')
        os.remove(path)

    log.write_log(f"Downloading: {entry['url']}")
    log.write_log(f'Saving to: {path}')
    partial = path + '.partial'
    if os.path.exists(partial):
        os.remove(partial)
    with urllib.request.urlopen(entry['url']) as response, open(partial, 'wb') as f:
        shutil.copyfileobj(response, f, 1024 * 1024)
    actual = get_sha256(partial)
    if actual != expected:
        os.remove(partial)
        raise BuildError(f'The SHA-256 of the downloaded WinPython does not match.\nExpected: {expected}\nActual: {actual}')
    os.rename(partial, path)
    return path


def expand_winpython(archive: str, destination: str, work_dir: str) -> None:
    """Extracts WinPython into <work_dir>\\extract, strips the top-level folder (WPy64-xxxx), and places it at destination."""
    extract_dir = os.path.join(work_dir, 'extract')
    log.write_log(f'Extracting: {archive}')
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(extract_dir)
        # zipfile does not restore the modification times, so set them from the entries
        for info in zf.infolist():
            if not info.is_dir():
                mtime = time.mktime((*info.date_time, 0, 0, -1))
                os.utime(os.path.join(extract_dir, info.filename), (mtime, mtime))
    top = os.listdir(extract_dir)
    if len(top) != 1 or not os.path.isdir(os.path.join(extract_dir, top[0])):
        raise BuildError(f'The top level of the WinPython zip is not a single folder: {archive}')
    log.write_log(f'Stripping the top-level folder {top[0]} and placing it at winpython\\')
    shutil.move(os.path.join(extract_dir, top[0]), destination)
    os.rmdir(extract_dir)
