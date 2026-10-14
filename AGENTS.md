# odekake-winpython

A general-purpose PowerShell script that packages any uv project into a ZIP, based on WinPython, for carrying it into an offline Windows environment.

- Always respond in Japanese.
- `docs/spec.md` holds design decisions (with their reasons) and verified facts. Read the relevant sections before changing code.

## Repository layout

- `build-offline.ps1` / `build-offline.bat`: Entry points. The `.bat` launches the script with Windows PowerShell 5.1.
- `lib/*.ps1`: Implementation modules (settings, project inspection, WinPython, ZIP, logging, GUI).
- `config/settings.json`: Shared default settings. Per-user overrides go in `config/settings.local.json` (gitignored).
- `tests/*.Tests.ps1`: Pester 5 unit tests.
- `docs/spec.md`: Design notes. Open issues and pending ideas are GitHub issues.
- `VERSION`: Release version. Pushing a change to it on `main` triggers the release workflow.

## Coding

- The script must work on both Windows PowerShell 5.1 and PowerShell 7.
- Run `Invoke-Pester tests` after changing `lib/*.ps1`, and add or update tests for the changed behavior. The tests must not require network access.
- Write user-facing text (log output, console messages, exception messages, GUI text), code comments, script help, and Pester `Context` / `It` names in English.
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
- NEVER put personal paths in `config/settings.json`; use `config/settings.local.json` instead.

### Pull request

- When creating a pull request, read `.agents/docs/pull-request.md` and follow it.

## Temporary files

- Create all temporary scripts and investigation files under `tmp/` at the repository root (gitignored).
- NEVER create temporary files elsewhere; delete them when the task is complete.
