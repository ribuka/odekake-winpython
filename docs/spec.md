# odekake-winpython 仕様(2026-10-06 確定版)

元の要件定義(リポジトリ外)を、2026-10-05〜06 の検討で改めたもの。
旧 docs/handoff-addendum.md を整理し直したもので、検討の経緯は git 履歴を参照。

表記:
- **(確定)** はユーザー承認済み。
- **(推測)** **(未検証)** は裏付けがない。
- **(未決定)** はユーザーの判断待ち。勝手に確定しない。

---

## 1. 目的とスコープ

- 任意の uv プロジェクトを、オフラインの Windows 環境へ持ち出すための ZIP にする汎用 PowerShell スクリプト。特定リポジトリ専用ではない。(確定)
- スクリプトはこのリポジトリ(odekake-winpython)に置く。対象プロジェクトはスクリプトの外にある。(確定)
- 用語:
  - **対象プロジェクト**: ZIP にする uv プロジェクト。pyproject.toml と uv.lock があるフォルダ。
  - **このリポジトリ**: odekake-winpython。

## 2. 成果物の構成(確定)

開発時の `.venv` を WinPython に置き換えるイメージ。自分のコードは WinPython にインストールしない。

```
<name>-<version>_yyyymmddTHHmmss.zip      ← 外側 ZIP(持ち出し申請の対象。1ファイル)
├─ winpython.zip   ← WinPython + 依存ライブラリ。自分のコードは含まない(winPythonArchiveFormat が 7z なら winpython.7z。§16)
├─ src\            ← 自分のコード(ファイルのまま。搬入先で編集する可能性あり)
├─ pages\
└─ (その他、対象プロジェクトの gitignore されていないファイル。export-ignore のものを除く)
```

- **winpython.zip を二重にする理由**: ファイル数の多いランタイムを1ファイルで運ぶため。依存が近い別プロジェクトで流用する可能性もある。
- **winpython.zip の中身**: WinPython 配布物の最上位フォルダ(`WPy64-313150` などバージョン由来の名前)を取り除いて詰め直す。展開すると直接 `python\`, `scripts\` ... が出てくる。
- **搬入先での規約**: winpython.zip(または winpython.7z)は `<project>\winpython\` に展開する。フォルダ名は小文字の `winpython`。
  - `.venv` という名前は使わない。uv が壊れた venv とみなして作り直す恐れがある。(推測)
- **自分のコードの import**:
  - 対象プロジェクトは `[build-system]`(hatchling 等)を持ち、開発時は uv が自分のコードを editable インストールしている前提。
  - 自分のコードはインストールしない。代わりに `winpython\python\Lib\site-packages\` に `.pth` ファイルを1つ置き、中身を `..\..\..\..\src` にする。
  - 2026-10-06 に実機で確認済み: 新規作成した import 確認用パッケージを `src\` に置いて import でき、フォルダごと移設した後も import できた。
  - 同じ規約(`<project>\winpython\` + `<project>\src\`)を守るプロジェクト間なら、`.pth` は共通で使える。
  - `.pth` のファイル名は `odekake-src.pth`。(確定)
- **外側 ZIP に入れるファイル**:
  - 既定は、gitignore されていない全ファイル(未 add のファイルを含む。`git ls-files --cached --others --exclude-standard` 相当)。(確定)
  - `trackedOnly` で、add 済みのファイルだけに切り替えられる。(確定)
  - `exclude` で、指定したパターンに当たるファイルを除外できる。(確定)
  - 既定で、対象プロジェクトの `.gitattributes` で `export-ignore` が付いたファイルを除外する(`git archive` と同じ考え方)。`includeExportIgnored` を true にすると含める。(確定、issue #12)
    - フォルダに付いた `export-ignore`(`/tests/ export-ignore` など)は、中のファイルすべてに効く。
    - `.gitattributes` は作業ツリーのものを読む(`git archive` の既定はコミット済みのもの)。未 add のファイルも ZIP に入れるため。
    - 0.1.1 までは export-ignore のファイルも含めていた。既定の挙動が変わる。
    - 既知の制限: 文字列値の `export-ignore=set`(`=SET` なども)は、真偽値の Set と区別できずに除外される。`git archive` は除外しない。`git check-attr` がどちらも `set` と出力し、フォルダに付いた属性を真偽値として問い合わせる手段がほかにないため。まず書かれない記法なので、直さない(確定、2026-10-06、PR #14 のレビュー)。
- **外側 ZIP の最上位**: フォルダを挟まず、ZIP 直下にファイルを置く(上の図のとおり)。(確定)
- **起動用 .bat**: 対象アプリを起動する .bat は生成しない。起動方法はユーザーが搬入先で自分で整える。(確定)

## 3. 対象プロジェクトの指定(確定)

- `-ProjectRoot` が指定されていれば、それを使う。
- 指定がなければ、フォルダ選択ダイアログ(.NET `FolderBrowserDialog`)を出す。キャンセルしたら何もせず終了する。
- GUI はフォルダ選択だけ。その他の設定は設定ファイルと引数で行う。
- pyproject.toml または uv.lock がなければエラー。
- 対象が git リポジトリでない場合は、エラーにする(ファイル収集に git を使うため)。(確定)

## 4. ビルドの流れ

1. ビルド開始時刻を1回だけ取得する。ZIP 名とログ名の両方に同じ値を使う。
2. 設定を読む(§8)。対象プロジェクトを決める(§3)。
3. pyproject.toml から name と version を読む(§6)。Python バージョンを決める(§5)。
4. 依存を書き出す: `uv export --frozen --no-emit-project --no-default-groups [--group X ...] [--extra Y ...] --format requirements-txt -o <tmp>`
   - pyproject の `default-groups` は無視し、`groups` に指定したものだけを含める。既定では dev も含めない。
   - `installer` が uv でも行う。WinPython のダウンロード前に lock の不備に気づくためと、入れる依存をログに残すため(ハッシュの行は省いてログに書く)。(確定、2026-10-06)
   - `installer` が pip のときは、ここで PyPI 以外の index から取る依存がないかを確かめ、あればエラーで止める(§15)。
5. WinPython を用意する: `.build\` にキャッシュする。期待 SHA-256 と一致しなければ、自動でダウンロードし直す。`-Force` は設けない。
6. `.build\` の作業用フォルダに、搬入先と同じ配置(`<project>\winpython\` + `src\` …)で組み立てる。
7. 依存を WinPython に入れる。方法は `installer`(§8、§15)で選ぶ。
   - uv(既定): `UV_PROJECT_ENVIRONMENT=<winpython\python>` にして `uv sync --frozen --inexact --no-install-project --no-default-groups [--group X ...] [--extra Y ...] --python <winpython\python\python.exe> --link-mode copy --no-editable` を実行する。
   - pip: `winpython\python\python.exe -m pip install -r <tmp>` を実行する。host の pip には頼らない。
8. `.pth` を置く。
9. 動作確認(毎回実行し、失敗したらビルドも失敗):
   - `python --version`
   - `python -m pip check`
   - `python -c "import <importName>"`(`.pth` の検証も兼ねる)
10. `pruneWinPython` が有効なら、不要なランチャー等を削除する(§8)。
11. winpython.zip(または winpython.7z。§16)を作る。対象プロジェクトのファイルを集め、外側 ZIP を作る。
12. 外側 ZIP の SHA-256 を計算し、画面とログに出す。
13. 結果をポップアップで表示する(§9)。

- 一時ファイル(requirements、pip キャッシュ等)は残さない。WinPython 内のファイルは、役割の分からないものは消さない。

## 5. WinPython と Python バージョン(確定)

- 使うのは WinPython の **dot** 版(最小構成)。
- リリースは、対応表の **行ごとに** 固定する。選ぶ規則: その版の dot の .zip があり、SHA-256 を2か所(GitHub API の digest と https://winpython.github.io/md5_sha1.txt)で確かめられる、いちばん新しい安定版リリース。(確定、2026-10-06。以前は全行を 2026-03 リリースで固定していた)
  - 各行は、そのマイナー系の WinPython にある最新のパッチ版を同梱する。`.python-version` が `3.12.2` でも `3.12` の行(3.12.10)を使う。パッチ版そのものの同梱は別の issue で扱う。
  - 3.11 以前は載せない。
- Python バージョンの優先順位は **引数 `-PythonVersion` > `.python-version` > 設定ファイルの `pythonVersion`**。(確定)
  - §8 の「引数 > 設定ファイル > 既定値」の例外。設定ファイルの値は、`.python-version` がないときだけ使う。
  - 引数と `.python-version` のマイナーバージョンが違えば、警告をログに出す。
- マイナーバージョン(3.13 等)で、次の対応表を引く。表にないバージョンはエラーにする。最新版へのフォールバックはしない。
- URL は規則から組み立てず、完全な形で対応表に持つ。タグ名(`17.12.20260522/WinPython`, `16.6.20250620final` など)が、リリース名とも日付とも一致せず、ファイル名の大文字小文字(`WinPython64-` / `Winpython64-`)もリリースで違うため。

| Python | リリース | URL | SHA-256 | サイズ |
|---|---|---|---|---|
| 3.12 (3.12.10) | 2025-03 | https://github.com/winpython/winpython/releases/download/16.6.20250620final/Winpython64-3.12.10.1dot.zip | `7a1f004aec39615977b2b245423a50115530d16af3418df77977186a555d0a40` | 38,519,826 |
| 3.13 (3.13.15) | 2026-03 | https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.13.15.0dot.zip | `28e36408f0140c50b207ea059a599c664564e68a3cbb835f03a71f4601efd8f1` | 28,158,845 |
| 3.14 (3.14.7) | 2026-03 | https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.14.7.0dot.zip | `dbabedfb50eeb3c2c63dc43c9cb6239eae4a582c3bfd9a5f2ffd00a09b49a527` | 28,663,262 |

SHA-256 は、GitHub API の digest と https://winpython.github.io/md5_sha1.txt で一致を確認済み(2026-10-06)。

## 6. 名前・バージョン・出力先(確定)

- **`<name>`**: pyproject の `name` の `_` を `-` に置換したもの(リポジトリのフォルダ名に寄せる)。外側 ZIP 名とログ名の両方に使う。
- **import 確認用の名前**: pyproject の `name` の `-` を `_` に置換したもの。`importName` で上書きできる。
- **`<version>`**: pyproject の `version`。dynamic の場合は `<対象プロジェクト>\VERSION` から読む(1行。前後の空白と改行は除去)。dynamic で VERSION もなければエラー。
- **タイムスタンプ**: `_yyyymmddTHHmmss`(ローカル時刻)を常に付ける。そのため出力の上書きは起きない。
- **出力先**: 既定はユーザーのダウンロードフォルダ。`%USERPROFILE%\Downloads` を決め打ちにせず、Windows の既知フォルダ(Downloads)として場所を取得する(フォルダを移設している環境に対応するため)。`outputDir` で変更できる。

## 7. SHA-256 とログ(確定)

- 外側 ZIP の SHA-256 は、ファイルとしては出力しない。持ち出し申請の対象を1ファイルに保つため。ZIP 自身のハッシュを ZIP 内に入れるのは原理的に不可能。
- SHA-256 は画面に表示し、ログにも記録する。用途は、持ち出し申請の書類に値を記載し、搬入先で `Get-FileHash` と照合すること。
- ZIP の中に各ファイルのハッシュ一覧(SHA256SUMS)は入れない。
- ログ: このリポジトリの `logs\yyyymmddTHHmmss_<name>.log`。SHA-256 に加え、ビルド全体のログを書く。ログは持ち出さない。
- PS 5.1 の Start-Transcript は、外部コマンド(uv, pip)の出力を記録しないことがある。(推測) 外部コマンドの出力は明示的にログへ書き出す。

## 8. 設定(確定)

### 設定ファイル
- 形式は JSON。YAML / TOML は PowerShell に標準のパーサーがないため不採用。psd1 は馴染みがないため不採用。
- 置き場所はこのリポジトリ。対象プロジェクトは汚さない。
  - `config\settings.json`: 全プロジェクト共通。コミットされるので、個人のパスを書かない。
  - `config\settings.local.json`: 個人用。`*.local.json` は gitignore する。
- 優先順位: **引数 > settings.local.json > settings.json > 既定値**。マージはキー単位(書いたキーだけ上書きする)。
- プロジェクトごとの指定(`groups`, `extras`, `exclude` 等)は、引数で渡す。プロジェクト別の設定欄は設けない。
- 未知のキーはエラーにする(打ち間違いの検出のため)。
- 設定ファイル自体がなくても動く。

### 項目
- 設定キーと引数は同じ名前にする(キーは camelCase、引数は PascalCase)。
- 真偽値は、既定が false になる向きで名付ける。PowerShell のスイッチ引数は「付けると true」のため。

| 設定キー | 引数 | 型 | 既定値 / 説明 |
|---|---|---|---|
| (なし) | `-ProjectRoot` | パス | なし → フォルダ選択ダイアログ |
| (なし) | `-ConfigPath` | パス | `config\settings.json`(同じフォルダの `settings.local.json` も読む) |
| `pythonVersion` | `-PythonVersion` | 文字列 | `.python-version` の値。優先順位は §5 |
| `outputDir` | `-OutputDir` | パス | ダウンロードフォルダ |
| `trackedOnly` | `-TrackedOnly` | 真偽値 | false(未 add のファイルも含める) |
| `includeExportIgnored` | `-IncludeExportIgnored` | 真偽値 | false(`.gitattributes` で `export-ignore` のファイルは含めない。§2) |
| `groups` | `-Groups` | 文字列の配列 | 空(dev も含めない) |
| `extras` | `-Extras` | 文字列の配列 | 空 |
| `exclude` | `-Exclude` | 文字列の配列 | 空。外側 ZIP から除外するパターン |
| `pruneWinPython` | `-PruneWinPython` | 真偽値 | false(`config\settings.json` で true にしている) |
| `importName` | `-ImportName` | 文字列 | pyproject の `name`(`-` → `_`) |
| `installer` | `-Installer` | `"uv"` / `"pip"` | `"uv"`。依存を入れる方法(§15)。ほかの値はエラー(大文字小文字も区別する) |
| `winPythonArchiveFormat` | `-WinPythonArchiveFormat` | `"zip"` / `"7z"` | `"zip"`。外側 ZIP に入れる WinPython のアーカイブの形式(§16)。ほかの値はエラー(大文字小文字も区別する) |
| `noPopup` | `-NoPopup` | 真偽値 | false |
| `initialDir` | (なし) | パス | なし(初期位置を指定しない)。フォルダ選択ダイアログの初期位置 |

- `projectRoot` と `configPath` は設定キーにしない。設定ファイルの場所がそれらで決まるため。
- `initialDir` は、フォルダ選択ダイアログ(`-ProjectRoot` を省略したとき)の初期位置。(確定、2026-10-06)
  - 個人のパスになるので、`settings.local.json` に書く。
  - 引数は設けない。引数で指定するなら `-ProjectRoot` を使えばよいため。
  - 環境変数(`%USERPROFILE%` など)は展開する。
  - 相対パスはエラーにする(.bat から起動すると基準が分かりにくいため)。展開できなかった環境変数が残って相対パスになった場合も同じ。
  - フォルダがなければ、ログに警告を出し、初期位置を指定せずにダイアログを開く。
  - ダイアログには、`InitialDirectory` があれば(.NET 8 以降、PS 7)それを、なければ(.NET Framework、PS 5.1)`SelectedPath` を設定する。PS 7 で `SelectedPath` を使うと、指定したフォルダではなく親フォルダが開く(WinForms のソース `FolderBrowserDialog.cs` で確認。目視は未確認)。PS 5.1 はツリーがそのフォルダまで展開される。
- `exclude` は git pathspec(glob)の書式で書き、`:(exclude,glob)<パターン>` として git に渡す。対象プロジェクトの最上位からの相対パスで書く。(確定)
  - 例: `docs/**`, `**/*.log`, `tests`(フォルダごと)。
  - .gitignore と違い、`*.log` は最上位のファイルにしか当たらない。どの階層にも当てるなら `**/*.log`。
- `pruneWinPython` は、スクリプトの既定値は false のまま、コミットする `config\settings.json` で true にする。これで通常は削除される。(確定、2026-10-06)
  - 残したいときは、`settings.local.json` に `"pruneWinPython": false` と書く。
  - 引数 `-PruneWinPython:$false` は、PowerShell から ps1 を直接呼ぶときだけ使える。.bat 経由(`powershell.exe -File`)では `$false` が文字列として渡り、エラーになる(2026-10-06 確認)。
  - 目的は、容量削減ではなく、展開時に目に入るノイズを減らすこと。対象は WinPython 最上位の階層だけ。
  - 削除する: `Jupyter Lab.exe`, `Jupyter Notebook.exe`, `Spyder.exe`, `Spyder reset.exe`, `VS Code.exe`, `notebooks\`, `wheelhouse\`
  - 残す: `IDLE (Python GUI).exe`, `WinPython Command Prompt.exe`, `WinPython Powershell Prompt.exe`, `WinPython Interpreter.exe`, `WinPython Control Panel.exe`, `license.txt`, `python\`, `scripts\`

例(`config\settings.local.json`):
```json
{
  "outputDir": "D:\\export",
  "trackedOnly": true
}
```

## 9. 実行方法と UI(確定)

- PowerShell 5.1 と 7 の両方に対応する。
- このスクリプトを起動する .bat を、このリポジトリに置く。PowerShell スクリプトはダブルクリックで実行できないため。
  - `powershell.exe`(5.1)固定で、`-NoProfile -ExecutionPolicy Bypass -File "%~dp0<script>.ps1" %*` で起動する。
  - 成功・失敗にかかわらず毎回 `pause` する。
- 終了時に、結果をポップアップ(MessageBox)で表示する。
  - 成功時: 出力パスと SHA-256。
  - 失敗時: エラー内容とログのパス。
  - `noPopup` で抑止できる。
- スクリプトと .bat は、このリポジトリ直下の `build-offline.ps1` と `build-offline.bat`。(確定)

## 10. このリポジトリの構成

```
odekake-winpython\
├─ build-offline.ps1 / build-offline.bat
├─ lib\*.ps1                     ← build-offline.ps1 から dot-source する関数(§14)
├─ tests\*.Tests.ps1             ← Pester 5 の単体テスト(§14)。リリースの zip には入れない(export-ignore)
├─ config\settings.json          ← コミットする
├─ config\settings.local.json    ← gitignore
├─ logs\                         ← gitignore
├─ .build\                       ← gitignore(WinPython キャッシュ、作業用フォルダ)
└─ docs\
   ├─ spec.md
   └─ issues.md                  ← 課題の仮置き場(リモート公開後に GitHub の issue へ移す)
```

## 11. 確認済みの事実

- WinPython は 2026-03 以降、dot / slim / dotf / slimf の4種のみ。最小は dot。exe と zip/7z は中身同一。2026-04 はベータ(10/4 時点で b3)。
- 3.13 dot zip の中身(実物で確認):
  - 最上位は `WPy64-313150`。その下に `python\`, `scripts\`, `notebooks\`, `wheelhouse\`, 各種ランチャー .exe, `license.txt` がある。
  - `python\python.exe`, `python\Lib\site-packages\` がある。pip 26.2.1 を同梱。`._pth` ファイルがないので、`.pth` が有効。
  - `scripts\env.bat` は、PATH(`python\`, `python\Scripts` 等)、`PYTHONIOENCODING=utf-8`、`HOME` を設定する。
  - 同梱の wppm に、pip のランチャーを移設可能にする処理(`--movable`)がある。console script の .exe が移設に耐える可能性がある。(未検証。本スクリプトはランチャーを使わないので影響なし)
- PowerShell 5.1 と 7.6.6 は、どちらも既定で STA。フォルダ選択ダイアログを出せる。
- PS 7 の `PSModulePath` を引き継いだ環境(PS 7 から起動した Git Bash など)から `powershell.exe -File build-offline.ps1` を呼ぶと、5.1 で `Get-FileHash` が見つからずに失敗した。`PSModulePath` を外して呼ぶと成功した(2026-10-06 確認)。PS 7 のターミナルから build-offline.bat を呼んだときも同じになるかは未確認。
- uv 0.11.16 の `uv export` に次のフラグがある: `--frozen`, `--no-dev`, `--no-emit-project`, `--no-hashes`, `--no-default-groups`, `--group`, `--all-groups`, `--extra`, `--all-extras`, `--format`, `-o/--output-file`。
- 参照: https://winpython.github.io/ , https://winpython.github.io/releases.html
- 3.12 は、2026-03 リリース(`17.12.20260522/WinPython`)にはない(3.13.15 / 3.14.7 / 3.15.0 のみ)。3.12 の dot 版がある最後の安定版は 2025-03 リリース(タグ `16.6.20250620final`)で、これより新しいリリースに 3.12 はない(2026-10-06 確認)。
- 3.12 dot zip(3.12.10)の中身(実物で確認):
  - 最上位は `WPy64-312101`。`python\python.exe` と `python\Lib\site-packages\` は 3.13 と同じ深さなので、`.pth` の `..\..\..\..\src` はそのまま使える。
  - `._pth` はない。pip 25.1.1、packaging 25.0、setuptools 79.0.1 を同梱。同梱の pip 25.1.1 で、`uv export` が出すハッシュ付きの requirements を入れられる(試験ビルドで確認)。
  - 3.13 との違い: `wheelhouse\` がない(prune では「(なし)」になるだけ)。空の `settings\` と `t\` がある(役割が分からないので消さない)。
- 3.13 dot は packaging 26.2 を同梱している。lock がこれと違う版を指していれば、pip が入れ替える(試験用プロジェクトで 26.3 に入れ替わった)。
- git pathspec の `:(exclude,glob)` で、`tests` はフォルダごと、`*.log` は最上位だけ、`**/*.log` は全階層に当たる(2026-10-06 確認)。
- export-ignore の判定(git 2.54.0、2026-10-06 確認):
  - `git ls-files` は export-ignore を見ない。pathspec の `:(exclude,attr:export-ignore)` はファイル自身の属性だけを見るので、フォルダに付いたものは効かない。
  - `git check-attr export-ignore` も同じで、`/tests/ export-ignore` のとき `tests/x.py` は unspecified。フォルダを `tests/`(末尾に `/`)で問い合わせると set になる。`tests`(`/` なし)では unspecified。`docs export-ignore`(末尾に `/` なし)は `docs` でも `docs/` でも set。
  - `git archive` は、export-ignore のフォルダを中身ごと除く。そこで Get-ProjectFiles は、ファイルと、その親フォルダすべて(末尾に `/`)を check-attr で問い合わせ、どれかが set なら除く。
  - check-attr は未 add のファイルにも効く(パスだけで判定する)。`.gitattributes` 自身に export-ignore を付ければ、それも除かれる。

## 12. 受け入れ基準と未確認事項

### 受け入れ基準
元の要件定義(リポジトリ外)の Acceptance Criteria を、汎用スクリプトに合わせて書き直したもの。

1. コマンド1つ(または build-offline.bat のダブルクリック)で、対象プロジェクトから ZIP を作れる。— 確認済み(試験用プロジェクト・実プロジェクト)
2. 対象プロジェクトの既存の .venv に依存しない。— 確認済み(子プロセスの環境変数を外し、WinPython の python.exe だけを使う。§13)
3. 同梱する Python 実行環境は WinPython である。— 確認済み
4. 依存は uv.lock の固定された状態から入れる。— 確認済み(`uv export --frozen`、uv モードは `uv sync --frozen`)
5. ビルドの失敗が、はっきり分かる。— 確認済み(ポップアップ、ログ、終了コード)
6. 成果物を別の Windows PC にコピーできる(1ファイル)。— 確認済み
7. インターネットもシステムの Python もない PC で展開し、同梱の WinPython で対象のコードを import できる。別の展開先パス(日本語・空白を含む)でも動く。— 別パスは確認済み。インターネットも Python もない PC では未確認
8. 再ビルドで、必要がなければ WinPython をダウンロードし直さない。— 確認済み
9. 一時ファイルが git にコミットされない。— このリポジトリの `.build\`, `logs\` は gitignore 済み。対象プロジェクトには何も書かない

確認の記録:
- 2026-10-06 に、試験用の uv プロジェクト(requests に依存)で確認: 5.1 / 7 の両方でビルド成功。成果物を日本語と空白を含む別のパスに展開し、`python -I -c "import <パッケージ>, requests"` が通った。2回目以降は WinPython をダウンロードせずキャッシュを使った。
- 2026-10-06 に、Python 3.12 の試験用プロジェクト(requests に依存、`.python-version` は `3.12.2`)で確認: 5.1 / 7 の両方でビルド成功(3.12.10 を同梱)。成果物を日本語と空白を含む別のパスに展開し、`python -I -c "import <パッケージ>, requests"` が通った。同じプロジェクトを `-PythonVersion 3.13` / `3.14` でもビルドし、成功した。
- 2026-10-06 に、ユーザーが実プロジェクトでビルドし、成功・完了ポップアップの表示を確認。

### 未確認事項・実装時のメモ
- インターネットも Python もない別の PC での実行。(未確認)
- uv export は、既定でハッシュを出力する。pip はハッシュ照合モードになる。
  - PyPI の依存だけなら、ハッシュ付きのまま pip に渡して成功した(2026-10-06 確認)。
  - ハッシュのない行(path/git 依存など)がある場合に失敗するか。(未検証)
- PS 5.1 のフォルダ選択ダイアログの見た目。古いツリー形式になる可能性がある。(未確認。目視が必要)
- ZIP の作成には `System.IO.Compression.ZipFile` / `ZipArchive` を使った。5.1 と 7 の両方で作成・展開できた。

## 13. 実装で決めた細部

spec に書かれていなかったため、実装時に決めたもの。変更してよい。

- `outputDir` のフォルダがなければエラーにする(打ち間違いで意図しないフォルダを作らないため)。(確定)
- 相対パスの引数・設定は、カレントフォルダを基準に解決する。
- 配列の引数(`-Groups` など)は、カンマ区切りも受け付ける。.bat 経由(`-File`)だと `-Groups a,b` が1つの文字列で届くため。
- 作業用フォルダ `.build\work\` は、ビルド開始時に前回分を消す。成功時は消し、失敗時は調査用に残す。
- pyproject.toml は正規表現で読む(PowerShell に TOML パーサーがないため)。`[project]` の `name` / `version` が1行の文字列で書かれている前提。
- 動作確認の import は `python -I`(カレントフォルダを sys.path に入れない)で行い、`.pth` を経由して import できることを確かめる。
- ビルド中は、子プロセスの環境変数 `PYTHONPATH`, `PYTHONHOME`, `VIRTUAL_ENV` 等を外し、`PYTHONNOUSERSITE=1` にする。開発環境の影響を受けないため。
- 外側 ZIP 内で `winpython.zip` / `winpython.7z` は無圧縮で格納する(圧縮済みのため)。
- ZIP は `ZipArchive` でエントリを1つずつ追加して作り、区切りは必ず `/` にする。PS 5.1(.NET Framework)の `ZipFile.CreateFromDirectory` は区切りに `\` を使い、ZIP の規格に反するため使わない(2026-10-06、実プロジェクトの成果物で判明)。空フォルダも入れる。
- 対象プロジェクトに `winpython.zip`、`winpython.7z`、`winpython\` があると成果物と衝突するので、エラーにする(どの形式を選んでも、3つとも)。

## 14. build-offline.ps1 の分割と単体テスト

2026-10-06 時点で `build-offline.ps1` は約750行の1ファイルだった。保守性のため、責務ごとにファイルを分け、ビルドを走らせずに確かめられる部分に単体テストを付けた(issue #2)。

### 目的
- 分割そのものより、設定の読み込み・pyproject の読み取り・Python バージョンの決定・ファイル列挙を、WinPython のダウンロードなしで数秒で確かめられるようにすることが主目的。
- 利用者から見た動作(引数、設定キー、成果物、ログ、.bat)は一切変えない。

### 分割後の構成
```
odekake-winpython\
├─ build-offline.ps1        ← param、固定値、本体(Invoke-Build)、終了処理だけ。lib\*.ps1 を dot-source する
├─ build-offline.bat        ← 変更なし
├─ lib\
│  ├─ Log.ps1               ← Write-Log, Write-Step, Open-LogFile, Invoke-Native
│  ├─ Settings.ps1          ← Resolve-FullPath, Get-SettingKind, Assert-SettingChoice, Read-SettingsFile, Get-EffectiveSettings
│  ├─ Project.ps1           ← Read-PyProject, Get-ProjectVersion, Get-PythonMinor, Get-ProjectFiles, Get-NonPyPIRequirements(§15)
│  ├─ WinPython.ps1         ← Get-Sha256, Get-WinPythonArchive, Expand-WinPython
│  ├─ Zip.ps1               ← New-ZipFile, New-ZipFromDirectory, Get-SystemTarPath, New-SevenZipFromDirectory, Assert-SevenZipWritable(§16)
│  └─ Gui.ps1               ← New-TopMostOwner, Resolve-InitialDir, Select-ProjectFolder, Show-Popup, Get-DownloadsFolder
└─ tests\
   ├─ Settings.Tests.ps1
   ├─ Project.Tests.ps1
   ├─ Zip.Tests.ps1
   └─ Gui.Tests.ps1
```
- 固定値(`$WinPythonTable`, `$PruneTargets`, `$SettingTypes`, `$PthFileName`, `$PthContent`, `$EnvOverrides`)は `build-offline.ps1` の先頭に残す。WinPython の版を上げるときに見る場所を1か所にするため。
- 読み込みは `build-offline.ps1` で `foreach ($f in 'Log','Settings','Project','WinPython','Zip','Gui') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }`。

### 作業の手順
1. 関数が暗黙に参照しているスクリプト変数を、引数で受け取る形に直す(テストから呼べるようにするため)。対象:
   - `Read-SettingsFile`, `Get-EffectiveSettings` → `$SettingTypes`, `$RepoRoot`
   - `Get-WinPythonArchive` → `$BuildDir`
   - `Expand-WinPython` → `$WorkDir`
   - `Open-LogFile`, `Write-Log` → `$LogDir`, `$Timestamp`, `$Utf8NoBom`, `$script:LogPath`, `$script:LogBuffer`。ログはスクリプト全体で1つの状態なので、`$script:` のまま残してよい。その場合、Log.ps1 の先頭で初期化する。
2. 関数を上の対応で `lib\*.ps1` に移す。中身は変えない。
3. `lib\*.ps1` も **BOM 付き UTF-8** で保存する(PS 5.1 が日本語を読めないため。§11 参照)。
4. `build-offline.ps1` から dot-source する。
5. 動作確認(下の「完了の条件」)。
6. テストを書く。

### テストに入れるケース
- Settings.Tests.ps1(一時フォルダに settings.json / settings.local.json を書いて呼ぶ)
  - ファイルがなくても既定値が返る。
  - 優先順位: 引数 > settings.local.json > settings.json > 既定値。キー単位でマージされる。
  - 未知のキーはエラー。大文字小文字だけ違うキー(`outputdir`)もエラー。
  - 型違い(`"trackedOnly": "yes"`, `"groups": "dev"`)はエラー。
  - 配列の引数 `-Groups 'a,b'` が `a`, `b` の2つに分かれる。
  - 引数の `pythonVersion` は、ここでは上書きしない(§5 の優先順位は Get-PythonMinor で扱う)。
- Project.Tests.ps1
  - Read-PyProject: 通常 / シングルクォート / `dynamic = ["version"]`(複数行を含む)/ `[tool.x]` や `[[tool.uv.index]]` の `name` を拾わない。
  - Get-ProjectVersion: VERSION ファイルの前後の空白・改行を除く / VERSION がない / 2行以上ある。
  - Get-PythonMinor: 引数 > .python-version > 設定ファイル / `3.13.5` や `cpython-3.13` を 3.13 と読む / 引数と .python-version が違うと警告 / どれもないとエラー。
  - Get-ProjectFiles(一時フォルダで `git init` して作る): 既定は未 add のファイルを含む / `trackedOnly` / `exclude` の `tests`, `*.log`, `**/*.log`(§11 の挙動)/ 削除済みファイルはスキップ / `winpython.zip` や `winpython/` があるとエラー / 日本語のファイル名 / export-ignore(ファイル、フォルダ(`/` 付き・なし)、パターン、未 add のファイル、`.gitattributes` 自身、サブフォルダの `.gitattributes`、`set` 以外の値は除かない)/ `includeExportIgnored` で含める / export-ignore の `winpython.zip` はエラーにしない / `exclude`・`trackedOnly` との併用。
- Zip.Tests.ps1
  - エントリ名の区切りが `/` だけになる(§13)。空フォルダが入る。`Store` のエントリが無圧縮になる。
- Gui.Tests.ps1(ダイアログは出さない)
  - Resolve-InitialDir: 未指定は $null / 存在するフォルダはそのまま(正規化する)/ 環境変数を展開する / ないフォルダやファイルは警告して $null / 相対パスはエラー。

### 前提
- テストは Pester 5 を前提にする。(確定)Windows 標準の Pester は 3.4 で書き方が違う。`Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MaximumVersion 5.99` で入れる。
  - `-MaximumVersion` を付けないと、2026-10 時点では Pester 6.2.0 が入る。6 での動作は確かめていない。
  - PS 5.1 では、先に `Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force` が要った(2026-10-06 確認)。
  - 5.1 と 7 はモジュールのフォルダが別なので、それぞれに入れる。
- テストの実行方法(`Invoke-Pester tests`)は README に書く。`run-tests.bat` は置かない。(確定)

### 実装で決めたこと
- `Open-LogFile` は `($Name, $LogDir, $Timestamp)` を受け取る。ログの状態(`LogBuffer`, `LogPath`, 書き込みに使う UTF-8 BOM なしの Encoding)は Log.ps1 の先頭で `$script:` に初期化する。
- `Read-SettingsFile` は `($Path, $SettingTypes)`、`Get-EffectiveSettings` は `($BoundParameters, $SettingTypes, $RepoRoot)`、`Get-WinPythonArchive` は `($Entry, $BuildDir)`、`Expand-WinPython` は `($Archive, $Destination, $WorkDir)` を受け取る。
- `$EnvOverrides` も固定値として `build-offline.ps1` の先頭に移した。
- Settings.Tests.ps1 は、`$SettingTypes` を `build-offline.ps1` から構文解析で取り出して使う(スクリプトは実行しない)。テスト側に設定キーの写しを持たないため。
- Project.Tests.ps1 の Get-ProjectFiles は、`GIT_CONFIG_GLOBAL` を空のファイルに、`GIT_CONFIG_NOSYSTEM=1` にして呼ぶ。利用者のグローバルな除外設定などに結果が左右されないため。
- issue #2 に「既知のバグ」として挙がっていた2点(大文字小文字だけ違うキーが通る、ZIP のエントリ名の区切りが `\`)は、分割前の時点で既に直っていた(`-ccontains`、`-replace '\\', '/'`)。テストはこれらの再発を検出する。直した箇所をわざと元に戻すとテストが失敗することを確認した(2026-10-06)。

### 確認の記録
- 2026-10-06、試験用 uv プロジェクト(requests に依存、3.13、日本語のファイル名を含む)で、分割の前後を PS 5.1 / 7 の両方でビルドして比べた。
  - どちらもビルドに成功した。ログ(時刻・パス・サイズ・SHA-256・所要時間以外)は一致した。
  - 外側 ZIP と winpython.zip のエントリ一覧(名前とサイズ)は一致した。違ったのは、外側 ZIP の中の winpython.zip のサイズだけだった(数十バイト)。同じ版で2回ビルドしても1バイト違ったので、ビルドのたびに揺れるものと判断した(原因は未調査)。
  - エラー系(git でない、未知のキー、未対応の Python、VERSION なし)のメッセージは一致した。違うのはスタックトレースの行番号とファイル名だけ。
- `Invoke-Pester tests` は PS 5.1.26100 / 7.6.6(Pester 5.9.1)の両方で 51 件すべて成功した。テストはネットワークを使わない(git はローカルのリポジトリにだけ使う)。ネットワークを切った状態での実行はしていない。

### 完了の条件
- 分割の前後で、試験用 uv プロジェクトに対するビルドが PS 5.1 と 7 の両方で成功し、ログの内容(時刻とパス以外)と、外側 ZIP・winpython.zip のエントリ一覧が一致する。
- エラー系(git でない、未知のキー、未対応の Python、VERSION なし)のメッセージが変わらない。
- `Invoke-Pester tests` が PS 5.1 と 7 の両方で通る。ネットワークにつながっていなくても通る。

## 15. 依存のインストール方式(installer)

issue #10。`[tool.uv.sources]` で独自の index(`explicit = true`)を指定した非公開パッケージが依存にあると、pip 方式のビルドが失敗していた。

### 原因(2026-10-06、ローカルの擬似 index で再現。uv 0.11.16 / WinPython 3.13.15 dot)
- `uv export --format requirements-txt` は index の情報を出さない(`mylib==0.1.0 --hash=...` だけ)。pip は PyPI だけを探し、`No matching distribution found` で失敗する。
- PyPI に同名のパッケージがあっても、ハッシュが合わないので誤って入ることはない。ハッシュは外さない。
- 実プロジェクトの失敗ログは未確認。同じ原因というのは推測。

### 方式(確定)
- `uv sync` で WinPython の python フォルダに直接入れる方式(uv モード)を足し、既定にする。普段の `uv sync` と同じ認証の仕組み(`UV_INDEX_<NAME>_USERNAME/PASSWORD`、keyring、netrc、`uv auth` など)がそのまま効くため。
- `config\settings.json` にも `"installer": "uv"` を書き、切り替えられることが目に入るようにする。
- 従来の pip 方式も `installer: "pip"` で残す。uv モードで問題が出たときの逃げ道。pip モードでも `uv export` を使うので、uv への依存はなくならない。
- 検討して採らなかった方式: `uv export --format pylock.toml` → `pip install -r pylock.toml`(pip が experimental の警告を出す。3.12 の pip 25.1.1 は未検証)、requirements.txt + `--extra-index-url`(認証情報を pip 用に別に用意する必要があり、汎用スクリプトに向かない)。

### uv モードの引数(確定、2026-10-06)
`UV_PROJECT_ENVIRONMENT=<winpython\python>` にして、次を実行する。環境変数は呼び出しの間だけ設定し、元に戻す。
```
uv sync --project <対象> --frozen --inexact --no-install-project --no-default-groups [--group X ...] [--extra Y ...]
        --python <winpython\python\python.exe> --link-mode copy --no-editable
```
- `--inexact`: 付けないと、lock にないもの(WinPython 同梱の pip、wppm、packaging、setuptools 等)が消される。
- `--link-mode copy`: uv のキャッシュへのハードリンクにせず、実体をコピーする。成果物がキャッシュと結びつかないため。
- `--no-editable`: path 依存やワークスペースのメンバーを、開発機の絶対パスを指す editable にしないため。
- `--compile-bytecode` は付けない(見送り)。
- 個人の uv 設定(`uv.toml`、`UV_*` 環境変数)は外さない(`--no-config` は付けない)。index の認証に効いてほしいため。その分、成果物が個人の設定に左右されうる。
- ログに `uv --version` を出す。uv sync には `-v` を付けない(入れたパッケージの一覧は通常の出力に出る)。

### pip モードの事前検査(確定、2026-10-06)
- `uv export` の直後(WinPython のダウンロード前)に、requirements.txt の各依存(`name==version`)を uv.lock の `[[package]]` と照合する。`source = { registry = "..." }` が `https://pypi.org/simple` 以外なら、該当する依存を並べてエラーにする(`Get-NonPyPIRequirements`)。
- 環境マーカーで index を切り替えると、uv.lock に同じ `name==version` が registry 違いで複数入る。requirements.txt からはどれが選ばれたか分からないため、1つでも PyPI 以外があればエラーにする(安全側。Windows 以外向けの非公開 index でも止まる)。(PR #11 のレビューで判明)
- requirements.txt に出ない依存(選ばなかった group など)は見ない。名前は PEP 503 の正規化(`[-_.]+` → `-`、小文字)で照合する。URL の末尾の `/` は区別しない。
- pyproject の `[[tool.uv.index]]` は正規表現で確実に読めない恐れがあるため、uv.lock を見る。
- PyPI のミラーを既定の index にしている環境(`UV_DEFAULT_INDEX` など)では、PyPI のパッケージでもエラーになる。(推測。未検証) その場合は uv モードを使う。

### 設定の型
- 決まった値だけを受け付ける型を足した。`$SettingTypes` の値を配列にすると、その中の値だけを受け付け、先頭の値が既定値になる。設定ファイルと引数の両方で、大文字小文字も区別して確かめる(未知のキーと同じ扱い)。

### 確認の記録(2026-10-06、uv 0.11.16)
- 擬似の非公開 index(`python -m http.server` で配った PEP 503 の simple index。`explicit = true`)にだけある `mylib` と requests に依存する 3.13 の試験用プロジェクト:
  - uv モード: PS 5.1 / 7 の両方でビルド成功。
  - pip モード: PS 5.1 / 7 の両方で、WinPython のダウンロード前に「PyPI 以外の index から取る依存があり…」のエラーで止まった。
- PyPI だけの試験用プロジェクト(3.12(`.python-version` は `3.12.2`)/ 3.13、requests に依存): uv / pip の両モード × PS 5.1 / 7 の全8通りでビルド成功。
- 上の成功した成果物すべてを、日本語と空白を含むパスに展開し、`python -I -c "import <パッケージ>, requests, pip, packaging"`(非公開のものは `mylib` も)が通った。
- uv モードの成果物で、元の WinPython の `site-packages` 直下の項目(3.13: 21 個、3.12: 24 個)がすべて残っていた。
- 対象プロジェクトには `.venv` などのファイルは作られず、`git status --ignored` も空のままだった。
- uv モードで入れたパッケージの `INSTALLER` は `uv`。搬入先の pip(26.2.1)で `pip uninstall` できた。
- 実プロジェクトでのビルドの確認(ユーザー)は未実施。

## 16. WinPython のアーカイブ形式(winPythonArchiveFormat)

issue #13。外側 ZIP の中に入れる WinPython のアーカイブを、zip か 7z から選べるようにした。外側は zip のまま。

### 方式(確定、2026-10-06)
- 既定は zip(従来どおり `winpython.zip`)。`"7z"` にすると `winpython.7z` を入れる。
  - 既定を zip にした理由: PowerShell の `Expand-Archive` は 7z を扱えず、搬入先が Windows 10 や古いビルドだと 7-Zip が要るため。
- 7z は Windows 標準の `%SystemRoot%\System32\tar.exe`(bsdtar / libarchive)で作る: `tar.exe -C <winpython> --format 7zip --options 7zip:compression=lzma2 -cf winpython.7z <最上位の項目...>`
  - パスは System32 に固定する。PATH の `tar` は Git for Windows の GNU tar 1.35 のことがあり、これは 7z を書けない(`7zip: Invalid archive format`)。
  - tar に `.` を渡すとエントリ名が `./` で始まるので、最上位の項目を名前で並べて渡す。
  - 7-Zip(`7z.exe`)は使わない。追加の導入が要らないことを優先した。7-Zip 製より約 4% 大きくなる(下の比較)ことは承知のうえ。
- 圧縮は LZMA2、レベルは libarchive の既定。solid(1 ブロック)になる。
- 7z を作れないときは、zip にフォールバックせずエラーで止める。WinPython のダウンロード前に、作業用フォルダで小さな 7z を試しに作って確かめる(`Assert-SevenZipWritable`)。ログに `tar --version` を出す。
- 外側 ZIP の中では無圧縮で格納する(§13)。

### 搬入先での展開
- 7-Zip、または `tar.exe -C winpython -xf winpython.7z`(先に `winpython\` を作る)で展開する。
- Windows 11 の新しいビルドのエクスプローラーは 7z を展開できるはず。(未確認)
- Windows 10 や古いビルドの `tar.exe` は 7z(LZMA2)を書けない・読めない可能性がある。(推測。未確認)

### 確認の記録(2026-10-06、Windows 11 26200、tar.exe は bsdtar 3.8.8 / libarchive 3.8.8 / liblzma 5.8.1)
- WinPython 3.13.15 dot 単体(依存なし、prune 前、4323 ファイル)の比較:

| 作り方 | サイズ | 時間 |
|---|---|---|
| 元の配布 zip | 28.2 MB | — |
| `Compress-Archive` の zip | 28.0 MB | 約 5 秒 |
| tar.exe 7z(lzma2、既定レベル) | 17.5 MB | 18〜40 秒(測るたびにばらついた) |
| tar.exe 7z(lzma2、レベル 9) | 17.0 MB | 約 21 秒 |
| 7-Zip 26.04 `7zr -mx=5`(既定) | 16.9 MB | 約 10 秒 |
| 7-Zip 26.04 `7zr -mx=9` | 16.5 MB | 約 12 秒 |

- 7-Zip との差は、7-Zip が exe/dll 向けの BCJ フィルタと大きな辞書を使うためと思われる。(推測)
- tar.exe で作った 7z は、7-Zip 26.04 の `7zr t` で異常なし。`7zr x` と `tar.exe -xf` のどちらで展開しても、ファイル数が元と一致し、`python.exe` が動いた。7-Zip から見ると `LZMA2:23`、solid、1 ブロック。
- 試験用プロジェクト(3.13、requests に依存、uv モード、prune あり)のビルド:
  - `-WinPythonArchiveFormat 7z`: PS 7 / 5.1(.bat 経由)の両方で成功。winpython.7z は 16.9 MB(既定の zip のビルドでは winpython.zip が 26.7 MB)。
  - 既定(zip): PS 5.1 で成功し、従来どおり `winpython.zip` が入った。
  - `-WinPythonArchiveFormat 7Z` は、設定の値のエラーで止まった。
- 成果物を日本語と空白を含むパスに展開し(外側は `Expand-Archive`、winpython.7z は `tar.exe -xf` と 7-Zip の両方)、`python -I -c "import <パッケージ>, requests, pip"` が通った(PS 7 / 5.1)。
- `tar -tf` の一覧はコンソールのコードページで出力されるので、日本語の名前が化けて見える。7z の中には UTF-16 で入っており、展開すれば正しい名前になる。
