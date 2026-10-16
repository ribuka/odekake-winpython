"""Network-free Defender scan tests using injected subprocess results."""

import datetime
import io
import json
import os
import subprocess
import zipfile
from pathlib import Path

import pytest

from build_offline import Build, parse_arguments
from odekake import BuildError, scan

FOLDER = r"C:\Temp\scan-日本語"
SCAN_ID = "{12345678-1234-1234-1234-123456789abc}"
OTHER_ID = "{00000000-0000-0000-0000-000000000000}"


def event(number, message, second=0):
    return {
        "Id": number,
        "Message": message,
        "TimeCreated": f"2026-10-16T12:00:{second:02}+09:00",
    }


def clean_events():
    return [
        event(1000, f"スキャン ID: {SCAN_ID}\nScan Resources: folder:_{FOLDER}"),
        event(1001, f"Scan ID: {SCAN_ID}", 1),
    ]


def result(stdout="", returncode=0):
    return subprocess.CompletedProcess(
        [], returncode, stdout, "command error" if returncode else ""
    )


@pytest.mark.parametrize(
    "mode,enabled,ok",
    [("Normal", True, True), ("Passive", True, False), ("Normal", False, False)],
)
def test_defender_status(monkeypatch, tmp_path, mode, enabled, ok):
    monkeypatch.setenv("ProgramFiles", str(tmp_path))
    scanner = tmp_path / "Windows Defender" / "MpCmdRun.exe"
    scanner.parent.mkdir()
    scanner.touch()

    def run(args, **kwargs):
        assert args[:4] == [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
        ]
        assert "Get-MpComputerStatus" in args[4]
        return result(json.dumps({"AMRunningMode": mode, "AntivirusEnabled": enabled}))

    if ok:
        assert scan.check_defender(run) == str(scanner)
    else:
        with pytest.raises(BuildError, match="Normal"):
            scan.check_defender(run)


def test_defender_command_failure():
    with pytest.raises(BuildError, match="command failed"):
        scan.check_defender(lambda *a, **k: result(returncode=1))


def test_defender_executable_missing(monkeypatch, tmp_path):
    monkeypatch.setenv("ProgramFiles", str(tmp_path))
    with pytest.raises(BuildError, match="scanner not found"):
        scan.check_defender(
            lambda *a, **k: result('{"AMRunningMode":"Normal","AntivirusEnabled":true}')
        )


@pytest.mark.parametrize(
    "text,count",
    [
        ("found 0 threats", 0),
        ("found no threats", 0),
        ("found 1 threats", 1),
        ("found 12 threats", 12),
    ],
)
def test_threat_count(text, count):
    assert scan.threat_count(text) == count


def test_missing_threat_count():
    with pytest.raises(BuildError, match="threat count"):
        scan.threat_count("Scan finished.")


def test_select_events_excludes_other_scans_and_sorts():
    detection = event(1116, f"Path: file:_{FOLDER.lower()}\\app\\sample.txt", 2)
    events = clean_events() + [
        detection,
        event(1000, f"{OTHER_ID} other"),
        event(1001, OTHER_ID),
        event(1117, "other path"),
    ]
    assert scan.select_events(list(reversed(events)), FOLDER) == clean_events() + [
        detection
    ]


@pytest.mark.parametrize(
    "payload,expected",
    [("", []), (json.dumps(event(1000, "日本語")), [event(1000, "日本語")])],
)
def test_event_json_shapes(payload, expected):
    def run(args, **kwargs):
        assert "Get-WinEvent" in args[4]
        assert "OutputEncoding" in args[4]
        assert kwargs["encoding"] == "utf-8"
        return result(payload)

    assert scan.read_events(datetime.datetime.now(datetime.UTC), run) == expected


@pytest.mark.parametrize(
    "code,text,extra,match",
    [
        (0, "found 0 threats", [], None),
        (0, "found no threats", [], None),
        (0, "found 1 threats", [event(1116, FOLDER)], "found threats"),
        (0, "found 1 threats", [], "disagree"),
        (0, "found 0 threats", [event(1117, FOLDER)], "disagree"),
        (2, "found 0 threats", [], "code 2"),
        (2, "", [], "code 2"),
        (0, "found 0 threats", [event(1002, SCAN_ID)], "interrupted"),
        (0, "found 0 threats", [event(1005, SCAN_ID)], "failed"),
    ],
)
def test_scan_result(code, text, extra, match):
    if match:
        with pytest.raises(BuildError, match=match):
            scan.validate_result(code, text, clean_events() + extra)
    else:
        scan.validate_result(code, text, clean_events())


def test_incomplete_scan_result():
    with pytest.raises(BuildError, match="incomplete"):
        scan.validate_result(0, "found 0 threats", [])


@pytest.mark.parametrize(
    "complete,detected", [(True, False), (True, True), (False, False)]
)
def test_waits_for_terminal_and_remediation(monkeypatch, complete, detected):
    ticks = [0]
    responses = [clean_events()[:1]]
    if complete:
        responses.append(clean_events() + ([event(1116, FOLDER)] if detected else []))
        if detected:
            responses.append(
                clean_events() + [event(1116, FOLDER), event(1117, FOLDER)]
            )

    def read(*args):
        return responses.pop(0) if len(responses) > 1 else responses[0]

    monkeypatch.setattr(scan, "read_events", read)

    def sleep(seconds):
        ticks[0] += seconds

    events, done = scan.wait_events(
        None, FOLDER, monotonic=lambda: ticks[0], sleep=sleep
    )
    assert done is complete
    expected = (4 if detected else 2) if complete else 60
    assert ticks[0] == expected
    assert bool(events)


def test_missing_guid_keeps_raw_start_for_evidence(monkeypatch):
    raw = [event(1000, FOLDER)]
    monkeypatch.setattr(scan, "read_events", lambda *a: raw)
    collected = []
    with pytest.raises(BuildError, match="GUID"):
        scan.wait_events(None, FOLDER, collected=collected)
    assert collected == raw


def test_evidence_preserves_messages_without_bom(tmp_path):
    path = tmp_path / "evidence.txt"
    message = "日本語\r\nBroken � label:  \nUser: EXAMPLE\\sample"
    scan.write_evidence(path, "Scanning\nfound 0 threats.\n", [event(1000, message)])
    assert path.read_bytes() == (
        "Scanning\r\nfound 0 threats.\r\nEvent ID: 1000 TimeCreated: 2026-10-16T12:00:00+09:00\r\n"
        + message.replace("\r\n", "\n").replace("\n", "\r\n")
    ).encode("utf-8")


def payload(path, extension="zip"):
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, "w") as archive:
        archive.writestr("python/hello.txt", "hello")
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(f"winpython.{extension}", inner.getvalue())
        archive.writestr("src/hello.py", "print('hello')")


def test_extracts_nested_zip_and_removes_archive(tmp_path):
    path = tmp_path / "payload.zip"
    payload(path)
    folder = tmp_path / "expanded"
    scan.extract_payload(str(path), str(folder))
    assert (folder / "winpython/python/hello.txt").read_text() == "hello"
    assert not (folder / "winpython.zip").exists()


def test_extracts_seven_zip_with_system_tar(tmp_path):
    path = tmp_path / "payload.zip"
    payload(path, "7z")
    folder = tmp_path / "expanded"

    def run(args, **kwargs):
        assert args == [
            scan.ziputil.get_system_tar_path(),
            "-xf",
            str(folder / "winpython.7z"),
            "-C",
            str(folder / "winpython"),
        ]
        return result()

    scan.extract_payload(str(path), str(folder), run)
    assert not (folder / "winpython.7z").exists()


@pytest.mark.parametrize("failure", [None, "threat", "timeout", "extract", "events"])
def test_scan_cleans_up_and_preserves_zip_and_evidence(monkeypatch, tmp_path, failure):
    path = tmp_path / "payload.zip"
    payload(path)
    monkeypatch.setattr(scan, "long_path", lambda path: path)
    folders = []

    def run(args, **kwargs):
        assert args[1:5] == ["-Scan", "-ScanType", "3", "-File"]
        folder = args[5]
        folders.append(folder)
        assert os.path.isfile(os.path.join(folder, "winpython", "python", "hello.txt"))
        assert not os.path.exists(os.path.join(folder, "winpython.zip"))
        return result("found 1 threats" if failure == "threat" else "found 0 threats")

    def wait(*args, collected=None, **kwargs):
        collected[:] = clean_events()
        if failure == "events":
            raise BuildError("event access failed")
        return clean_events() + (
            [event(1116, FOLDER)] if failure == "threat" else []
        ), failure != "timeout"

    monkeypatch.setattr(scan, "wait_events", wait)
    if failure == "extract":
        monkeypatch.setattr(
            scan,
            "extract_payload",
            lambda *a: (_ for _ in ()).throw(BuildError("extraction failed")),
        )
    if failure:
        with pytest.raises(
            BuildError,
            match="Scan record:.*",
        ):
            scan.scan_zip(str(path), "scanner", run)
    else:
        assert scan.scan_zip(str(path), "scanner", run) == str(path) + ".scan.txt"
    assert path.exists()
    assert os.path.isfile(str(path) + ".scan.txt")
    assert all(not os.path.exists(folder) for folder in folders)
    if failure == "events":
        assert "Event ID: 1000" in (tmp_path / "payload.zip.scan.txt").read_text(
            encoding="utf-8"
        )


def test_defender_preflight_runs_before_project_access(monkeypatch):
    args, given = parse_arguments(["--virus-scan", "--project-root", "missing"])
    monkeypatch.setattr(
        scan, "check_defender", lambda: (_ for _ in ()).throw(BuildError("preflight"))
    )
    with pytest.raises(BuildError, match="preflight"):
        Build(args, given).run()


def test_virus_scan_boolean_arguments():
    assert parse_arguments(["--virus-scan"])[1]["virus_scan"] is True
    assert parse_arguments(["--no-virus-scan"])[1]["virus_scan"] is False


@pytest.mark.parametrize("enabled", [False, True])
def test_build_scans_after_cleanup_before_done(monkeypatch, tmp_path, logs, enabled):
    import build_offline as build

    root = tmp_path / "project"
    root.mkdir()
    (root / "pyproject.toml").touch()
    (root / "uv.lock").touch()
    output = tmp_path / "output"
    output.mkdir()
    work = tmp_path / "work"
    monkeypatch.setattr(build, "WORK_DIR", str(work))
    monkeypatch.setattr(build, "BUILD_DIR", str(tmp_path))
    monkeypatch.setattr(build, "REPO_ROOT", str(tmp_path))
    monkeypatch.setattr(build.shutil, "which", lambda *a: "tool")
    monkeypatch.setattr(build.project, "read_pyproject", lambda *a: {"name": "sample"})
    monkeypatch.setattr(build.project, "get_project_version", lambda *a: "1.0")
    monkeypatch.setattr(build.project, "get_python_minor", lambda *a: "3.13")
    monkeypatch.setattr(build.project, "get_project_files", lambda *a: [])
    monkeypatch.setattr(build.log, "open_log_file", lambda *a: None)
    monkeypatch.setattr(build.log, "write_step", lambda text: logs.append(text))
    monkeypatch.setattr(build.log, "log_path", lambda: "build.log")

    def run(exe, args, **kwargs):
        if "status" in args:
            return ""
        if "--output-file" in args:
            Path(args[args.index("--output-file") + 1]).write_text("", encoding="utf-8")
        return "true" if "rev-parse" in args else "tool"

    monkeypatch.setattr(build.log, "run", run)
    monkeypatch.setattr(
        build.winpython, "get_winpython_archive", lambda *a: "cached.zip"
    )

    def expand(archive, destination, *args):
        runtime = Path(destination) / "python"
        (runtime / "Lib/site-packages").mkdir(parents=True)
        (runtime / "python.exe").touch()

    monkeypatch.setattr(build.winpython, "expand_winpython", expand)
    calls = []

    def preflight():
        calls.append("preflight")
        return "scanner"

    def scan_zip(path, scanner):
        assert not work.exists()
        assert "Done." not in logs
        assert os.path.isfile(path)
        calls.append("scan")
        return path + ".scan.txt"

    monkeypatch.setattr(build.scan, "check_defender", preflight)
    monkeypatch.setattr(build.scan, "scan_zip", scan_zip)
    args, given = parse_arguments(
        [
            "--project-root",
            str(root),
            "--output-dir",
            str(output),
            "--virus-scan" if enabled else "--no-virus-scan",
        ]
    )
    instance = Build(args, given)
    instance.run()
    assert calls == (["preflight", "scan"] if enabled else [])
    assert ("Scan record:" in instance.result_text) is enabled
    assert "Done." in logs


@pytest.mark.parametrize("output", ["invalid", "null", "[]"])
def test_invalid_defender_status_is_build_error(output):
    with pytest.raises(BuildError):
        scan.check_defender(lambda *a, **k: result(output))


def test_failed_event_query_preserves_collected_events(monkeypatch):
    calls = [0]

    def read(*args):
        calls[0] += 1
        if calls[0] == 1:
            return clean_events()[:1]
        raise BuildError("access denied")

    monkeypatch.setattr(scan, "read_events", read)
    collected = []
    with pytest.raises(BuildError, match="access denied"):
        scan.wait_events(None, FOLDER, sleep=lambda *a: None, collected=collected)
    assert collected == clean_events()[:1]


@pytest.mark.parametrize("threat", [False, True])
def test_cleanup_failure_preserves_scan_failure_and_folder(
    monkeypatch, tmp_path, threat
):
    path = tmp_path / "payload.zip"
    payload(path)
    monkeypatch.setattr(scan, "long_path", lambda path: path)
    real_remove = scan.remove_tree
    folders = []

    def remove(folder):
        folders.append(folder)
        raise OSError("file is in use")

    monkeypatch.setattr(scan, "remove_tree", remove)

    def wait(*a, **k):
        return clean_events() + ([event(1116, FOLDER)] if threat else []), True

    monkeypatch.setattr(scan, "wait_events", wait)
    try:
        with pytest.raises(BuildError) as error:
            scan.scan_zip(
                str(path),
                "scanner",
                lambda *a, **k: result(
                    "found 1 threats" if threat else "found no threats"
                ),
            )
        assert "Cannot remove temporary scan folder" in str(error.value)
        assert folders[0] in str(error.value)
        assert ("found threats" in str(error.value)) is threat
        assert path.exists()
    finally:
        for folder in folders:
            real_remove(folder)


def test_extraction_detection_is_included_before_scan(monkeypatch, tmp_path):
    path = tmp_path / "payload.zip"
    payload(path)
    base = datetime.datetime(2026, 10, 16, 12, tzinfo=datetime.UTC)
    now = [base]

    class Clock(datetime.datetime):
        @classmethod
        def now(cls, tz=None):
            return now[0]

    monkeypatch.setattr(scan.datetime, "datetime", Clock)
    monkeypatch.setattr(scan, "long_path", lambda path: path)
    original_extract = scan.extract_payload

    def extract(*args):
        original_extract(*args)
        now[0] += datetime.timedelta(seconds=10)

    monkeypatch.setattr(scan, "extract_payload", extract)

    def read(start, run):
        assert start <= base
        folder = folders[0]
        return [
            event(1000, f"{SCAN_ID} {folder}"),
            event(1001, SCAN_ID, 10),
            event(1116, folder, 1),
            event(1117, folder, 2),
        ]

    monkeypatch.setattr(scan, "read_events", read)
    folders = []

    def run(args, **kwargs):
        folders.append(args[-1])
        return result("found no threats")

    with pytest.raises(BuildError, match="disagree"):
        scan.scan_zip(str(path), "scanner", run)
    evidence = Path(str(path) + ".scan.txt").read_text(encoding="utf-8")
    assert "Event ID: 1116" in evidence
    assert "Event ID: 1117" in evidence
    assert not os.path.exists(folders[0])


def test_evidence_failure_preserves_original_failure_and_cleans_up(
    monkeypatch, tmp_path
):
    path = tmp_path / "payload.zip"
    payload(path)
    folders = []

    def long(path):
        folders.append(path)
        return path

    monkeypatch.setattr(scan, "long_path", long)
    monkeypatch.setattr(scan, "read_events", lambda *a: [])

    def fail_extract(*args):
        raise BuildError("original extraction error")

    def fail_write(*args):
        raise OSError("disk full")

    monkeypatch.setattr(scan, "extract_payload", fail_extract)
    monkeypatch.setattr(scan, "write_evidence", fail_write)
    with pytest.raises(BuildError) as error:
        scan.scan_zip(str(path), "scanner")
    assert "original extraction error" in str(error.value)
    assert "Cannot write scan record" in str(error.value)
    assert "disk full" in str(error.value)
    assert not os.path.exists(folders[0])


def test_extraction_failure_collects_detection_evidence(monkeypatch, tmp_path):
    path = tmp_path / "payload.zip"
    payload(path)
    folders = []

    def long(path):
        folders.append(path)
        return path

    monkeypatch.setattr(scan, "long_path", long)

    def extract(*args):
        raise PermissionError("extracted file was locked")

    def read(*args):
        return [
            event(1116, folders[0]),
            event(1117, folders[0], 1),
            event(1116, "unrelated path"),
        ]

    monkeypatch.setattr(scan, "extract_payload", extract)
    monkeypatch.setattr(scan, "read_events", read)
    with pytest.raises(BuildError, match="extracted file was locked"):
        scan.scan_zip(str(path), "scanner")
    evidence = Path(str(path) + ".scan.txt").read_text(encoding="utf-8")
    assert "Event ID: 1116" in evidence
    assert "Event ID: 1117" in evidence
    assert "unrelated path" not in evidence
    assert not os.path.exists(folders[0])


def test_nonzero_exit_precedes_incomplete_event_timeout():
    with pytest.raises(BuildError, match="code 2"):
        scan.validate_result(2, "", [], complete=False)
