"""Implementation modules of odekake-winpython. Used by build_offline.py; not meant to be run on their own."""

import os
import shutil
import stat
import sys


class BuildError(Exception):
    """An error that stops the build. The message is shown to the user as it is."""


def remove_tree(path: str) -> None:
    """Removes a folder and its contents, including read-only files."""

    def clear_readonly_and_retry(func, failed_path, _exc):
        os.chmod(failed_path, stat.S_IWRITE)
        func(failed_path)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=clear_readonly_and_retry)
    else:
        shutil.rmtree(path, onerror=clear_readonly_and_retry)
