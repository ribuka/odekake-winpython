# WinPython Offline Bundle Automation — Work Handoff

## Metadata

- SOURCE_CHAT_DATE: `2026-10-05T21:56:00+09:00`
- Handoff created: `2026-10-05T22:13:45+09:00`
- Platform: Windows
- Shell: PowerShell
- Python dependency workflow: `uv`
- Purpose: automate creation of a Python environment that can be carried into an offline Windows environment

---

## Goal

Implement a repository-local PowerShell build script that automates the current manual process for creating an offline-portable Python environment based on WinPython.

The desired operator experience is roughly:

```powershell
.\scripts\build-offline.ps1
```

and the build should produce a portable archive under `dist/`.

Example:

```text
dist/
└─ <project>-winpython.zip
```

A SHA256 sidecar may be added later, but it is **not a current requirement**.

---

## Background / Current Manual Procedure

The current procedure is already known to work:

1. Generate `requirements.txt` from `pyproject.toml` / the locked dependency state.
2. Download the smallest appropriate WinPython distribution.
3. Extract WinPython.
4. Run `pip install -r requirements.txt` using the Python inside the extracted WinPython.
5. Re-compress the completed WinPython environment.
6. Carry the archive into an offline Windows environment.
7. Extract and run without downloading packages or installing system Python.

The automation should preserve this workflow rather than redesign it unnecessarily.

---

## Core Design Decision

Do **not** over-engineer this into a wheelhouse / installer / multi-component distribution unless the target repository actually requires it.

Preferred architecture:

```text
pyproject.toml + uv.lock
        │
        ▼
requirements.txt
        │
        ▼
WinPython minimal/slim
        │
        ▼
pip install dependencies into WinPython
        │
        ▼
optional smoke test
        │
        ▼
ZIP
```

The intended artifact is a **fully populated WinPython directory** that can be extracted and used offline.

This is intentionally simpler than solutions that carry wheels separately and run `pip --no-index` on the offline machine.

---

## Public Reference Investigated

Reference repository:

- `ReSerendipity/TTS-MultiModel`
- `scripts/build_portable_bundle.ps1`
- `scripts/unpack_portable_bundle.ps1`

Repository:
https://github.com/ReSerendipity/TTS-MultiModel

Useful ideas from it:

- WinPython version and URL pinning
- automatic WinPython download
- reproducible offline packaging
- integrity checking
- offline installation validation
- explicit handling of large packages

However, **do not copy its architecture wholesale**.

That project separates:

- WinPython + normal dependencies
- PyTorch wheels
- model files

and performs some offline installation after unpacking. That complexity exists because it handles very large Torch/model payloads and release distribution.

For the current use case, the existing simpler workflow is preferred.

---

## Implementation Requirements

Create a script such as:

```text
scripts/build-offline.ps1
```

### 1. Resolve repository root

The script must work regardless of the caller's current working directory.

Use `$PSScriptRoot` to resolve the repository root.

Do not depend on the user launching the script from the repo root.

### 2. Dependency export

Use the project's locked dependency state.

Preferred source of truth:

```text
uv.lock
```

Generate a requirements file with `uv export`.

Conceptually:

```powershell
uv export `
    --frozen `
    --no-dev `
    --format requirements-txt `
    --output-file <temporary requirements file>
```

Confirm the exact currently supported `uv export` CLI syntax before finalizing the implementation.

Do not use `pip freeze` from the developer's `.venv` as the source of truth.

If the repository intentionally needs development dependencies in the offline environment, make this behavior configurable rather than silently including them.

### 3. WinPython version pinning

Pin a specific WinPython release.

Do not dynamically use "latest" without an explicit reason.

Prefer the smallest WinPython flavor that provides:

- the required Python version
- pip
- standard Python runtime
- no unnecessary scientific/IDE packages if avoidable

Keep configuration near the top of the script, for example:

```powershell
$WinPythonVersion = "..."
$WinPythonUrl = "..."
```

If useful, allow parameters such as:

```powershell
param(
    [string]$OutputDir = "...",
    [switch]$Force
)
```

but avoid unnecessary configuration surface.

### 4. Download cache

Avoid downloading WinPython every build.

Suggested layout:

```text
.build/
├─ downloads/
│  └─ <WinPython installer/archive>
└─ offline/
   └─ <temporary extracted environment>
```

or equivalent.

The build/temp directory must be git-ignored.

If the pinned WinPython archive is already present, reuse it unless `-Force` or similar is specified.

### 5. Extract WinPython

Automate extraction.

Avoid requiring a globally installed WinPython.

Prefer tools already available on supported Windows systems where practical.

If the WinPython release is a self-extracting executable, use its unattended extraction mechanism if reliable.

Do not hard-code the generated `WPy...` directory name if it can be discovered safely after extraction.

Normalize the working runtime directory to a predictable build path if that simplifies subsequent operations.

### 6. Install dependencies into WinPython

Locate the actual WinPython `python.exe` and run:

```powershell
& $PythonExe -m pip install -r $RequirementsFile
```

Important:

- never rely on `pip.exe` found through the host `PATH`
- always invoke pip as `<WinPython python.exe> -m pip`
- fail immediately on non-zero exit codes

Consider upgrading pip only if there is a concrete need. Avoid changing packaging tools gratuitously.

### 7. Project installation decision

Determine whether the target repo itself must be installed into the portable environment.

Two possible patterns:

#### A. Source remains outside WinPython

```text
package/
├─ runtime/     # WinPython
└─ project/     # repository/application files
```

Then launch with the portable Python.

#### B. Project is installed into WinPython

For example:

```powershell
& $PythonExe -m pip install <repo>
```

or editable/non-editable equivalent.

Do not assume one without inspecting the repository structure and current launch method.

Prefer the simplest arrangement that preserves current application behavior.

### 8. Smoke test

After installation, run at least one offline-safe validation using the WinPython interpreter.

At minimum:

```powershell
& $PythonExe --version
& $PythonExe -m pip check
```

Additionally, if the application has a safe import target:

```powershell
& $PythonExe -c "import <main_package>"
```

Use the repository's actual package/module name.

Avoid tests that require network access.

### 9. Remove avoidable build residue

Before compression, consider removing:

- pip download cache
- temporary requirements file
- build-only files
- `__pycache__` only if there is a reason to reduce size

Do not aggressively delete files inside WinPython unless their role is understood.

Correctness and portability are more important than squeezing the final archive.

### 10. Compression

Create the final archive automatically under:

```text
dist/
```

Preferred naming:

```text
<project>-winpython-<version>.zip
```

or a similarly deterministic name.

If the repository already has a project version in `pyproject.toml`, reuse it.

The archive should contain everything needed for offline execution.

The offline machine should **not** need:

- internet access
- system Python
- `uv`
- `pip install` from PyPI

unless explicitly decided otherwise.

---

## Out of Scope for Initial Implementation

Do not implement these unless the repository actually needs them:

- separate wheelhouse distribution
- `pip --no-index --find-links` installation on the offline PC
- GitHub Release publishing
- multi-part archives
- Torch-specific dependency handling
- model-file component splitting
- custom installer GUI
- system-wide Python registration
- automatic PATH modification
- code signing
- SHA256 sidecar generation

These can be added later if requirements emerge.

---

## Important Portability Concern

A copied `.venv` is not the intended solution.

The purpose of WinPython is to provide a portable Python distribution suitable for relocation between machines/directories.

Nevertheless, verify that installed console scripts / entry points continue to work after moving the completed environment.

If relocation breaks generated launchers or shebangs, investigate WinPython/wppm portability helpers such as movable/fix behavior rather than adding brittle path-rewrite code blindly.

---

## Expected Script Qualities

The PowerShell implementation should be:

- idempotent where practical
- fail-fast
- readable
- repository-local
- minimally configurable
- free from unnecessary abstraction
- safe to rerun
- explicit about what is being downloaded and where
- independent of the developer's active `.venv`

Use:

```powershell
$ErrorActionPreference = 'Stop'
```

and explicitly check native command exit codes where PowerShell would otherwise continue.

---

## Suggested Build Flow

```text
build-offline.ps1
    │
    ├─ validate uv / pyproject.toml / uv.lock
    │
    ├─ derive project/version metadata
    │
    ├─ uv export -> temporary requirements.txt
    │
    ├─ download pinned WinPython if cache miss
    │
    ├─ extract to clean staging directory
    │
    ├─ discover WinPython python.exe
    │
    ├─ python -m pip install -r requirements.txt
    │
    ├─ optionally install/copy project
    │
    ├─ python -m pip check
    │
    ├─ application import smoke test
    │
    └─ compress -> dist/<artifact>.zip
```

---

## Acceptance Criteria

The task is complete when:

1. One PowerShell command builds the offline package from a clean checkout.
2. The build does not depend on the repository's existing `.venv`.
3. The Python runtime inside the package is WinPython.
4. Dependencies come from the project's locked dependency state.
5. Build failure is surfaced clearly.
6. The generated archive can be copied to another Windows machine.
7. After extraction on a machine with no internet and no system Python, the intended application/import path works using the bundled WinPython.
8. Re-running the build does not require redownloading WinPython unless necessary.
9. Temporary files are not accidentally committed to Git.

---

## First Actions for the Coding Agent

Before editing:

1. Inspect the target repository's:
   - `pyproject.toml`
   - `uv.lock`
   - `.gitignore`
   - package/source layout
   - current entry point / launcher
   - supported Python version
2. Determine whether the repo source should be copied alongside WinPython or installed into it.
3. Check the current minimal WinPython release appropriate for that Python version.
4. Implement the smallest `build-offline.ps1` satisfying the acceptance criteria.
5. Run the build locally.
6. Test the artifact from a different extraction path to catch relocation issues.
7. Report:
   - produced artifact path
   - artifact size
   - bundled Python version
   - `pip check` result
   - smoke-test result
   - any unresolved portability issue

---

## Guiding Principle

The existing manual workflow is already valid.

The goal is **automation and reproducibility**, not redesign.

Prefer:

> automate the known-good manual process

over:

> invent a generalized offline Python packaging framework
