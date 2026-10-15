"""Exercises remote sources using local repositories without network access."""

import subprocess
import zipfile

import pytest

import build_offline
from odekake import BuildError, log
from odekake.project import get_project_files
from odekake.source import (
    assert_internal_path_dependencies,
    clone_remote_source,
    worktree_provenance,
)


def git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


@pytest.fixture
def repository(tmp_path, monkeypatch):
    config = tmp_path / "gitconfig"
    config.write_text("[core]\n    autocrlf = false\n", encoding="utf-8")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_AUTHOR_NAME", "Test")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "Test")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
    root = tmp_path / "project"
    root.mkdir()
    git(root, "init", "-b", "main")
    (root / "pyproject.toml").write_text(
        '[project]\nname = "sample"\nversion = "1.0"\n', encoding="utf-8"
    )
    (root / "uv.lock").write_text("version = 1\n", encoding="utf-8")
    (root / ".python-version").write_text("3.13\n", encoding="utf-8")
    (root / "code.py").write_bytes(b"committed\n")
    (root / ".gitattributes").write_text("hidden export-ignore\n", encoding="utf-8")
    (root / "hidden").write_text("hidden\n", encoding="utf-8")
    git(root, "add", ".")
    git(root, "commit", "-m", "Initial")
    bare = tmp_path / "remote.git"
    subprocess.run(
        ["git", "clone", "--bare", str(root), str(bare)],
        check=True,
        capture_output=True,
    )
    git(root, "remote", "add", "origin", str(bare))
    return root, bare


def test_remote_ahead_excludes_worktree_changes_and_preserves_attributes(
    repository, tmp_path
):
    root, bare = repository
    upstream = tmp_path / "upstream"
    subprocess.run(
        ["git", "clone", str(bare), str(upstream)], check=True, capture_output=True
    )
    (upstream / "code.py").write_text("remote\n", encoding="utf-8")
    git(upstream, "commit", "-am", "Advance")
    git(upstream, "push", "origin", "main")
    expected = git(upstream, "rev-parse", "HEAD")
    (root / "code.py").write_text("dirty\n", encoding="utf-8")
    (root / "untracked").write_text("extra", encoding="utf-8")
    (root / ".gitattributes").write_text("", encoding="utf-8")
    clone = tmp_path / "clone"
    assert clone_remote_source(str(root), str(clone), "origin/main") == expected
    assert git(root, "rev-parse", "HEAD") != expected
    assert (root / "code.py").read_text() == "dirty\n"
    assert (clone / "code.py").read_text() == "remote\n"
    files = get_project_files(str(clone), False, [])
    assert "untracked" not in files
    assert "hidden" not in files
    assert "hidden" in get_project_files(str(clone), True, [], True)
    assert "code.py" not in get_project_files(str(clone), False, ["*.py"])


@pytest.mark.parametrize(
    "ref", ["origin/missing", "main", "v1.0", "origin/HEAD", "origin/main~1", ""]
)
def test_rejects_non_remote_or_missing_refs(repository, tmp_path, ref):
    root, _ = repository
    git(root, "tag", "v1.0")
    with pytest.raises(BuildError):
        clone_remote_source(str(root), str(tmp_path / "clone"), ref)


def test_fetch_failure_does_not_use_cached_ref(repository, tmp_path):
    root, _ = repository
    git(root, "fetch", "origin")
    git(root, "remote", "set-url", "origin", str(tmp_path / "missing.git"))
    with pytest.raises(BuildError, match="External command failed"):
        clone_remote_source(str(root), str(tmp_path / "clone"), "origin/main")
    assert not (tmp_path / "clone").exists()


def test_remote_subfolder_is_rejected_before_fetch(repository, tmp_path, monkeypatch):
    root, _ = repository
    subfolder = root / "app"
    subfolder.mkdir()
    git(root, "remote", "set-url", "origin", str(tmp_path / "missing.git"))
    refs_before = git(root, "for-each-ref", "refs/remotes")
    with pytest.raises(BuildError, match="repository top level"):
        clone_remote_source(str(subfolder), str(tmp_path / "clone"), "origin/main")
    assert git(root, "for-each-ref", "refs/remotes") == refs_before
    assert not (tmp_path / "clone").exists()
    work = tmp_path / "work"
    work.mkdir()
    marker = work / "previous-failure"
    marker.write_text("keep", encoding="utf-8")
    monkeypatch.setattr(build_offline, "WORK_DIR", str(work))
    args, given = build_offline.parse_arguments(
        ["--project-root", str(subfolder), "--source", "remote"]
    )
    with pytest.raises(BuildError, match="repository top level"):
        build_offline.Build(args, given).run()
    assert marker.read_text() == "keep"


def test_deleted_remote_branch_does_not_use_cached_ref(repository, tmp_path):
    root, _bare = repository
    git(root, "branch", "removed")
    git(root, "push", "origin", "removed")
    git(root, "push", "origin", "--delete", "removed")
    git(root, "update-ref", "refs/remotes/origin/removed", "HEAD")
    with pytest.raises(BuildError, match="External command failed"):
        clone_remote_source(str(root), str(tmp_path / "clone"), "origin/removed")


def test_fetches_remote_with_slashes_and_branch_outside_default_refspec(
    repository, tmp_path
):
    root, bare = repository
    git(root, "remote", "add", "team/upstream", str(bare))
    git(
        root,
        "config",
        "remote.team/upstream.fetch",
        "+refs/heads/other:refs/remotes/team/upstream/other",
    )
    assert clone_remote_source(
        str(root), str(tmp_path / "clone"), "team/upstream/main"
    ) == git(root, "rev-parse", "HEAD")


@pytest.mark.parametrize("kind", ["path", "directory", "editable", "virtual"])
@pytest.mark.parametrize(
    "value",
    ["../outside", "nested/../../outside", "C:/outside", "/outside", "..\\outside"],
)
def test_rejects_external_lock_paths(tmp_path, kind, value):
    (tmp_path / "uv.lock").write_text(
        f"[[package]]\nname = \"dep\"\nsource = {{ {kind} = '{value}' }}\n",
        encoding="utf-8",
    )
    with pytest.raises(BuildError, match="outside the repository"):
        assert_internal_path_dependencies(str(tmp_path))


def test_accepts_internal_workspace_and_registry_sources(tmp_path):
    (tmp_path / "packages/member").mkdir(parents=True)
    (tmp_path / "uv.lock").write_text(
        '[[package]]\nsource = { editable = "." }\n'
        '[[package]]\nsource = { directory = "packages/member" }\n'
        '[[package]]\nsource = { registry = "https://example.invalid/simple" }\n',
        encoding="utf-8",
    )
    assert_internal_path_dependencies(str(tmp_path))


def test_rejects_internal_dependency_missing_from_clone(tmp_path):
    (tmp_path / "uv.lock").write_text(
        '[[package]]\nname = "dep"\nsource = { path = "wheels/dep.whl" }\n',
        encoding="utf-8",
    )
    with pytest.raises(BuildError, match="missing from the clone"):
        assert_internal_path_dependencies(str(tmp_path))


def test_worktree_clean_dirty_and_ignored_files(repository, logs):
    root, _ = repository
    sha, clean = worktree_provenance(str(root))
    assert clean and sha == git(root, "rev-parse", "HEAD")
    (root / ".gitignore").write_text("ignored\n", encoding="utf-8")
    git(root, "add", ".gitignore")
    git(root, "commit", "-m", "Ignore")
    (root / "ignored").write_text("ignored", encoding="utf-8")
    assert worktree_provenance(str(root))[1]
    (root / "new").write_text("new", encoding="utf-8")
    assert not worktree_provenance(str(root))[1]
    assert any("Warning:" in message for message in logs)
    (root / "new").unlink()
    (root / "code.py").write_text("dirty", encoding="utf-8")
    assert not worktree_provenance(str(root))[1]


def test_worktree_without_commits(repository, tmp_path, logs):
    root = tmp_path / "unborn"
    root.mkdir()
    git(root, "init", "-b", "main")
    assert worktree_provenance(str(root)) == ("(no commits)", True)
    assert any("(no commits)" in message for message in logs)


def test_build_uses_clone_for_metadata_dependencies_and_zip(
    repository, tmp_path, monkeypatch, logs
):
    root, _ = repository
    expected = git(root, "rev-parse", "HEAD")
    (root / "pyproject.toml").unlink()
    (root / "uv.lock").unlink()
    (root / ".python-version").write_text("3.99", encoding="utf-8")
    (root / "code.py").write_text("dirty", encoding="utf-8")
    (root / "extra").write_text("extra", encoding="utf-8")
    work = tmp_path / "work"
    monkeypatch.setattr(build_offline, "WORK_DIR", str(work))
    monkeypatch.setattr(log, "open_log_file", lambda *args: None)
    original_run = log.run
    uv_roots = []

    def run(command, args, **kwargs):
        if command == "git":
            return original_run(command, args, **kwargs)
        if command == "uv":
            if args == ["--version"]:
                return "uv test"
            uv_roots.append(args[args.index("--project") + 1])
            if args[0] == "export":
                from pathlib import Path

                Path(args[args.index("--output-file") + 1]).write_text(
                    "", encoding="utf-8"
                )
        return ""

    monkeypatch.setattr(log, "run", run)
    monkeypatch.setattr(
        build_offline.winpython, "get_winpython_archive", lambda *args: "unused"
    )

    def expand(archive, destination, work_dir):
        from pathlib import Path

        destination = Path(destination)
        (destination / "python/Lib/site-packages").mkdir(parents=True)
        (destination / "python/python.exe").write_bytes(b"test")

    monkeypatch.setattr(build_offline.winpython, "expand_winpython", expand)
    monkeypatch.setattr(build_offline.ziputil, "get_system_tar_path", lambda: "unused")
    args, given = build_offline.parse_arguments(
        [
            "--project-root",
            str(root),
            "--source",
            "remote",
            "--output-dir",
            str(tmp_path),
            "--no-popup",
        ]
    )
    build = build_offline.Build(args, given)
    build.run()
    assert uv_roots == [str(work / "source"), str(work / "source")]
    with zipfile.ZipFile(next(tmp_path.glob("sample-1.0_*.zip"))) as archive:
        assert archive.read("code.py") == b"committed\n"
        assert "extra" not in archive.namelist()
        assert "hidden" not in archive.namelist()
    assert "Source: remote" in build.result_text
    assert "origin/main" in build.result_text
    assert expected in build.result_text
    assert not work.exists()


@pytest.mark.parametrize("subfolder", [False, True])
def test_worktree_validation_failure_preserves_previous_work(
    repository, tmp_path, monkeypatch, subfolder
):
    root, _ = repository
    if subfolder:
        app = root / "app"
        app.mkdir()
        for name in ("pyproject.toml", "uv.lock", ".python-version"):
            (app / name).write_bytes((root / name).read_bytes())
        root = app
    work = tmp_path / "work"
    work.mkdir()
    marker = work / "previous-failure"
    marker.write_text("keep", encoding="utf-8")
    monkeypatch.setattr(build_offline, "WORK_DIR", str(work))
    monkeypatch.setattr(log, "open_log_file", lambda *args: None)
    args, given = build_offline.parse_arguments(
        [
            "--project-root",
            str(root),
            "--source",
            "worktree",
            "--output-dir",
            str(tmp_path / "missing"),
        ]
    )
    with pytest.raises(BuildError, match="Output folder not found"):
        build_offline.Build(args, given).run()
    assert marker.read_text() == "keep"
