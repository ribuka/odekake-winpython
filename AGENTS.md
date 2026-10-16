# odekake-winpython

A general-purpose Python script (Windows only) that packages any uv project into a ZIP, based on WinPython, for carrying it into an offline Windows environment.

- Always respond in Japanese.
- `docs/spec.md` holds design decisions (with their reasons) and verified facts. Read the relevant sections before changing code.

## Repository layout

- `build_offline.py` / `build-offline.bat`: Entry points. The `.bat` launches the script with `uv run`.
- `odekake/*.py`: Implementation modules (settings, project inspection, WinPython, ZIP, logging, GUI).
- `pyproject.toml` / `uv.lock`: The tool's own Python requirement and dependencies (runtime: loguru; dev: pytest, ruff).
- `config/settings.toml`: Shared default settings. Per-user overrides go in `config/settings.local.toml` (gitignored).
- `tests/test_*.py`: pytest unit tests.
- `.github/workflows/ci.yml`: CI (ruff check and pytest on Ubuntu) for pull requests.
- `docs/spec.md`: Design notes. Open issues and pending ideas are GitHub issues.
- `VERSION`: Release version. Pushing a change to it on `main` triggers the release workflow.

## Coding

- Do not add runtime dependencies other than loguru, and keep the code working on Python 3.11 and later.
- Run `uv run ruff check` and `uv run ruff format --check` before committing. Keep ruff's default rules.
- Run `uv run pytest` after changing `build_offline.py` or `odekake/*.py`, and add or update tests for the changed behavior. The tests must not require network access.
- CI runs the tests on Ubuntu. Mark tests that need Windows (tar.exe, Windows paths, tkinter dialogs, running python.exe) with `pytest.mark.skipif(sys.platform != "win32", ...)`; write the rest to pass on Ubuntu too.
- Write user-facing text (log output, console messages, exception messages, GUI text), code comments, docstrings, argument help, and test names in English.
- `README.md` and `docs/spec.md` are written in Japanese. Keep them in Japanese.

## Working with the spec

- `docs/spec.md` records only what the code and tests cannot tell: why a design was chosen (including rejected alternatives) and facts verified by investigation. Do not restate behavior that the code, tests, or README already describe.
  - User-facing usage, options, and settings belong in `README.md`.
  - Work plans, build/verification logs, and discussion history belong in issues and pull requests.
- Status markers in `docs/spec.md`:
  - **(推測)** / **(未検証)**: Not backed by evidence.
  - **(未決定)**: Awaiting the user's decision. NEVER settle these on your own.
  - Statements without a marker are decided or verified.
- For items marked "実装時に提案すること" (to be proposed during implementation), present a proposal and get approval before implementing it.
- When a change involves a new design decision or a newly verified fact, add it to `docs/spec.md`. Mark facts verified on a real machine with the date.

## Collaboration

- Act as an equal, critical technical partner. Point out problems with assumptions or design candidly instead of going along with them.
- Clearly separate guesses from verified facts.

## GitHub

### Commit

- Before creating a commit, read `.agents/docs/commit.md` and follow it.
- Before committing, check that no personal information is included: user names, email addresses, local paths (e.g. `C:\Users\...`), machine names, or tokens.
- NEVER put personal paths in `config/settings.toml`; use `config/settings.local.toml` instead.

### Pull request

- When creating a pull request, read `.agents/docs/pull-request.md` and follow it.

## Temporary files

- Create all temporary scripts and investigation files under `tmp/` at the repository root (gitignored).
- NEVER create temporary files elsewhere; delete them when the task is complete.
