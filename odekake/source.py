"""Selects the project source and records its Git provenance."""

import os
from pathlib import Path, PureWindowsPath

from odekake import BuildError, log
from odekake.project import read_toml


def assert_remote_project_root(root: str) -> None:
    """Rejects unsupported subfolder projects before changing build state."""
    prefix = log.run(
        "git", ["-C", root, "rev-parse", "--show-prefix"], capture=True
    ).strip()
    if prefix:
        raise BuildError(
            "Remote source requires a project at the repository top level; "
            "projects in repository subfolders are not supported."
        )


def clone_remote_source(root: str, destination: str, remote_ref: str) -> str:
    """Fetches a remote branch and checks out its exact commit in a local clone."""
    assert_remote_project_root(root)
    remotes = log.run("git", ["-C", root, "remote"], capture=True).splitlines()
    matches = [name for name in remotes if remote_ref.startswith(name + "/")]
    if not matches:
        raise BuildError(f"Not a remote branch: {remote_ref}")
    remote = max(matches, key=len)
    branch = remote_ref[len(remote) + 1 :]
    if branch == "HEAD":
        raise BuildError("remote_ref must name a remote branch, not remote HEAD.")
    log.run("git", ["check-ref-format", f"refs/heads/{branch}"])
    # An explicit refspec also handles remotes configured to fetch only one branch.
    log.run(
        "git",
        [
            "-C",
            root,
            "fetch",
            "--",
            remote,
            f"+refs/heads/{branch}:refs/remotes/{remote_ref}",
        ],
    )
    sha = log.run(
        "git",
        ["-C", root, "rev-parse", "--verify", f"refs/remotes/{remote_ref}^{{commit}}"],
        capture=True,
    ).strip()
    # Copy objects independently, including commits only reachable from remote refs.
    log.run(
        "git", ["clone", "--no-checkout", "--no-hardlinks", "--", root, destination]
    )
    log.run("git", ["-C", destination, "checkout", "--detach", sha])
    return sha


def worktree_summary(sha: str, clean: bool) -> str:
    """Formats worktree provenance consistently for logs and the popup."""
    return (
        f"Source: worktree / Commit: {sha} / Worktree: {'clean' if clean else 'dirty'}"
    )


def worktree_provenance(root: str) -> tuple[str, bool]:
    """Records HEAD and rejects uncommitted changes without logging file names."""
    try:
        sha = log.run(
            "git",
            ["-C", root, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            capture=True,
        ).strip()
    except BuildError:
        # Confirm the repository is still readable before treating HEAD as unborn.
        log.run("git", ["-C", root, "symbolic-ref", "HEAD"], capture=True)
        sha = "(no commits)"
    status = log.run(
        "git",
        ["-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        capture=True,
    )
    # With -z, renames/copies have a second path record; all other entries have one.
    records = iter(status.split("\0"))
    changed = 0
    for record in records:
        if not record:
            continue
        changed += 1
        if "R" in record[:2] or "C" in record[:2]:
            next(records)
    clean = changed == 0
    log.write_log(worktree_summary(sha, clean))
    if not clean:
        raise BuildError(
            f"The worktree is not clean. Changed files: {changed} "
            "(including untracked files). Commit or remove the changes before building."
        )
    return sha, clean


def assert_internal_path_dependencies(root: str) -> None:
    """Rejects lockfile path sources that escape the cloned repository."""
    base = Path(root).resolve()
    for package in read_toml(os.path.join(root, "uv.lock"), "uv.lock").get(
        "package", []
    ):
        source = package.get("source", {})
        for key in ("path", "directory", "editable", "virtual"):
            value = source.get(key) if isinstance(source, dict) else None
            if not isinstance(value, str):
                continue
            # Windows syntax must also be recognized by the Ubuntu test runner.
            windows = PureWindowsPath(value)
            normalized = value.replace("\\", "/")
            target = (base / normalized).resolve()
            if windows.drive or windows.root or not target.is_relative_to(base):
                raise BuildError(
                    f"Remote source cannot use a path dependency outside the repository: "
                    f"{package.get('name', '(unknown)')} ({key}: {value})"
                )
            if not target.exists():
                raise BuildError(
                    f"Remote source path dependency is missing from the clone: "
                    f"{package.get('name', '(unknown)')} ({key}: {value})"
                )
