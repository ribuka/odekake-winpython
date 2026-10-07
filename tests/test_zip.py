"""Tests for odekake/zip.py."""

import os
import subprocess
import sys
import tempfile
import zipfile

import pytest
from conftest import write_text

from odekake import BuildError
from odekake.zip import (
    ZipEntry,
    assert_seven_zip_writable,
    get_system_tar_path,
    new_seven_zip_from_directory,
    new_zip_file,
    new_zip_from_directory,
)

windows_only = pytest.mark.skipif(sys.platform != "win32", reason="needs Windows")


def _can_write_7z() -> bool:
    """Whether tar.exe on this PC can create 7z (it may not on older Windows)."""
    if sys.platform != "win32":
        return False
    with tempfile.TemporaryDirectory() as probe:
        write_text(os.path.join(probe, "a.txt"), "a")
        command = [
            get_system_tar_path(),
            "-C",
            probe,
            "--format",
            "7zip",
            "--options",
            "7zip:compression=lzma2",
            "-cf",
            os.path.join(probe, "p.7z"),
            "a.txt",
        ]
        try:
            return (
                subprocess.run(command, capture_output=True, check=False).returncode
                == 0
            )
        except OSError:
            return False


needs_7z = pytest.mark.skipif(
    not _can_write_7z(), reason="tar.exe on this PC cannot create 7z"
)


def zip_entries(path) -> dict[str, zipfile.ZipInfo]:
    with zipfile.ZipFile(path) as zf:
        return {info.filename: info for info in zf.infolist()}


class TestNewZipFromDirectory:
    @pytest.fixture
    def entries(self, tmp_path):
        src = tmp_path / "src"
        write_text(src / "top.txt", "top")
        write_text(src / "a" / "b" / "c.txt", "c")
        write_text(src / "日本語" / "ファイル.txt", "jp")
        (src / "empty" / "inner").mkdir(parents=True)
        zip_path = tmp_path / "dir.zip"
        new_zip_from_directory(str(zip_path), str(src))
        assert not os.path.exists(f"{zip_path}.partial")
        return zip_entries(zip_path)

    def test_uses_only_slashes_in_entry_names_without_the_folder_itself(self, entries):
        assert sorted(entries) == [
            "a/b/c.txt",
            "empty/inner/",
            "top.txt",
            "日本語/ファイル.txt",
        ]
        assert not any("\\" in name for name in entries)

    def test_includes_empty_folders(self, entries):
        assert entries["empty/inner/"].is_dir()
        assert entries["empty/inner/"].file_size == 0


class TestNewZipFile:
    @pytest.fixture
    def source(self, tmp_path):
        # A highly compressible file, to see whether store changes the compressed size.
        path = tmp_path / "repeat.txt"
        write_text(path, "a" * 100000)
        return str(path)

    def test_stores_store_entries_without_compression_and_compresses_the_rest(
        self, tmp_path, source
    ):
        zip_path = tmp_path / "store.zip"
        new_zip_file(
            str(zip_path),
            [
                ZipEntry("stored.txt", source, store=True),
                ZipEntry("dir/deflated.txt", source),
                ZipEntry("empty/", None),
            ],
        )
        entries = zip_entries(zip_path)
        assert sorted(entries) == ["dir/deflated.txt", "empty/", "stored.txt"]
        assert entries["stored.txt"].compress_type == zipfile.ZIP_STORED
        assert entries["stored.txt"].compress_size == 100000
        assert entries["dir/deflated.txt"].compress_size < 10000

    def test_works_even_when_a_previous_partial_file_remains(self, tmp_path, source):
        zip_path = tmp_path / "retry.zip"
        write_text(f"{zip_path}.partial", "broken")
        new_zip_file(str(zip_path), [ZipEntry("a.txt", source)])
        assert list(zip_entries(zip_path)) == ["a.txt"]
        assert not os.path.exists(f"{zip_path}.partial")


@needs_7z
class TestNewSevenZipFromDirectory:
    @pytest.fixture
    def archive(self, tmp_path):
        src = tmp_path / "src7"
        write_text(src / "top.txt", "top")
        write_text(src / "a b" / "c.txt", "c" * 100000)
        write_text(src / "日本語" / "ファイル.txt", "jp")
        (src / "empty" / "inner").mkdir(parents=True)
        path = tmp_path / "dir.7z"
        new_seven_zip_from_directory(str(path), str(src), get_system_tar_path())
        assert not os.path.exists(f"{path}.partial")
        return path

    def test_writes_the_7z_format_with_compression(self, archive):
        data = archive.read_bytes()
        assert data[:6] == bytes([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])
        assert len(data) < 10000

    def test_does_not_start_entry_names_with_dot_slash_and_leaves_out_the_folder_itself(
        self, archive
    ):
        # tar -tf prints in the console code page, so Japanese names are not compared here (checked by extracting)
        out = subprocess.run(
            [get_system_tar_path(), "-tf", str(archive)],
            capture_output=True,
            check=True,
        ).stdout
        names = [
            line.rstrip("/")
            for line in out.decode("ascii", errors="replace").splitlines()
        ]
        assert len(names) == 7
        ascii_names = sorted(n for n in names if "�" not in n and "?" not in n)
        assert ascii_names == ["a b", "a b/c.txt", "empty", "empty/inner", "top.txt"]

    def test_extracts_to_the_same_contents_as_the_original(self, archive, tmp_path):
        out = tmp_path / "out7"
        out.mkdir()
        subprocess.run(
            [get_system_tar_path(), "-C", str(out), "-xf", str(archive)], check=True
        )
        assert (out / "a b" / "c.txt").read_text() == "c" * 100000
        assert (out / "日本語" / "ファイル.txt").read_text(encoding="utf-8") == "jp"
        assert (out / "empty" / "inner").is_dir()

    def test_fails_on_an_empty_folder(self, tmp_path):
        empty = tmp_path / "empty7"
        empty.mkdir()
        with pytest.raises(BuildError, match="The folder to pack into 7z is empty: "):
            new_seven_zip_from_directory(
                str(tmp_path / "empty.7z"), str(empty), get_system_tar_path()
            )


class TestAssertSevenZipWritable:
    def test_fails_without_tar_exe(self, tmp_path):
        with pytest.raises(
            BuildError, match="tar.exe, needed to create 7z, not found: "
        ):
            assert_seven_zip_writable(str(tmp_path / "no" / "tar.exe"), str(tmp_path))

    @windows_only
    def test_fails_when_tar_cannot_write_7z_and_leaves_no_test_files_behind(
        self, tmp_path
    ):
        # Use a command that always fails in place of a tar that cannot write 7z
        fake_tar = os.path.join(os.environ["SystemRoot"], "System32", "where.exe")
        work = tmp_path / "work-fail"
        work.mkdir()
        with pytest.raises(BuildError, match="tar.exe on this PC cannot create 7z. "):
            assert_seven_zip_writable(fake_tar, str(work))
        assert os.listdir(work) == []

    @needs_7z
    def test_leaves_nothing_behind_when_7z_can_be_created(self, tmp_path):
        work = tmp_path / "work-ok"
        work.mkdir()
        assert_seven_zip_writable(get_system_tar_path(), str(work))
        assert os.listdir(work) == []
