"""Information about the target project."""

import os
import re
import tomllib

from odekake import BuildError, log


def _read_toml(path: str, label: str) -> dict:
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise BuildError(f"Cannot read {label} as TOML: {path}\n{e}") from e


def read_pyproject(path: str) -> dict:
    """Reads name / version / dynamic from [project] in pyproject.toml.

    Returns {'name': str | None, 'version': str | None, 'dynamic': list[str]}.
    """
    project = _read_toml(path, "pyproject.toml").get("project", {})
    if not isinstance(project, dict):
        project = {}
    name = project.get("name")
    version = project.get("version")
    dynamic = project.get("dynamic", [])
    return {
        "name": name if isinstance(name, str) else None,
        "version": version if isinstance(version, str) else None,
        "dynamic": [d for d in dynamic if isinstance(d, str)]
        if isinstance(dynamic, list)
        else [],
    }


def get_project_version(root: str, pyproject: dict) -> str:
    if pyproject["version"]:
        return pyproject["version"]
    if "version" in pyproject["dynamic"]:
        version_file = os.path.join(root, "VERSION")
        if not os.path.isfile(version_file):
            raise BuildError(
                f"version in pyproject.toml is dynamic, but there is no VERSION file: {version_file}"
            )
        with open(version_file, encoding="utf-8-sig") as f:
            version = f.read().strip()
        if not version or "\n" in version or "\r" in version:
            raise BuildError(
                f"The VERSION file must contain the version on a single line: {version_file}"
            )
        return version
    raise BuildError(
        "pyproject.toml has no version in [project] (and version is not in dynamic either)."
    )


def _minor_of(raw: str) -> str | None:
    m = re.search(r"(\d+)\.(\d+)", raw)
    return f"{m.group(1)}.{m.group(2)}" if m else None


def get_python_minor(
    root: str, from_argument: str | None, from_settings: str | None
) -> str:
    """Decides the Python minor version (such as 3.13).

    Priority: argument --python-version > .python-version > pythonVersion in the settings file
    """
    from_file = None
    pv_file = os.path.join(root, ".python-version")
    if os.path.isfile(pv_file):
        with open(pv_file, encoding="utf-8-sig") as f:
            lines = [line.strip() for line in f]
        from_file = next(
            (line for line in lines if line and not line.startswith("#")), None
        )

    if from_argument:
        source, raw = "argument --python-version", from_argument
    elif from_file:
        source, raw = ".python-version", from_file
    elif from_settings:
        source, raw = "pythonVersion in the settings file", from_settings
    else:
        raise BuildError(
            ".python-version not found. Specify the version with pythonVersion (--python-version), such as 3.13."
        )

    minor = _minor_of(raw)
    if not minor:
        raise BuildError(f"Cannot read the Python version ({source}): '{raw}'")

    if from_argument and from_file:
        file_minor = _minor_of(from_file)
        if file_minor and file_minor != minor:
            log.write_log(
                f"Warning: using Python {minor} as specified by argument --python-version, "
                f"which differs from .python-version ({from_file}).",
                color="yellow",
            )
    log.write_log(f"Python version: {minor} ({source}: {raw})")
    return minor


def get_project_files(
    root: str,
    tracked_only: bool,
    exclude: list[str],
    include_export_ignored: bool = False,
) -> list[str]:
    """Lists the files to put into the ZIP with git (paths relative to the target project, separated by /).

    If include_export_ignored is false, files marked export-ignore in .gitattributes are left out (issue #12).
    """
    git_args = ["-C", root, "-c", "core.quotepath=off", "ls-files", "-z", "--cached"]
    if not tracked_only:
        git_args += ["--others", "--exclude-standard"]
    git_args += ["--", "."]
    git_args += [f":(exclude,glob){pattern}" for pattern in exclude]

    candidates = []
    for rel in log.run("git", git_args, capture=True).split("\0"):
        if not rel:
            continue
        if not os.path.isfile(os.path.join(root, rel)):
            # Files deleted but not yet committed, or submodules
            log.write_log(f"Skipped (not an existing file): {rel}", color="yellow")
            continue
        candidates.append(rel)

    ignored = (
        set() if include_export_ignored else get_export_ignored_paths(root, candidates)
    )
    files = []
    for rel in candidates:
        if rel in ignored:
            log.write_log(f"Excluded (export-ignore): {rel}")
            continue
        # Windows file names are case-insensitive, so the conflict check is too
        lower = rel.lower()
        if lower in ("winpython.zip", "winpython.7z") or lower.startswith("winpython/"):
            raise BuildError(
                f"The target project has '{rel}', which conflicts with winpython.zip / winpython.7z / winpython\\ "
                "in the output. Leave it out with exclude."
            )
        files.append(rel)
    if not files:
        raise BuildError("There are no files to put into the ZIP.")
    return files


def get_export_ignored_paths(root: str, paths: list[str]) -> set[str]:
    """Returns the paths (relative, separated by /) marked export-ignore, including those whose parent folder is marked.

    git check-attr does not apply a pattern that matches a folder (such as /tests/) to the files inside it.
    So parent folders are also checked with a trailing /, giving the same result as git archive leaving out the whole folder.
    .gitattributes is read from the working tree (git archive uses the target commit by default),
    because files not yet added also go into the ZIP.
    """
    if not paths:
        return set()
    ancestors: dict[str, list[str]] = {}
    queries: dict[str, None] = {}  # ordered set
    for rel in paths:
        parts = rel.split("/")
        dirs = ["/".join(parts[:i]) + "/" for i in range(1, len(parts))]
        ancestors[rel] = dirs
        for q in [*dirs, rel]:
            queries[q] = None

    out = log.run(
        "git",
        ["-C", root, "check-attr", "-z", "--stdin", "export-ignore"],
        capture=True,
        input_text="".join(f"{q}\0" for q in queries),
    )
    # The output repeats "path NUL attribute NUL value NUL". Only entries whose value is set are left out (same as git archive).
    # The string value export-ignore=set is also printed as set and cannot be told apart, so it is left out too
    # (known limitation; spec §2).
    fields = out.split("\0")
    marked = {fields[j] for j in range(0, len(fields) - 2, 3) if fields[j + 2] == "set"}

    return {rel for rel in paths if any(q in marked for q in [*ancestors[rel], rel])}


def _normalize_name(name: str) -> str:
    """PEP 503 name normalization."""
    return re.sub(r"[-_.]+", "-", name).lower()


def get_non_pypi_requirements(
    lock_path: str, requirements_path: str, pypi_index_url: str
) -> list[str]:
    """Returns the dependencies in requirements.txt (the output of uv export) that uv.lock takes from an index
    (registry) other than PyPI.

    pip does not know the index from requirements.txt, so pip mode cannot install them (issue #10).
    Returns a list of "name==version (index URL)".
    When environment markers switch the index, the same name==version appears more than once with different registries.
    requirements.txt does not tell which one was chosen, so it is returned if any of them is not PyPI (to be safe).
    """
    registries: dict[str, list[str]] = {}
    for package in _read_toml(lock_path, "uv.lock").get("package", []):
        source = package.get("source", {})
        registry = source.get("registry") if isinstance(source, dict) else None
        if package.get("name") and registry:
            key = f"{_normalize_name(package['name'])}=={package.get('version')}"
            registries.setdefault(key, []).append(registry)

    result = []
    seen = set()
    with open(requirements_path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)", line)
            if not m:
                continue
            key = f"{_normalize_name(m.group(1))}=={m.group(2)}"
            if key not in registries or key in seen:
                continue
            seen.add(key)
            for registry in registries[key]:
                if registry.rstrip("/") != pypi_index_url.rstrip("/"):
                    result.append(f"{key} ({registry})")
    return result
