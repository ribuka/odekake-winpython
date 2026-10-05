# odekake-winpython 仕様(2026-10-06 確定版)

handoff-original.md の要件を、2026-10-05〜06 の検討で改めたもの。original と矛盾する場合はこのファイルを優先する。
旧 docs/handoff-addendum.md を整理し直したもので、検討の経緯は git 履歴を参照。

表記:
- **(確定)** はユーザー承認済み。
- **(推測)** **(未検証)** は裏付けがない。
- **(未決定)** はユーザーの判断待ち。勝手に確定しない。

---

## 1. 目的とスコープ

- 任意の uv プロジェクトを、オフラインの Windows 環境へ持ち出すための ZIP にする汎用 PowerShell スクリプト。特定リポジトリ専用ではない。(確定)
- スクリプトはこのリポジトリ(odekake-winpython)に置く。対象プロジェクトはスクリプトの外にある。(確定)
- original のうち、次の項目は無効:
  - §1「$PSScriptRoot から repo root を解決」: `$PSScriptRoot` は、このリポジトリ内のファイル(config, logs, .build)の場所を求めるのに使う。対象プロジェクトの場所は §3 で決める。
  - 「repository-local」「対象 repo を inspect して決める」: 対象ごとに変わる部分は、設定と引数で受け取る。
  - §7 の A/B(ソース同梱 / pip install): どちらも採らない。§2 を参照。
- 用語:
  - **対象プロジェクト**: ZIP にする uv プロジェクト。pyproject.toml と uv.lock があるフォルダ。
  - **このリポジトリ**: odekake-winpython。

## 2. 成果物の構成(確定)

開発時の `.venv` を WinPython に置き換えるイメージ。自分のコードは WinPython にインストールしない。

```
<name>-<version>_yyyymmddTHHmmss.zip      ← 外側 ZIP(持ち出し申請の対象。1ファイル)
├─ winpython.zip   ← WinPython + 依存ライブラリ。自分のコードは含まない
├─ src\            ← 自分のコード(ファイルのまま。搬入先で編集する可能性あり)
├─ pages\
└─ (その他、対象プロジェクトの gitignore されていないファイル)
```

- **winpython.zip を二重にする理由**: ファイル数の多いランタイムを1ファイルで運ぶため。依存が近い別プロジェクトで流用する可能性もある。
- **winpython.zip の中身**: WinPython 配布物の最上位フォルダ(`WPy64-313150` などバージョン由来の名前)を取り除いて詰め直す。展開すると直接 `python\`, `scripts\` ... が出てくる。
- **搬入先での規約**: winpython.zip は `<project>\winpython\` に展開する。フォルダ名は小文字の `winpython`。
  - `.venv` という名前は使わない。uv が壊れた venv とみなして作り直す恐れがある。(推測)
- **自分のコードの import**:
  - 対象プロジェクトは `[build-system]`(hatchling 等)を持ち、開発時は uv が自分のコードを editable インストールしている前提。
  - 自分のコードはインストールしない。代わりに `winpython\python\Lib\site-packages\` に `.pth` ファイルを1つ置き、中身を `..\..\..\..\src` にする。
  - 2026-10-06 に実機で確認済み: 新規作成した import 確認用パッケージを `src\` に置いて import でき、フォルダごと移設した後も import できた。
  - 同じ規約(`<project>\winpython\` + `<project>\src\`)を守るプロジェクト間なら、`.pth` は共通で使える。
  - `.pth` のファイル名(未決定。実装時に決めてよい)。
- **外側 ZIP に入れるファイル**:
  - 既定は、gitignore されていない全ファイル(未 add のファイルを含む。`git ls-files --cached --others --exclude-standard` 相当)。(確定)
  - `trackedOnly` で、add 済みのファイルだけに切り替えられる。(確定)
  - `exclude` で、指定したパターンに当たるファイルを除外できる。(確定)
- **外側 ZIP の最上位**: ZIP 直下にファイルを置くか、`<name>\` フォルダを1段挟むか。(未決定)
- **起動用 .bat**: 対象アプリを起動する .bat は生成しない。起動方法はユーザーが搬入先で自分で整える。(確定)

## 3. 対象プロジェクトの指定(確定)

- `-ProjectRoot` が指定されていれば、それを使う。
- 指定がなければ、フォルダ選択ダイアログ(.NET `FolderBrowserDialog`)を出す。キャンセルしたら何もせず終了する。
- GUI はフォルダ選択だけ。その他の設定は設定ファイルと引数で行う。
- pyproject.toml または uv.lock がなければエラー。
- 対象が git リポジトリでない場合(ファイル収集に git を使うため): エラーにする案。(未決定)

## 4. ビルドの流れ

1. ビルド開始時刻を1回だけ取得する。ZIP 名とログ名の両方に同じ値を使う。
2. 設定を読む(§8)。対象プロジェクトを決める(§3)。
3. pyproject.toml から name と version を読む(§6)。Python バージョンを決める(§5)。
4. 依存を書き出す: `uv export --frozen --no-emit-project --no-default-groups [--group X ...] [--extra Y ...] --format requirements-txt -o <tmp>`
   - pyproject の `default-groups` は無視し、`groups` に指定したものだけを含める。既定では dev も含めない。
5. WinPython を用意する: `.build\` にキャッシュする。期待 SHA-256 と一致しなければ、自動でダウンロードし直す。`-Force` は設けない。
6. `.build\` の作業用フォルダに、搬入先と同じ配置(`<project>\winpython\` + `src\` …)で組み立てる。
7. `winpython\python\python.exe -m pip install -r <tmp>` を実行する。host の pip や PATH には頼らない。
8. `.pth` を置く。
9. 動作確認(毎回実行し、失敗したらビルドも失敗):
   - `python --version`
   - `python -m pip check`
   - `python -c "import <importName>"`(`.pth` の検証も兼ねる)
10. `pruneWinPython` が有効なら、不要なランチャー等を削除する(§8)。
11. winpython.zip を作る。対象プロジェクトのファイルを集め、外側 ZIP を作る。
12. 外側 ZIP の SHA-256 を計算し、画面とログに出す。
13. 結果をポップアップで表示する(§9)。

- original §9 の「残骸の除去」(pip キャッシュ・一時 requirements など)は踏襲する。役割の分からないものは消さない。

## 5. WinPython と Python バージョン(確定)

- 使うのは WinPython の **dot** 版(最小構成)。2026-03 リリース(安定版)で固定する。
- Python バージョンは `.python-version` から読む。なければ `pythonVersion` で指定する。
- マイナーバージョン(3.13 等)で、次の対応表を引く。表にないバージョンはエラーにする。最新版へのフォールバックはしない。
- URL は規則から組み立てず、完全な形で対応表に持つ。タグ名 `17.12.20260522/WinPython` が、リリース名とも日付とも一致しないため。

| Python | URL | SHA-256 | サイズ |
|---|---|---|---|
| 3.13 (3.13.15) | https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.13.15.0dot.zip | `28e36408f0140c50b207ea059a599c664564e68a3cbb835f03a71f4601efd8f1` | 28,158,845 |
| 3.14 (3.14.7) | https://github.com/winpython/winpython/releases/download/17.12.20260522/WinPython/WinPython64-3.14.7.0dot.zip | `dbabedfb50eeb3c2c63dc43c9cb6239eae4a582c3bfd9a5f2ffd00a09b49a527` | 28,663,262 |

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
| `pythonVersion` | `-PythonVersion` | 文字列 | `.python-version` の値 |
| `outputDir` | `-OutputDir` | パス | ダウンロードフォルダ |
| `trackedOnly` | `-TrackedOnly` | 真偽値 | false(未 add のファイルも含める) |
| `groups` | `-Groups` | 文字列の配列 | 空(dev も含めない) |
| `extras` | `-Extras` | 文字列の配列 | 空 |
| `exclude` | `-Exclude` | 文字列の配列 | 空。外側 ZIP から除外するパターン |
| `pruneWinPython` | `-PruneWinPython` | 真偽値 | false |
| `importName` | `-ImportName` | 文字列 | pyproject の `name`(`-` → `_`) |
| `noPopup` | `-NoPopup` | 真偽値 | false |

- `projectRoot` と `configPath` は設定キーにしない。設定ファイルの場所がそれらで決まるため。
- `exclude` は git pathspec の exclude 指定で実現する想定。git pathspec と .gitignore の書式は完全には同じではない。どちらの書式に合わせるか(未決定。実装時に提案すること)。
- `pruneWinPython` の目的は、容量削減ではなく、展開時に目に入るノイズを減らすこと。対象は WinPython 最上位の階層だけ。
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
- スクリプトと .bat のファイル名・配置(original の例は `scripts\build-offline.ps1`)。(未決定。実装時に提案すること)

## 10. このリポジトリの構成

```
odekake-winpython\
├─ <script>.ps1 / <script>.bat   ← 名前・配置は未決定
├─ config\settings.json          ← コミットする
├─ config\settings.local.json    ← gitignore
├─ logs\                         ← gitignore
├─ .build\                       ← gitignore(WinPython キャッシュ、作業用フォルダ)
└─ docs\
```

## 11. 確認済みの事実

- WinPython は 2026-03 以降、dot / slim / dotf / slimf の4種のみ。最小は dot。exe と zip/7z は中身同一。2026-04 はベータ(10/4 時点で b3)。
- 3.13 dot zip の中身(実物で確認):
  - 最上位は `WPy64-313150`。その下に `python\`, `scripts\`, `notebooks\`, `wheelhouse\`, 各種ランチャー .exe, `license.txt` がある。
  - `python\python.exe`, `python\Lib\site-packages\` がある。pip 26.2.1 を同梱。`._pth` ファイルがないので、`.pth` が有効。
  - `scripts\env.bat` は、PATH(`python\`, `python\Scripts` 等)、`PYTHONIOENCODING=utf-8`、`HOME` を設定する。
  - 同梱の wppm に、pip のランチャーを移設可能にする処理(`--movable`)がある。console script の .exe が移設に耐える可能性がある。(未検証。本スクリプトはランチャーを使わないので影響なし)
- PowerShell 5.1 と 7.6.6 は、どちらも既定で STA。フォルダ選択ダイアログを出せる。
- uv 0.11.16 の `uv export` に次のフラグがある: `--frozen`, `--no-dev`, `--no-emit-project`, `--no-hashes`, `--no-default-groups`, `--group`, `--all-groups`, `--extra`, `--all-extras`, `--format`, `-o/--output-file`。
- 参照: https://winpython.github.io/ , https://winpython.github.io/releases.html

## 12. 実装時に確認すること

- uv export は、既定でハッシュを出力する。pip はハッシュ照合モードになり、ハッシュのない行(path/git 依存など)があると失敗する。(推測) ハッシュ付きのまま pip に渡せるか確認する。
- PS 5.1 のフォルダ選択ダイアログの見た目。古いツリー形式になる可能性がある。
- ZIP の作成には `System.IO.Compression.ZipFile` を使う。5.1 の Compress-Archive には難がある。(未検証の認識)
- 受け入れ基準は original の Acceptance Criteria を踏襲する。別の展開先パスでのテストを含む。
