# odekake-winpython

uv プロジェクトを、インターネットにつながらない Windows PC へ持ち出すための ZIP にするスクリプトです。
Python の実行環境には WinPython(dot 版)を使い、依存ライブラリを入れた状態で同梱します。

詳しい仕様は [docs/spec.md](docs/spec.md) を参照してください。

## 必要なもの(ZIP を作る PC)

- Windows
- `git` と `uv` に PATH が通っていること
  - スクリプト自体は Python(3.11 以上)で書かれていますが、Python は uv が用意するので、別に入れる必要はありません。
- インターネット接続(初回に WinPython をダウンロードするため。2回目以降は `.build\` のキャッシュを使います)

## 対象プロジェクトの条件

- `pyproject.toml` と `uv.lock` がある
- git リポジトリである
- 自分のコードが `src\` の下にある(`[build-system]` を持つ構成)
- `build_offline.py` の `WINPYTHON_TABLE` に載っている版(現在は 3.12 / 3.13 / 3.14 など)を使う(`.python-version` などで指定)。ほかの版は URL と SHA-256 を追加すれば使える

## 使い方

### ダブルクリックで実行する

1. `build-offline.bat` をダブルクリックします。
2. フォルダ選択ダイアログで、対象プロジェクトのフォルダを選びます。
3. 終わると、ポップアップに出力先と SHA-256 が表示されます。

出力先は、既定ではダウンロードフォルダです。

### コマンドで実行する

```bat
build-offline.bat --project-root D:\work\myproject
```

主なオプション:

| オプション | 説明 |
|---|---|
| `--project-root <フォルダ>` | 対象プロジェクト。省略するとフォルダ選択ダイアログが出ます |
| `--output-dir <フォルダ>` | 出力先(既存のフォルダを指定) |
| `--groups a b` | 含める依存グループ。既定では dev も含めません |
| `--extras a b` | 含める extras |
| `--exclude "docs/**" tests` | ZIP から除外するファイル(git pathspec の書式) |
| `--tracked-only` | git に add 済みのファイルだけを入れる |
| `--include-export-ignored` | `.gitattributes` で `export-ignore` が付いたファイルも入れる(既定では入れない) |
| `--python-version 3.13` | Python のバージョンを指定(`.python-version` より優先) |
| `--import-name <名前>` | 動作確認で import するパッケージ名(既定は pyproject の name) |
| `--installer uv` / `--installer pip` | 依存を入れる方法(既定は `uv`。下の「依存のインストール方法」を参照) |
| `--winpython-archive-format zip` / `--winpython-archive-format 7z` | WinPython を入れるアーカイブの形式(既定は `zip`。下の「WinPython のアーカイブ形式」を参照) |
| `--prune-winpython` / `--no-prune-winpython` | WinPython の不要なファイルを削除する / しない(下の「WinPython の不要なファイルの削除」を参照) |
| `--no-popup` | 終了時のポップアップを出さない |

- `--groups` などの複数の値は、`--groups a b`、`--groups a --groups b`、`--groups a,b` のどれでも指定できます。
- 真偽値のオプションは、`--tracked-only` / `--no-tracked-only` のように、`--no-` を付けると設定ファイルの値を打ち消せます。
- すべてのオプションは `build-offline.bat --help` で確認できます。

0.1.x(PowerShell 版)からは、オプションの名前が変わりました(`-ProjectRoot` → `--project-root` など)。設定ファイルはそのまま使えます。

### 設定ファイル

毎回同じオプションを使う場合は、設定ファイルに書けます。キー名は次のとおりです(オプション名とは書き方が違います)。

| キー | オプション |
|---|---|
| `outputDir` | `--output-dir` |
| `groups` / `extras` / `exclude` | `--groups` / `--extras` / `--exclude` |
| `trackedOnly` | `--tracked-only` |
| `includeExportIgnored` | `--include-export-ignored` |
| `pythonVersion` | `--python-version` |
| `importName` | `--import-name` |
| `installer` | `--installer` |
| `winPythonArchiveFormat` | `--winpython-archive-format` |
| `pruneWinPython` | `--prune-winpython` |
| `noPopup` | `--no-popup` |
| `initialDir` | (なし) |

- `config\settings.json` … 共通の設定(コミットされるので個人のパスは書かない)
- `config\settings.local.json` … 個人用の設定(git の管理外)

例(`config\settings.local.json`):

```json
{
  "outputDir": "D:\\export",
  "trackedOnly": true
}
```

優先順位は「オプション > settings.local.json > settings.json > 既定値」です。

フォルダ選択ダイアログの初期位置は、`initialDir` で指定できます(オプションはありません)。
個人のパスなので `config\settings.local.json` に書きます。`%USERPROFILE%` などの環境変数が使えます。
絶対パスで書いてください。フォルダがないときは、警告を出して初期位置なしでダイアログを開きます。

```json
{
  "initialDir": "%USERPROFILE%\\repos"
}
```

### 依存のインストール方法

既定では、`uv sync` で WinPython に依存を入れます(`"installer": "uv"`)。
`[tool.uv.sources]` と `[[tool.uv.index]]`(`explicit = true`)で指定した非公開の index にあるパッケージも入ります。
index の認証は、普段の `uv sync` と同じもの(`UV_INDEX_<NAME>_USERNAME` などの環境変数、keyring、`uv auth` など)を使います。

uv で問題が出たときは、従来の pip でも入れられます。

```json
{
  "installer": "pip"
}
```

pip では、PyPI 以外の index にあるパッケージは入りません。そうした依存があると、WinPython をダウンロードする前にエラーで止まります。
どちらの方法でも、依存の一覧は `uv export` で uv.lock から書き出し、ログに残します。

### WinPython のアーカイブ形式

既定では、WinPython を `winpython.zip` にして外側の ZIP に入れます。
`"winPythonArchiveFormat": "7z"` にすると、代わりに `winpython.7z` を入れます。zip より 4 割ほど小さくなります。

```json
{
  "winPythonArchiveFormat": "7z"
}
```

- 7z は Windows 標準の `C:\Windows\System32\tar.exe` で作ります。7-Zip は要りません。
- この PC の `tar.exe` が 7z を作れないとき(古い Windows など)は、WinPython をダウンロードする前にエラーで止まります。zip に切り替わることはありません。
- 持ち出し先で 7z を展開する手段(7-Zip など)が要ります。`Expand-Archive` では展開できません(下の「持ち出し先での準備」を参照)。

### WinPython の不要なファイルの削除

`config\settings.json` で `"pruneWinPython": true` にしているので、通常は WinPython の最上位から次のファイルとフォルダを削除します。
展開したときに、使わないファイルが目に入らないようにするためです。

- 削除する: `Jupyter Lab.exe`, `Jupyter Notebook.exe`, `Spyder.exe`, `Spyder reset.exe`, `VS Code.exe`, `notebooks\`, `wheelhouse\`
- 残す: `python\`, `scripts\`, `IDLE (Python GUI).exe`, `WinPython Command Prompt.exe` など

削除したくないときは、`config\settings.local.json` に `"pruneWinPython": false` と書くか、`--no-prune-winpython` を付けます。

### WinPython のキャッシュ

ダウンロードした WinPython の zip は、このリポジトリの `.build\downloads\` に保存されます。
2回目以降は、ファイルの SHA-256 が一致すれば、ダウンロードせずにこれを使います。

```
odekake-winpython\
└─ .build\
   └─ downloads\
      └─ WinPython64-3.13.15.0dot.zip
```

`.build\` は git の管理外なので、別の PC に clone したときや `.build\` を消したときは、ダウンロードし直しになります。
また、古い版の WinPython は、いずれ配布元から取れなくなるかもしれません。

そのため、この zip は別の場所(NAS など)に控えておくことを勧めます。
控えた zip を `.build\downloads\` に同じファイル名で置けば、ダウンロードせずに使います。
ファイル名は、`build_offline.py` の `WINPYTHON_TABLE` にある URL の末尾と同じです。
置いたファイルが正しいかは SHA-256 で照合し、一致しなければダウンロードし直します。

## 出力される ZIP

ファイル名は `<name>-<version>_yyyymmddTHHmmss.zip` です。中身は次のとおりです。

```
myproject-1.0.0_20261006T120000.zip
├─ winpython.zip   ← WinPython と依存ライブラリ(7z を選んだときは winpython.7z)
├─ src\            ← 自分のコード
└─ (その他、gitignore されていないファイル。`.gitattributes` で export-ignore のものを除く)
```

SHA-256 は ZIP には入りません。画面・ポップアップ・ログ(`logs\`)に出るので、必要なら控えてください。

## 持ち出し先での準備

1. 外側の ZIP を、好きなフォルダ(例: `D:\apps\myproject\`)に展開します。
2. その中の `winpython.zip` を、同じフォルダの `winpython\` に展開します(フォルダ名は小文字の `winpython`)。
   - `winpython.7z` のときは、7-Zip で展開するか、次のように Windows 標準の `tar.exe` で展開します(Windows 10 や古いビルドの `tar.exe` では展開できないことがあります)。

     ```powershell
     mkdir winpython
     tar.exe -C winpython -xf winpython.7z
     ```

```
D:\apps\myproject\
├─ winpython\
│  ├─ python\python.exe
│  └─ scripts\ ...
├─ src\
└─ ...
```

3. `winpython\python\python.exe` で、自分のコードを import できます(`src\` は自動で読み込まれます)。

アプリの起動用 .bat などは作られません。起動方法は持ち出し先で用意してください。

ZIP が壊れていないか確かめるには、持ち出し先で次を実行し、控えた SHA-256 と比べます。

```powershell
Get-FileHash .\myproject-1.0.0_20261006T120000.zip -Algorithm SHA256
```

## テスト(このリポジトリを修正する人向け)

`odekake\*.py` の一部に、pytest の単体テストがあります(`tests\`)。WinPython のダウンロードもネットワークも使わず、数秒で終わります。`git` は使います。

リポジトリのフォルダで次を実行します(初回は uv が pytest と ruff を入れます)。

```powershell
uv run pytest
uv run ruff check
uv run ruff format --check
```

PR では、GitHub Actions(ubuntu)で `ruff check` と pytest が走ります。Windows でしか動かないテストは、ubuntu では飛ばします。
