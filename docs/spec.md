# odekake-winpython 仕様(2026-10-06 確定版、2026-10-07 に Python へ移行)

元の要件定義(リポジトリ外)を、2026-10-05〜06 の検討で改めたもの。
旧 docs/handoff-addendum.md を整理し直したもので、検討の経緯は git 履歴を参照。
実装は 2026-10-07 に PowerShell から Python に移した(§18)。それより前の「確認の記録」は、PowerShell 版で確かめたもの。

表記:
- **(確定)** はユーザー承認済み。
- **(推測)** **(未検証)** は裏付けがない。
- **(未決定)** はユーザーの判断待ち。勝手に確定しない。

---

## 1. 目的とスコープ

- 任意の uv プロジェクトを、オフラインの Windows 環境へ持ち出すための ZIP にする汎用スクリプト。特定リポジトリ専用ではない。(確定)
- 実装は Python。ビルドする PC も Windows に限る(§18)。(確定)
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

- `--project-root` が指定されていれば、それを使う。
- 指定がなければ、フォルダ選択ダイアログ(tkinter の `filedialog.askdirectory`)を出す。キャンセルしたら何もせず終了する。
  - tkinter が使えない Python で起動したときは、ダイアログを出さずに「`--project-root` を指定すること」というエラーで止める。
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
5. WinPython を用意する: `.build\` にキャッシュする。期待 SHA-256 と一致しなければ、自動でダウンロードし直す。`--force` は設けない。
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
- Python バージョンの優先順位は **引数 `--python-version` > `.python-version` > 設定ファイルの `pythonVersion`**。(確定)
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
- SHA-256 は画面に表示し、ログにも記録する。用途は、持ち出し申請の書類に値を記載し、搬入先で `Get-FileHash` と照合すること。表示は `Get-FileHash` と同じ大文字の16進。
- ZIP の中に各ファイルのハッシュ一覧(SHA256SUMS)は入れない。
- ログ: このリポジトリの `logs\yyyymmddTHHmmss_<name>.log`。SHA-256 に加え、ビルド全体のログを書く。ログは持ち出さない。
- ログは自前の関数(`log.write_log`)で、コンソールとログファイルの両方に書く。外部コマンド(uv, pip など)の出力も、受け取ってログに書き出す。

## 8. 設定(確定)

### 設定ファイル
- 形式は JSON。(PowerShell 版のとき、YAML / TOML は標準のパーサーがないため不採用、psd1 は馴染みがないため不採用とした。Python への移行でも、互換のため JSON のまま。§18)
- 置き場所はこのリポジトリ。対象プロジェクトは汚さない。
  - `config\settings.json`: 全プロジェクト共通。コミットされるので、個人のパスを書かない。
  - `config\settings.local.json`: 個人用。`*.local.json` は gitignore する。
- 優先順位: **引数 > settings.local.json > settings.json > 既定値**。マージはキー単位(書いたキーだけ上書きする)。
- プロジェクトごとの指定(`groups`, `extras`, `exclude` 等)は、引数で渡す。プロジェクト別の設定欄は設けない。
- 未知のキーはエラーにする(打ち間違いの検出のため)。
- 設定ファイル自体がなくても動く。

### 項目
- 設定キーは camelCase、引数はケバブケース(下の表のとおり)。
- 真偽値は、既定が false になる向きで名付ける。
- 真偽値の引数は `--x` / `--no-x` の両方を受け付け、設定ファイルの値をどちらの向きにも上書きできる。ただし `noPopup` は `--no-popup` だけ。

| 設定キー | 引数 | 型 | 既定値 / 説明 |
|---|---|---|---|
| (なし) | `--project-root` | パス | なし → フォルダ選択ダイアログ |
| (なし) | `--config-path` | パス | `config\settings.json`(同じフォルダの `settings.local.json` も読む) |
| `pythonVersion` | `--python-version` | 文字列 | `.python-version` の値。優先順位は §5 |
| `outputDir` | `--output-dir` | パス | ダウンロードフォルダ |
| `trackedOnly` | `--tracked-only` / `--no-tracked-only` | 真偽値 | false(未 add のファイルも含める) |
| `includeExportIgnored` | `--include-export-ignored` / `--no-include-export-ignored` | 真偽値 | false(`.gitattributes` で `export-ignore` のファイルは含めない。§2) |
| `groups` | `--groups` | 文字列の配列 | 空(dev も含めない) |
| `extras` | `--extras` | 文字列の配列 | 空 |
| `exclude` | `--exclude` | 文字列の配列 | 空。外側 ZIP から除外するパターン |
| `pruneWinPython` | `--prune-winpython` / `--no-prune-winpython` | 真偽値 | false(`config\settings.json` で true にしている) |
| `importName` | `--import-name` | 文字列 | pyproject の `name`(`-` → `_`) |
| `installer` | `--installer` | `"uv"` / `"pip"` | `"uv"`。依存を入れる方法(§15)。ほかの値はエラー(大文字小文字も区別する) |
| `winPythonArchiveFormat` | `--winpython-archive-format` | `"zip"` / `"7z"` | `"zip"`。外側 ZIP に入れる WinPython のアーカイブの形式(§16)。ほかの値はエラー(大文字小文字も区別する) |
| `noPopup` | `--no-popup` | 真偽値 | false |
| `initialDir` | (なし) | パス | なし(初期位置を指定しない)。フォルダ選択ダイアログの初期位置 |

- 配列の引数は、`--groups a b` のように1つの引数に続けて書くことも、`--groups a --groups b` のように繰り返すことも、`--groups a,b` のようにカンマで区切ることもできる。
- `projectRoot` と `configPath` は設定キーにしない。設定ファイルの場所がそれらで決まるため。
- `initialDir` は、フォルダ選択ダイアログ(`--project-root` を省略したとき)の初期位置。(確定、2026-10-06)
  - 個人のパスになるので、`settings.local.json` に書く。
  - 引数は設けない。引数で指定するなら `--project-root` を使えばよいため。
  - 環境変数(`%USERPROFILE%` など)は展開する。展開するのは `%NAME%` の形だけ(`$NAME` は展開しない。`\\server\c$` などを壊さないため)。定義されていない変数はそのまま残す。
  - 相対パスはエラーにする(.bat から起動すると基準が分かりにくいため)。展開できなかった環境変数が残って相対パスになった場合も同じ。
  - フォルダがなければ、ログに警告を出し、初期位置を指定せずにダイアログを開く。
  - ダイアログには `askdirectory` の `initialdir` で渡す。
- `exclude` は git pathspec(glob)の書式で書き、`:(exclude,glob)<パターン>` として git に渡す。対象プロジェクトの最上位からの相対パスで書く。(確定)
  - 例: `docs/**`, `**/*.log`, `tests`(フォルダごと)。
  - .gitignore と違い、`*.log` は最上位のファイルにしか当たらない。どの階層にも当てるなら `**/*.log`。
- `pruneWinPython` は、スクリプトの既定値は false のまま、コミットする `config\settings.json` で true にする。これで通常は削除される。(確定、2026-10-06)
  - 残したいときは、`settings.local.json` に `"pruneWinPython": false` と書くか、引数 `--no-prune-winpython` を付ける。
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

- 実装は Python 3.11 以上(`tomllib` を使うため)。インタープリターは uv が用意する(ビルドにはもともと uv が必須)。
- このスクリプトを起動する .bat を、このリポジトリに置く。ダブルクリックで実行するため。
  - 中身は `uv run --project "%~dp0." --no-dev python "%~dp0build_offline.py" %*`。
    - `--project` に `"%~dp0"` をそのまま渡すと、末尾の `\` と `"` が `\"` として読まれ、引数が壊れる。そのため `.` を足して `"%~dp0."` にする。
  - 成功・失敗にかかわらず毎回 `pause` し、終了コードを返す。
- 終了時に、結果をポップアップ(Win32 の `MessageBoxW`。最前面に出す)で表示する。
  - 成功時: 出力パスと SHA-256。
  - 失敗時: エラー内容とログのパス。
  - `noPopup` で抑止できる。
- スクリプトと .bat は、このリポジトリ直下の `build_offline.py` と `build-offline.bat`。(確定)

## 10. このリポジトリの構成

```
odekake-winpython\
├─ build_offline.py / build-offline.bat
├─ odekake\*.py                  ← build_offline.py から使うモジュール(§14)
├─ tests\test_*.py               ← pytest の単体テスト(§14)。リリースの zip には入れない(export-ignore)
├─ pyproject.toml / uv.lock      ← このツール自身の Python と開発用の依存(pytest)
├─ config\settings.json          ← コミットする
├─ config\settings.local.json    ← gitignore
├─ logs\                         ← gitignore
├─ .build\                       ← gitignore(WinPython キャッシュ、作業用フォルダ)
├─ .venv\                        ← gitignore(uv run が作る)
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
  - `git archive` は、export-ignore のフォルダを中身ごと除く。そこで `project.get_project_files` は、ファイルと、その親フォルダすべて(末尾に `/`)を check-attr で問い合わせ、どれかが set なら除く。
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
9. 一時ファイルが git にコミットされない。— このリポジトリの `.build\`, `logs\`, `.venv\` は gitignore 済み。対象プロジェクトには何も書かない

確認の記録:
- 2026-10-06 に、試験用の uv プロジェクト(requests に依存)で確認(PowerShell 版): ビルド成功。成果物を日本語と空白を含む別のパスに展開し、`python -I -c "import <パッケージ>, requests"` が通った。2回目以降は WinPython をダウンロードせずキャッシュを使った。
- 2026-10-06 に、Python 3.12 の試験用プロジェクト(requests に依存、`.python-version` は `3.12.2`)で確認(PowerShell 版): ビルド成功(3.12.10 を同梱)。成果物を日本語と空白を含む別のパスに展開し、`python -I -c "import <パッケージ>, requests"` が通った。同じプロジェクトを Python 3.13 / 3.14 の指定でもビルドし、成功した。
- 2026-10-06 に、ユーザーが実プロジェクトでビルドし、成功・完了ポップアップの表示を確認(PowerShell 版)。
- Python 版の確認は §18。

### 未確認事項・実装時のメモ
- インターネットも Python もない別の PC での実行。(未確認)
- uv export は、既定でハッシュを出力する。pip はハッシュ照合モードになる。
  - PyPI の依存だけなら、ハッシュ付きのまま pip に渡して成功した(2026-10-06 確認)。
  - ハッシュのない行(path/git 依存など)がある場合に失敗するか。(未検証)
- tkinter のフォルダ選択ダイアログの見た目と、コンソールの後ろに隠れずに前面に出るか。(未確認。目視が必要)

## 13. 実装で決めた細部

spec に書かれていなかったため、実装時に決めたもの。変更してよい。

- `outputDir` のフォルダがなければエラーにする(打ち間違いで意図しないフォルダを作らないため)。(確定)
- 相対パスの引数・設定は、カレントフォルダを基準に解決する。
- 配列の引数(`--groups` など)は、カンマ区切りも受け付ける(PowerShell 版の `-Groups a,b` と同じ書き方ができるように残した)。
- 作業用フォルダ `.build\work\` は、ビルド開始時に前回分を消す。成功時は消し、失敗時は調査用に残す。
- pyproject.toml と uv.lock は `tomllib` で読む。
- 動作確認の import は `python -I`(カレントフォルダを sys.path に入れない)で行い、`.pth` を経由して import できることを確かめる。
- ビルド中は、子プロセスの環境変数 `PYTHONPATH`, `PYTHONHOME`, `VIRTUAL_ENV` 等を外し、`PYTHONNOUSERSITE=1` にする。開発環境の影響を受けないため(`uv run` が設定する `VIRTUAL_ENV` もここで外れる)。
- 外部コマンドは `subprocess` に引数をリストで渡す(シェルは通さない)。終了コードが 0 でなければ、ビルドを失敗にする。
- 外側 ZIP 内で `winpython.zip` / `winpython.7z` は無圧縮で格納する(圧縮済みのため)。
- ZIP は `zipfile` でエントリを1つずつ追加して作り、区切りは必ず `/` にする(PowerShell 版で、.NET Framework の `ZipFile.CreateFromDirectory` が `\` を使って規格に反したため決めたこと。2026-10-06)。空フォルダも入れる。
- WinPython の zip を展開するときは、各ファイルの更新日時を zip のエントリの日時に戻す(`zipfile` は戻さないため)。
- 対象プロジェクトに `winpython.zip`、`winpython.7z`、`winpython\` があると成果物と衝突するので、エラーにする(どの形式を選んでも、3つとも。大文字小文字は区別しない)。

## 14. モジュールの構成と単体テスト

`lib\*.ps1` を、Python のモジュールに 1 対 1 で移した(issue #22。分割の経緯は issue #2)。

### 目的
- 設定の読み込み・pyproject の読み取り・Python バージョンの決定・ファイル列挙などを、WinPython のダウンロードなしで数秒で確かめられるようにする。

### 構成
```
odekake-winpython\
├─ build_offline.py         ← 引数、固定値、本体(Build.run)、終了処理だけ
├─ build-offline.bat
├─ pyproject.toml           ← requires-python >= 3.11、実行時の依存なし、[dependency-groups] dev = ["pytest"]、[build-system] なし
├─ odekake\
│  ├─ __init__.py           ← BuildError(利用者に見せるエラー), remove_tree
│  ├─ log.py                ← write_log, write_step, open_log_file, run(外部コマンド)
│  ├─ settings.py           ← resolve_full_path, read_settings_file, get_effective_settings
│  ├─ project.py            ← read_pyproject, get_project_version, get_python_minor, get_project_files, get_export_ignored_paths, get_non_pypi_requirements(§15)
│  ├─ winpython.py          ← get_sha256, get_winpython_archive, expand_winpython
│  ├─ zip.py                ← ZipEntry, new_zip_file, new_zip_from_directory, get_system_tar_path, new_seven_zip_from_directory, assert_seven_zip_writable(§16)
│  └─ gui.py                ← resolve_initial_dir, select_project_folder, show_popup, get_downloads_folder
└─ tests\
   ├─ conftest.py           ← log.write_log を差し替えて、ログに出た文言を確かめられるようにする
   ├─ test_settings.py
   ├─ test_project.py
   ├─ test_zip.py
   └─ test_gui.py
```
- 固定値(`WINPYTHON_TABLE`, `PRUNE_TARGETS`, `SETTING_TYPES`, `OPTION_NAMES`, `PTH_FILE_NAME`, `PTH_CONTENT`, `ENV_OVERRIDES`)は `build_offline.py` の先頭に置く。WinPython の版を上げるときに見る場所を1か所にするため。
- `odekake\` のモジュールは `from odekake import log` として `log.write_log` / `log.run` を呼ぶ。テストで差し替えられるようにするため。
- ソースは UTF-8(BOM なし)で保存する。

### テストに入れるケース
- test_settings.py(一時フォルダに settings.json / settings.local.json を書いて呼ぶ)
  - ファイルがなくても既定値が返る。
  - 優先順位: 引数 > settings.local.json > settings.json > 既定値。キー単位でマージされる。真偽値の引数は、設定ファイルの値をどちらの向きにも上書きできる。
  - 未知のキーはエラー。大文字小文字だけ違うキー(`outputdir`)もエラー。BOM 付きのファイルも読める。
  - 型違い(`"trackedOnly": "yes"`, `"trackedOnly": 1`, `"groups": "dev"`)はエラー。
  - 配列の引数 `--groups a,b` が `a`, `b` の2つに分かれる。
  - 引数の `pythonVersion` は、ここでは上書きしない(§5 の優先順位は `get_python_minor` で扱う)。
  - 引数の解析(`parse_arguments`): 渡した引数だけが設定として返る。すべての引数が設定キーに対応する。
- test_project.py
  - read_pyproject: 通常 / シングルクォート / `dynamic = ["version"]`(複数行を含む)/ 複数行文字列やインラインテーブル / `[tool.x]` や `[[tool.uv.index]]` の `name` を拾わない / TOML として読めないとエラー。
  - get_project_version: VERSION ファイルの前後の空白・改行を除く / VERSION がない / 2行以上ある。
  - get_python_minor: 引数 > .python-version > 設定ファイル / `3.13.5` や `cpython-3.13` を 3.13 と読む / 引数と .python-version が違うと警告 / どれもないとエラー。
  - get_project_files(一時フォルダで `git init` して作る): 既定は未 add のファイルを含む / `trackedOnly` / `exclude` の `tests`, `*.log`, `**/*.log`(§11 の挙動)/ 削除済みファイルはスキップ / `winpython.zip` や `winpython/`(大文字小文字違いを含む)があるとエラー / 日本語のファイル名 / export-ignore(ファイル、フォルダ(`/` 付き・なし)、パターン、未 add のファイル、`.gitattributes` 自身、サブフォルダの `.gitattributes`、`set` 以外の値は除かない)/ `includeExportIgnored` で含める / export-ignore の `winpython.zip` はエラーにしない / `exclude`・`trackedOnly` との併用 / 多数のパスを1回の check-attr で問い合わせる。
  - get_non_pypi_requirements: PyPI 以外の registry の依存を返す(名前は正規化して照合)/ PyPI だけなら空 / 同じ name==version の registry が複数あるとき / URL の末尾の `/` を区別しない。
- test_zip.py
  - エントリ名の区切りが `/` だけになる(§13)。空フォルダが入る。`store` のエントリが無圧縮になる。前回の `.partial` が残っていても作れる。
  - 7z: 形式と圧縮、エントリ名が `./` で始まらない、展開すると元と同じ、空のフォルダはエラー。tar.exe が 7z を作れない PC では飛ばす。
  - assert_seven_zip_writable: tar.exe がない / 7z を作れない(試験用のファイルを残さない)/ 作れる(何も残さない)。
- test_gui.py(ダイアログは出さない)
  - resolve_initial_dir: 未指定は None / 存在するフォルダはそのまま(正規化する)/ 環境変数を展開する(`$NAME` は展開しない)/ ないフォルダやファイルは警告して None / 相対パスはエラー。

### 前提
- テストは pytest で書く。`uv run pytest` で実行する(README に書く)。
- テストはネットワークを使わない(git はローカルのリポジトリにだけ使う)。
- test_project.py の get_project_files は、`GIT_CONFIG_GLOBAL` を空のファイルに、`GIT_CONFIG_NOSYSTEM=1` にして呼ぶ。利用者のグローバルな除外設定などに結果が左右されないため。

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
`UV_PROJECT_ENVIRONMENT=<winpython\python>` にして、次を実行する。環境変数はこの呼び出しの子プロセスにだけ渡す。
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
- `uv export` の直後(WinPython のダウンロード前)に、requirements.txt の各依存(`name==version`)を uv.lock の `[[package]]` と照合する。`source = { registry = "..." }` が `https://pypi.org/simple` 以外なら、該当する依存を並べてエラーにする(`get_non_pypi_requirements`)。
- 環境マーカーで index を切り替えると、uv.lock に同じ `name==version` が registry 違いで複数入る。requirements.txt からはどれが選ばれたか分からないため、1つでも PyPI 以外があればエラーにする(安全側。Windows 以外向けの非公開 index でも止まる)。(PR #11 のレビューで判明)
- requirements.txt に出ない依存(選ばなかった group など)は見ない。名前は PEP 503 の正規化(`[-_.]+` → `-`、小文字)で照合する。URL の末尾の `/` は区別しない。
- index は pyproject の `[[tool.uv.index]]` ではなく、uv.lock(実際に解決された結果)で見る。
- PyPI のミラーを既定の index にしている環境(`UV_DEFAULT_INDEX` など)では、PyPI のパッケージでもエラーになる。(推測。未検証) その場合は uv モードを使う。

### 設定の型
- 決まった値だけを受け付ける型を足した。`SETTING_TYPES` の値をタプルにすると、その中の値だけを受け付け、先頭の値が既定値になる。設定ファイルと引数の両方で、大文字小文字も区別して確かめる(未知のキーと同じ扱い)。

### 確認の記録(2026-10-06、uv 0.11.16、PowerShell 版)
- 擬似の非公開 index(`python -m http.server` で配った PEP 503 の simple index。`explicit = true`)にだけある `mylib` と requests に依存する 3.13 の試験用プロジェクト:
  - uv モード: ビルド成功。
  - pip モード: WinPython のダウンロード前に「PyPI 以外の index から取る依存があり…」のエラーで止まった。
- PyPI だけの試験用プロジェクト(3.12(`.python-version` は `3.12.2`)/ 3.13、requests に依存): uv / pip の両モードでビルド成功。
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
- 7z を作れないときは、zip にフォールバックせずエラーで止める。WinPython のダウンロード前に、作業用フォルダで小さな 7z を試しに作って確かめる(`assert_seven_zip_writable`)。ログに `tar --version` を出す。
- 外側 ZIP の中では無圧縮で格納する(§13)。

### 搬入先での展開
- 7-Zip、または `tar.exe -C winpython -xf winpython.7z`(先に `winpython\` を作る)で展開する。
- Windows 11 の新しいビルドのエクスプローラーは 7z を展開できるはず。(未確認)
- Windows 10 や古いビルドの `tar.exe` は 7z(LZMA2)を書けない・読めない可能性がある。(推測。未確認)

### 確認の記録(2026-10-06、Windows 11 26200、tar.exe は bsdtar 3.8.8 / libarchive 3.8.8 / liblzma 5.8.1、PowerShell 版)
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
  - 7z: 成功。winpython.7z は 16.9 MB(既定の zip のビルドでは winpython.zip が 26.7 MB)。
  - 既定(zip): 成功し、従来どおり `winpython.zip` が入った。
  - 形式に `7Z` を指定すると、設定の値のエラーで止まった。
- 成果物を日本語と空白を含むパスに展開し(外側は `Expand-Archive`、winpython.7z は `tar.exe -xf` と 7-Zip の両方)、`python -I -c "import <パッケージ>, requests, pip"` が通った。
- `tar -tf` の一覧はコンソールのコードページで出力されるので、日本語の名前が化けて見える。7z の中には UTF-16 で入っており、展開すれば正しい名前になる。

## 17. ログ・メッセージとコードの言語

issue #17。

### 方式(確定、2026-10-06)
- 画面とログに出す文言は英語にする。対象: `log.write_log` / `print` / `log.write_step` の見出し / 例外(`BuildError` など)のメッセージ / GUI(フォルダ選択ダイアログのタイトル、ポップアップのタイトルと本文)/ 引数のヘルプ。
- コード中のコメント、docstring、テストの関数名・クラス名も英語にする。
- テストのデータ(日本語のファイル名・フォルダ名)は、日本語のパスを扱えるか確かめるためのものなので日本語のまま残す。
- `docs/` と README は日本語のまま。

## 18. Python への移行

issue #22。実装を PowerShell から Python に移した。対象プロジェクトの指定方法、設定ファイル、ビルドの流れ、成果物の構成(§2〜§16)は変えていない。変わったのは、実装と引数の名前だけ。

### 理由(確定)
- 利用者兼レビュアーが ps1 を読み慣れておらず、変更のレビューが形だけになるため。
- PowerShell 特有の落とし穴(5.1 と 7 の違い、BOM、外部コマンドへの引数のクォート、`$LASTEXITCODE` の確かめ忘れ、関数の戻り値に余計な出力が混ざる、要素が1つの配列が配列でなくなる、など)で、実装の間違いが起きやすいため。
- 手書きしていた処理(TOML の読み込み、ZIP の区切り文字など)を、標準ライブラリで書けるため。

### 方式(確定)
- ビルドする PC は Windows のまま。成果物は Windows 専用の WinPython を含み、ビルド時に `python.exe` を実行して確かめる(§4 手順 7・9)ため。
- 実行時の依存は標準ライブラリだけ。`tomllib` を使うので Python 3.11 以上。インタープリターは uv が用意する。
- 引数はケバブケースにした(§8 の表)。既存の呼び出し(`-ProjectRoot` など)とは互換がないため、バージョンを 0.2.0 に上げた。
- 設定ファイル(`config\settings.json`、`settings.local.json`)のキー名と意味は変えていない。
- 個別の置き換え:
  - フォルダ選択ダイアログ: `tkinter.filedialog.askdirectory`(§3)。
  - ポップアップ: `ctypes` で Win32 の `MessageBoxW`(tkinter に頼らない)。
  - ダウンロードフォルダ: `ctypes` で `SHGetKnownFolderPath`(PowerShell 版と同じ API)。
  - ログ: `Start-Transcript` を使わず、自前の関数でコンソールとログファイルに書く(§7)。
  - 外部コマンド: `subprocess` に引数をリストで渡す。終了コードは毎回確かめる。
  - pyproject.toml / uv.lock: `tomllib`。PowerShell 版にあった「`name` / `version` が1行の文字列で書かれている前提」の制限はなくなった。
  - ZIP: `zipfile`。7z: 従来どおり System32 の `tar.exe`。SHA-256: `hashlib`。ダウンロード: `urllib.request`。
  - export-ignore の問い合わせは、`git check-attr --stdin` でまとめて1回にした(PowerShell 版はコマンドラインの長さの上限のため、分けて呼んでいた)。
- 移行で直した PowerShell 版の制限: .bat 経由で `-PruneWinPython:$false` を渡せなかった(`--no-prune-winpython` で渡せる)。

### 確認の記録(2026-10-07、Windows 11 26200、uv 0.11.16、git 2.54.0)
- 同じ試験用プロジェクト(3.13、requests に依存、`src\` レイアウト、`/tests/ export-ignore`、未 add のファイルと日本語・空白を含む名前のファイルあり)を、PowerShell 版(PS 5.1)と Python 版(Python 3.13.12)の両方でビルドした。設定は既定(uv、prune あり、zip)、`installer` pip、`winPythonArchiveFormat` 7z、`trackedOnly` の4通り。8回とも成功した。
  - 外側 ZIP のエントリ一覧(名前とサイズ)は、4通りすべてで一致した。
  - winpython 内のファイル一覧(名前とサイズ。zip は 4508 / pip モードは 4529 項目、7z は展開して比べた)と `odekake-src.pth` の中身は、4通りすべてで一致した。
  - ログに出る依存一覧は、4通りすべてで一致した。ログ全体も、時刻・パス・サイズ・SHA-256・所要時間・インタープリターの行と、check-attr の呼び方(`--stdin`)以外は一致した。
  - 違ったのは、外側 ZIP の中の winpython.zip / winpython.7z の格納方法だけ。PowerShell 版(.NET Framework の `NoCompression`)は「deflate の無圧縮ブロック」(圧縮方式 8)、Python 版は本当の無圧縮(圧縮方式 0、stored)になった。どちらも無圧縮の格納で、§13 の決まりは満たす。
  - 所要時間は、既定の設定で PowerShell 版が約 13 秒、Python 版が約 22 秒だった(1回ずつの計測)。
- Python 版の4つの成果物を、日本語と空白を含むパスに展開し(外側と winpython.zip は `Expand-Archive`、winpython.7z は `tar.exe -xf`)、`python -I -c "import <パッケージ>, requests, pip"` が通った。日本語のファイル名も正しく展開された。
- エラー系(git でない、未知のキー、未対応の Python、VERSION なし、installer の値が不正、対象フォルダなし)のメッセージは、引数の名前(`-Installer` → `--installer` など)以外は PowerShell 版と一致した。終了コードは 1。
- `build-offline.bat` を別のフォルダからコマンドで呼び、引数(`--groups dev` など)が渡ること、ビルドが成功すること、失敗時に終了コード 1 が返ること、`pause` することを確かめた。
- ダウンロードフォルダの取得(`SHGetKnownFolderPath`)は、シェルの `shell:Downloads` と同じパスを返した。
- `uv run pytest` は、Python 3.13.12 と 3.11.15 の両方で 105 件すべて成功した。
- WinPython のダウンロード(`get_winpython_archive` を単体で呼んだ。3.14 の zip): ダウンロードして SHA-256 が一致した。2回目はキャッシュを使った。キャッシュを1バイト壊すと、ダウンロードし直した。
- 未確認: `build-offline.bat` のダブルクリックで出るフォルダ選択ダイアログ(tkinter)と、完了・失敗のポップアップの表示(目視が必要)。
