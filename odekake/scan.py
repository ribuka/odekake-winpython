"""Microsoft Defender scanning and unmodified scan evidence."""

import ctypes
import datetime
import json
import os
import re
import subprocess
import tempfile
import time
import zipfile

from odekake import BuildError, remove_tree
from odekake import zip as ziputil

GUID = re.compile(r"\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}")


def powershell(script, run=subprocess.run):
    """Runs Windows PowerShell and returns UTF-8 output."""
    result = run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); "
            "$ErrorActionPreference = 'Stop'; " + script,
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode:
        raise BuildError(f"Defender PowerShell command failed: {result.stderr}")
    return result.stdout


def check_defender(run=subprocess.run):
    """Checks Defender before the build and returns the scanner executable."""
    try:
        status = json.loads(
            powershell(
                "Get-MpComputerStatus | Select-Object AMRunningMode,AntivirusEnabled | ConvertTo-Json",
                run,
            )
        )
    except (OSError, ValueError) as error:
        raise BuildError(f"Cannot query Microsoft Defender status: {error}") from error
    if not isinstance(status, dict):
        raise BuildError("Microsoft Defender returned an invalid status object.")
    if (
        status.get("AMRunningMode") != "Normal"
        or status.get("AntivirusEnabled") is not True
    ):
        raise BuildError(
            "Microsoft Defender must be running in Normal mode with AntivirusEnabled true."
        )
    scanner = os.path.join(
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        "Windows Defender",
        "MpCmdRun.exe",
    )
    if not os.path.isfile(scanner):
        raise BuildError(f"Microsoft Defender scanner not found: {scanner}")
    return scanner


def long_path(path):
    """Expands short Windows path components before matching event messages."""
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetLongPathNameW.argtypes = [
        ctypes.c_wchar_p,
        ctypes.c_wchar_p,
        ctypes.c_uint32,
    ]
    kernel.GetLongPathNameW.restype = ctypes.c_uint32
    size = kernel.GetLongPathNameW(path, None, 0)
    if not size:
        raise ctypes.WinError(ctypes.get_last_error())
    buffer = ctypes.create_unicode_buffer(size)
    if not kernel.GetLongPathNameW(path, buffer, size):
        raise ctypes.WinError(ctypes.get_last_error())
    return buffer.value


def read_events(start, run=subprocess.run):
    """Reads event messages without changing their contents."""
    stamp = start.isoformat().replace("'", "''")
    output = powershell(
        "$events = @(Get-WinEvent -FilterHashtable @{"
        "LogName='Microsoft-Windows-Windows Defender/Operational';"
        "Id=1000,1001,1002,1005,1116,1117;"
        f"StartTime=[datetime]::Parse('{stamp}')}} -ErrorAction SilentlyContinue "
        "-ErrorVariable eventErrors); "
        "foreach ($e in $eventErrors) { if ($e.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw $e } }; "
        "$events | Select-Object Id,@{n='TimeCreated';e={$_.TimeCreated.ToString('o')}},Message | ConvertTo-Json -Depth 3",
        run,
    )
    data = json.loads(output) if output.strip() else []
    return data if isinstance(data, list) else [data]


def select_events(events, folder):
    """Correlates starts and terminal events by scan GUID, detections by path."""
    starts = [
        e
        for e in events
        if e["Id"] == 1000 and folder.casefold() in (e["Message"] or "").casefold()
    ]
    ids = set()
    for event in starts:
        match = GUID.search(event["Message"])
        if match:
            ids.add(match.group().casefold())
    selected = [
        e
        for e in events
        if e in starts
        or (
            e["Id"] in (1001, 1002, 1005)
            and any(g in (e["Message"] or "").casefold() for g in ids)
        )
        or (
            e["Id"] in (1116, 1117)
            and folder.casefold() in (e["Message"] or "").casefold()
        )
    ]
    return sorted(selected, key=lambda e: e["TimeCreated"])


def threat_count(stdout):
    """Requires the scanner's explicit threat count."""
    counts = re.findall(r"found (\d+|no) threats", stdout)
    if not counts:
        raise BuildError("Defender output has no recognizable threat count.")
    return max(0 if count == "no" else int(count) for count in counts)


def validate_result(returncode, stdout, events):
    """Rejects threats, incomplete scans, and conflicting evidence."""
    if any(e["Id"] == 1000 and not GUID.search(e["Message"]) for e in events):
        raise BuildError("Defender start event has no scan GUID.")
    threats = threat_count(stdout) > 0
    detected = any(e["Id"] in (1116, 1117) for e in events)
    if returncode:
        raise BuildError(f"Defender exited with code {returncode}.")
    if any(e["Id"] in (1002, 1005) for e in events):
        raise BuildError("Defender scan was interrupted or failed.")
    if threats != detected:
        raise BuildError("Defender events and standard output disagree about threats.")
    if threats:
        raise BuildError("Microsoft Defender found threats.")
    if not any(e["Id"] == 1000 for e in events) or not any(
        e["Id"] == 1001 for e in events
    ):
        raise BuildError("Defender scan evidence is incomplete.")


def wait_events(
    start,
    folder,
    run=subprocess.run,
    monotonic=time.monotonic,
    sleep=time.sleep,
    collected=None,
):
    """Waits up to sixty seconds for completion and delayed remediation."""
    deadline = monotonic() + 60
    while True:
        events = select_events(read_events(start, run), folder)
        if collected is not None:
            collected[:] = events
        if any(e["Id"] == 1000 and not GUID.search(e["Message"]) for e in events):
            raise BuildError("Defender start event has no scan GUID.")
        terminal = any(e["Id"] in (1001, 1002, 1005) for e in events)
        detection = any(e["Id"] == 1116 for e in events)
        remediation = any(e["Id"] == 1117 for e in events)
        if terminal and (not detection or remediation):
            return events, True
        if monotonic() >= deadline:
            return events, False
        sleep(2)


def write_evidence(path, stdout, events):
    """Writes only scanner output, event separators, and raw event messages."""
    text = stdout
    for event in events:
        if text and not text.endswith(("\n", "\r")):
            text += "\n"
        text += f"Event ID: {event['Id']} TimeCreated: {event['TimeCreated']}\n{event['Message']}"
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\r\n")
    with open(path, "w", encoding="utf-8", newline="") as stream:
        stream.write(text)


def extract_payload(zip_path, folder, run=subprocess.run):
    """Expands the payload and removes the nested runtime archive."""
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(folder)
    archives = [
        os.path.join(folder, name)
        for name in ("winpython.zip", "winpython.7z")
        if os.path.isfile(os.path.join(folder, name))
    ]
    if len(archives) != 1:
        raise BuildError("Expected exactly one WinPython archive in the outer ZIP.")
    nested = archives[0]
    runtime = os.path.join(folder, "winpython")
    os.makedirs(runtime, exist_ok=True)
    if nested.endswith(".zip"):
        with zipfile.ZipFile(nested) as archive:
            archive.extractall(runtime)
    else:
        result = run(
            [ziputil.get_system_tar_path(), "-xf", nested, "-C", runtime],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode:
            raise BuildError(f"Cannot extract WinPython 7z: {result.stderr}")
    os.remove(nested)


def scan_zip(zip_path, scanner, run=subprocess.run):
    """Scans an extracted ZIP, retaining evidence and the original on failure."""
    evidence = zip_path + ".scan.txt"
    folder = None
    stdout = ""
    events = []
    try:
        try:
            folder = tempfile.mkdtemp(
                prefix=f"odekake-scan-{os.path.splitext(os.path.basename(zip_path))[0]}-"
            )
            folder = long_path(folder)
            extract_payload(zip_path, folder, run)
            start = datetime.datetime.now().astimezone() - datetime.timedelta(seconds=5)
            result = run(
                [scanner, "-Scan", "-ScanType", "3", "-File", folder],
                capture_output=True,
                encoding="utf-8",
                errors="replace",
            )
            stdout = result.stdout
            events, complete = wait_events(start, folder, run, collected=events)
            write_evidence(evidence, stdout, events)
            if not complete:
                raise BuildError("Timed out waiting for Defender scan events.")
            validate_result(result.returncode, stdout, events)
        finally:
            try:
                write_evidence(evidence, stdout, events)
            finally:
                if folder is not None:
                    remove_tree(folder)
    except Exception as error:
        retained = (
            "Outer ZIP retained"
            if os.path.isfile(zip_path)
            else "Outer ZIP is missing (possibly quarantined)"
        )
        raise BuildError(
            f"Defender scan failed: {error}\nScan record: {evidence}\n{retained}: {zip_path}"
        ) from error
    return evidence
