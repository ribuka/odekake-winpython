"""Packs a uv project into a ZIP bundled with WinPython, for use on offline machines.

See docs/spec.md for the specification.
Settings priority: arguments > config\\settings.local.json > config\\settings.json > defaults

Example:
    build-offline.bat --project-root D:\\work\\foo --groups gui --exclude "docs/**" tests
"""

import argparse
import datetime
import os
import shutil
import sys
import traceback

from odekake import BuildError, gui, log, project, remove_tree, settings, winpython
from odekake import zip as ziputil

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# WinPython dot editions. Each row pins one release (spec §5). Keep the full URL instead of building it from a pattern.
WINPYTHON_TABLE = {
    "3.12": {  # released 2025-03 (the last stable release that has 3.12)
        "url": "https://github.com/winpython/winpython/releases/download/16.6.20250620final/Winpython64-3.12.10.1dot.zip",
        "sha256": "7a1f004aec39615977b2b245423a50115530d16af3418df77977186a555d0a40",
    },
    "3.13": {  # released 2026-03
        "url": "https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.13.15.0dot.zip",
        "sha256": "28e36408f0140c50b207ea059a599c664564e68a3cbb835f03a71f4601efd8f1",
    },
    "3.14": {  # released 2026-03
        "url": "https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.14.7.0dot.zip",
        "sha256": "dbabedfb50eeb3c2c63dc43c9cb6239eae4a582c3bfd9a5f2ffd00a09b49a527",
    },
}

# Top-level WinPython items removed by pruneWinPython (spec §8)
PRUNE_TARGETS = [
    "Jupyter Lab.exe",
    "Jupyter Notebook.exe",
    "Spyder.exe",
    "Spyder reset.exe",
    "VS Code.exe",
    "notebooks",
    "wheelhouse",
]

# Setting keys and their types (see settings.SettingType), and the argument name of each key.
# initialDir is for settings files only and has no argument (use --project-root to specify the folder by argument).
SETTING_TYPES: dict[str, settings.SettingType] = {
    "pythonVersion": "string",
    "outputDir": "string",
    "trackedOnly": "bool",
    "includeExportIgnored": "bool",
    "groups": "array",
    "extras": "array",
    "exclude": "array",
    "pruneWinPython": "bool",
    "importName": "string",
    "installer": ("uv", "pip"),
    "winPythonArchiveFormat": ("zip", "7z"),
    "noPopup": "bool",
    "initialDir": "string",
}
OPTION_NAMES = {
    "pythonVersion": "--python-version",
    "outputDir": "--output-dir",
    "trackedOnly": "--tracked-only",
    "includeExportIgnored": "--include-export-ignored",
    "groups": "--groups",
    "extras": "--extras",
    "exclude": "--exclude",
    "pruneWinPython": "--prune-winpython",
    "importName": "--import-name",
    "installer": "--installer",
    "winPythonArchiveFormat": "--winpython-archive-format",
    "noPopup": "--no-popup",
}

# The index that pip mode can install from (the registry in uv.lock). Dependencies from any other index are an error.
PYPI_INDEX_URL = "https://pypi.org/simple"

PTH_FILE_NAME = "odekake-src.pth"
PTH_CONTENT = "..\\..\\..\\..\\src"

# Environment variables that affect child processes (uv, pip, python). None removes the variable.
ENV_OVERRIDES = {
    "PYTHONPATH": None,
    "PYTHONHOME": None,
    "PYTHONSTARTUP": None,
    "VIRTUAL_ENV": None,
    "PYTHONNOUSERSITE": "1",
    "PYTHONIOENCODING": "utf-8",
    "PYTHONUTF8": "1",
}

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD_DIR = os.path.join(REPO_ROOT, ".build")
WORK_DIR = os.path.join(BUILD_DIR, "work")
LOG_DIR = os.path.join(REPO_ROOT, "logs")


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------


def parse_arguments(argv: list[str]) -> tuple[argparse.Namespace, dict[str, object]]:
    """Returns the parsed arguments and, keyed by setting key, the settings given as arguments."""
    parser = argparse.ArgumentParser(
        prog="build-offline",
        allow_abbrev=False,
        description="Packs a uv project into a ZIP bundled with WinPython, for use on offline machines. "
        "Settings priority: arguments > config\\settings.local.json > config\\settings.json > defaults",
    )
    parser.add_argument(
        "--project-root",
        help="the uv project to pack (default: show a folder selection dialog)",
    )
    parser.add_argument(
        "--config-path", help="settings file (default: config\\settings.json)"
    )
    help_texts = {
        "pythonVersion": "Python version such as 3.13 (takes priority over .python-version)",
        "outputDir": "existing folder to write the ZIP to (default: the Downloads folder)",
        "trackedOnly": "include only the files added to git",
        "includeExportIgnored": "include the files marked export-ignore in .gitattributes",
        "groups": "dependency groups to include (dev is not included by default)",
        "extras": "extras to include",
        "exclude": "git pathspec (glob) patterns of the files to leave out of the ZIP",
        "pruneWinPython": "remove unneeded WinPython launchers and folders",
        "importName": "package to import in the check (default: name in pyproject.toml)",
        "installer": "how to install the dependencies",
        "winPythonArchiveFormat": "archive format of WinPython in the ZIP",
        "noPopup": "do not show the popup at the end",
    }
    for key, kind in SETTING_TYPES.items():
        option = OPTION_NAMES.get(key)
        if option is None:
            continue
        if key == "noPopup":
            parser.add_argument(
                option, dest=key, action="store_const", const=True, help=help_texts[key]
            )
        elif kind == "bool":
            parser.add_argument(
                option,
                dest=key,
                action=argparse.BooleanOptionalAction,
                help=help_texts[key],
            )
        elif kind == "array":
            parser.add_argument(
                option,
                dest=key,
                action="extend",
                nargs="+",
                metavar="VALUE",
                help=help_texts[key],
            )
        else:
            # Choices are validated by settings.get_effective_settings, with the same message as the settings file
            metavar = "{" + ",".join(kind) + "}" if isinstance(kind, tuple) else "VALUE"
            parser.add_argument(option, dest=key, metavar=metavar, help=help_texts[key])
    args = parser.parse_args(argv)
    given = {
        key: getattr(args, key)
        for key in OPTION_NAMES
        if getattr(args, key) is not None
    }
    return args, given


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


class Build:
    def __init__(self, args: argparse.Namespace, given: dict[str, object]):
        self.args = args
        self.given = given
        self.start_time = datetime.datetime.now().astimezone()
        self.timestamp = self.start_time.strftime("%Y%m%dT%H%M%S")
        self.no_popup = bool(given.get("noPopup"))
        self.cancelled = False
        self.result_text: str | None = None

    def run(self) -> None:
        log.write_log(
            f"odekake-winpython build started: {self.start_time:%Y-%m-%d %H:%M:%S}"
        )
        log.write_log(f"Python {sys.version.split()[0]} ({sys.executable})")

        # --- Settings and target project ---
        cfg = settings.get_effective_settings(
            self.given, self.args.config_path, SETTING_TYPES, OPTION_NAMES, REPO_ROOT
        )
        self.no_popup = cfg["noPopup"]

        if self.args.project_root is not None:
            root = settings.resolve_full_path(self.args.project_root)
        else:
            selected = gui.select_project_folder(
                gui.resolve_initial_dir(cfg["initialDir"])
            )
            if not selected:
                print("No folder was selected. Exiting without doing anything.")
                self.cancelled = True
                return
            root = selected
        log.write_log(f"Target project: {root}")
        if not os.path.isdir(root):
            raise BuildError(f"Target project folder not found: {root}")
        for required in ("pyproject.toml", "uv.lock"):
            if not os.path.isfile(os.path.join(root, required)):
                raise BuildError(f"{required} not found in the target project: {root}")

        for tool in ("git", "uv"):
            if not shutil.which(tool):
                raise BuildError(f"{tool} not found. Install it and add it to PATH.")
        try:
            inside_git = (
                log.run(
                    "git",
                    ["-C", root, "rev-parse", "--is-inside-work-tree"],
                    capture=True,
                ).strip()
                == "true"
            )
        except BuildError:
            inside_git = False
        if not inside_git:
            raise BuildError(
                "The target project is not a git repository "
                f"(required because .gitignore decides which files go into the ZIP): {root}"
            )

        # --- Name and version ---
        py = project.read_pyproject(os.path.join(root, "pyproject.toml"))
        if not py["name"]:
            raise BuildError("pyproject.toml has no name in [project].")
        name = py["name"].replace("_", "-")
        log.open_log_file(name, LOG_DIR, self.timestamp)
        version = project.get_project_version(root, py)
        import_name = cfg["importName"] or py["name"].replace("-", "_")
        log.write_log(
            f"name: {name} / version: {version} / import check: {import_name}"
        )

        minor = project.get_python_minor(
            root, self.given.get("pythonVersion"), cfg["pythonVersion"]
        )
        if minor not in WINPYTHON_TABLE:
            raise BuildError(
                f"No WinPython is registered for Python {minor}. Supported: {', '.join(sorted(WINPYTHON_TABLE))}"
            )
        winpython_entry = WINPYTHON_TABLE[minor]

        out_dir = (
            settings.resolve_full_path(cfg["outputDir"])
            if cfg["outputDir"]
            else gui.get_downloads_folder()
        )
        if not os.path.isdir(out_dir):
            raise BuildError(f"Output folder not found: {out_dir}")
        zip_path = os.path.join(out_dir, f"{name}-{version}_{self.timestamp}.zip")
        log.write_log(f"Output: {zip_path}")
        log.write_log(
            f"groups: [{', '.join(cfg['groups'])}] / extras: [{', '.join(cfg['extras'])}] / "
            f"exclude: [{', '.join(cfg['exclude'])}] / trackedOnly: {cfg['trackedOnly']} / "
            f"includeExportIgnored: {cfg['includeExportIgnored']} / pruneWinPython: {cfg['pruneWinPython']} / "
            f"installer: {cfg['installer']} / winPythonArchiveFormat: {cfg['winPythonArchiveFormat']}"
        )
        log.write_log(
            f"uv: {' '.join(log.run('uv', ['--version'], capture=True).split())}"
        )

        # --- Work folder ---
        if os.path.exists(WORK_DIR):
            log.write_log(f"Removing the previous work folder: {WORK_DIR}")
            remove_tree(WORK_DIR)
        stage_dir = os.path.join(WORK_DIR, "stage")
        os.makedirs(stage_dir)

        # If this PC cannot create 7z, stop before downloading WinPython (no fallback to zip; spec §16)
        tar = ziputil.get_system_tar_path()
        if cfg["winPythonArchiveFormat"] == "7z":
            ziputil.assert_seven_zip_writable(tar, WORK_DIR)
            log.write_log(
                f"tar: {' '.join(log.run(tar, ['--version'], capture=True).split())}"
            )

        # --- Export dependencies ---
        # Done in uv mode too: to catch lock problems before downloading WinPython, and to log the dependencies to install.
        log.write_step("Exporting dependencies (uv export)")
        requirements = os.path.join(WORK_DIR, "requirements.txt")
        select_args = ["--no-default-groups"]
        for g in cfg["groups"]:
            select_args += ["--group", g]
        for e in cfg["extras"]:
            select_args += ["--extra", e]
        log.run(
            "uv",
            [
                "export",
                "--project",
                root,
                "--frozen",
                "--no-emit-project",
                *select_args,
                "--format",
                "requirements-txt",
                "--output-file",
                requirements,
                "--quiet",
            ],
        )
        with open(requirements, encoding="utf-8") as f:
            for line in f.read().splitlines():
                # Skip the hash lines because they are long
                if not line.strip() or line.lstrip().startswith(("#", "--hash")):
                    continue
                log.write_log("  " + line.rstrip(" \\"))

        if cfg["installer"] == "pip":
            non_pypi = project.get_non_pypi_requirements(
                os.path.join(root, "uv.lock"), requirements, PYPI_INDEX_URL
            )
            if non_pypi:
                raise BuildError(
                    "Some dependencies come from an index other than PyPI, which installer pip cannot install. "
                    "Set installer to uv:\n" + "\n".join(f"  {r}" for r in non_pypi)
                )

        # --- WinPython ---
        log.write_step(f"Preparing WinPython (Python {minor})")
        archive = winpython.get_winpython_archive(winpython_entry, BUILD_DIR)
        wp_dir = os.path.join(stage_dir, "winpython")
        winpython.expand_winpython(archive, wp_dir, WORK_DIR)
        python = os.path.join(wp_dir, "python", "python.exe")
        if not os.path.isfile(python):
            raise BuildError(f"python\\python.exe not found in WinPython: {python}")

        # --- Target project files ---
        log.write_step("Collecting the target project files")
        files = project.get_project_files(
            root, cfg["trackedOnly"], cfg["exclude"], cfg["includeExportIgnored"]
        )
        for rel in files:
            dst = os.path.join(stage_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(root, rel), dst)
            log.write_log(f"  {rel}")
        log.write_log(f"{len(files)} files")

        # --- Install dependencies ---
        if cfg["installer"] == "uv":
            # uv sync into WinPython's python folder as the project environment.
            # --inexact: keep packages not in the lock (pip, wppm, etc. bundled with WinPython).
            # --link-mode copy: no hard links to the uv cache.
            # --no-editable: path dependencies must not refer to paths on the build machine.
            log.write_step("Installing dependencies (uv sync)")
            log.run(
                "uv",
                [
                    "sync",
                    "--project",
                    root,
                    "--frozen",
                    "--inexact",
                    "--no-install-project",
                    *select_args,
                    "--python",
                    python,
                    "--link-mode",
                    "copy",
                    "--no-editable",
                ],
                env={"UV_PROJECT_ENVIRONMENT": os.path.join(wp_dir, "python")},
            )
        else:
            log.write_step("Installing dependencies (pip install)")
            log.run(
                python,
                [
                    "-X",
                    "utf8",
                    "-m",
                    "pip",
                    "install",
                    "--disable-pip-version-check",
                    "--no-warn-script-location",
                    "-r",
                    requirements,
                ],
            )

        pth_path = os.path.join(wp_dir, "python", "Lib", "site-packages", PTH_FILE_NAME)
        with open(pth_path, "w", encoding="utf-8", newline="") as f:
            f.write(PTH_CONTENT + "\r\n")
        log.write_log(f"Created {PTH_FILE_NAME}: {PTH_CONTENT}")

        # --- Verification ---
        log.write_step("Verifying")
        log.run(python, ["--version"])
        log.run(
            python, ["-X", "utf8", "-m", "pip", "check", "--disable-pip-version-check"]
        )
        # -I: keep the current folder out of sys.path, to make sure the import works through the .pth file.
        log.run(
            python,
            [
                "-I",
                "-X",
                "utf8",
                "-c",
                f"import {import_name}; print('import OK:', {import_name}.__file__)",
            ],
        )

        # --- Prune ---
        if cfg["pruneWinPython"]:
            log.write_step("Removing unneeded WinPython launchers and folders")
            for target in PRUNE_TARGETS:
                path = os.path.join(wp_dir, target)
                if os.path.isdir(path):
                    remove_tree(path)
                    log.write_log(f"  Removed: {target}")
                elif os.path.exists(path):
                    os.remove(path)
                    log.write_log(f"  Removed: {target}")
                else:
                    log.write_log(f"  (not found): {target}")

        # --- ZIP ---
        log.write_step("Creating the ZIP")
        archive_name = f"winpython.{cfg['winPythonArchiveFormat']}"
        winpython_archive = os.path.join(WORK_DIR, archive_name)
        log.write_log(f"Creating {archive_name}...")
        if cfg["winPythonArchiveFormat"] == "7z":
            ziputil.new_seven_zip_from_directory(winpython_archive, wp_dir, tar)
        else:
            ziputil.new_zip_from_directory(winpython_archive, wp_dir)
        log.write_log(
            f"{archive_name}: {os.path.getsize(winpython_archive) / 2**20:,.1f} MB"
        )
        log.write_log("Creating the outer ZIP...")
        # winpython.zip / winpython.7z is already compressed, so the outer ZIP stores it without compression
        outer_entries = [ziputil.ZipEntry(archive_name, winpython_archive, store=True)]
        outer_entries += [
            ziputil.ZipEntry(rel, os.path.join(stage_dir, rel)) for rel in files
        ]
        ziputil.new_zip_file(zip_path, outer_entries)

        sha256 = winpython.get_sha256(zip_path)
        size = os.path.getsize(zip_path)

        log.write_step("Cleaning up")
        remove_tree(WORK_DIR)
        log.write_log(f"Removed the work folder: {WORK_DIR}")

        elapsed = int(
            (datetime.datetime.now().astimezone() - self.start_time).total_seconds()
        )
        log.write_log()
        log.write_log("Done.", color="green")
        log.write_log(f"Output: {zip_path}", color="green")
        log.write_log(f"Size: {size:,} bytes ({size / 2**20:,.1f} MB)", color="green")
        log.write_log(f"SHA-256: {sha256}", color="green")
        log.write_log(f"Elapsed: {elapsed // 60 % 60:02}:{elapsed % 60:02}")
        log.write_log(f"Log: {log.log_path()}")

        self.result_text = f"Output:\n{zip_path}\n\nSHA-256:\n{sha256}"


def main(argv: list[str]) -> int:
    # The console may not be able to show every character (such as when redirected); never fail on output
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    log.start()
    args, given = parse_arguments(argv)
    build = Build(args, given)

    saved_env = {key: os.environ.get(key) for key in ENV_OVERRIDES}
    for key, value in ENV_OVERRIDES.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    exit_code = 0
    try:
        build.run()
        if not build.cancelled and not build.no_popup:
            gui.show_popup(build.result_text, False)
    # Any error stops the build and is reported to the user
    except (Exception, KeyboardInterrupt) as e:  # noqa: BLE001
        exit_code = 1
        message = str(e) or type(e).__name__
        if not log.log_path():
            log.open_log_file(None, LOG_DIR, build.timestamp)
        log.write_log()
        log.write_log(f"Failed: {message}", color="red")
        log.write_log(traceback.format_exc().rstrip(), color="gray")
        if os.path.exists(WORK_DIR):
            log.write_log(f"The work folder is kept for investigation: {WORK_DIR}")
        log.write_log(f"Log: {log.log_path()}")
        if not build.no_popup:
            gui.show_popup(f"{message}\n\nLog:\n{log.log_path()}", True)
    finally:
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
