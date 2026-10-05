# odekake-winpython

uv プロジェクトを、インターネットにつながらない Windows PC へ持ち出すための ZIP にするスクリプトです。
Python の実行環境には WinPython(dot 版)を使い、依存ライブラリを入れた状態で同梱します。

詳しい仕様は [docs/spec.md](docs/spec.md) を参照してください。

## 必要なもの(ZIP を作る PC)

- Windows の PowerShell 5.1 または 7
- `git` と `uv` に PATH が通っていること
- インターネット接続(初回に WinPython をダウンロードするため。2回目以降は `.build\` のキャッシュを使います)

## 対象プロジェクトの条件

- `pyproject.toml` と `uv.lock` がある
- git リポジトリである
- 自分のコードが `src\` の下にある(`[build-system]` を持つ構成)
- Python 3.13 か 3.14 を使う(`.python-version` などで指定)

## 使い方

### ダブルクリックで実行する

1. `build-offline.bat` をダブルクリックします。
2. フォルダ選択ダイアログで、対象プロジェクトのフォルダを選びます。
3. 終わると、ポップアップに出力先と SHA-256 が表示されます。

出力先は、既定ではダウンロードフォルダです。

### コマンドで実行する

```bat
build-offline.bat -ProjectRoot D:\work\myproject
```

主なオプション:

| オプション | 説明 |
|---|---|
| `-ProjectRoot <フォルダ>` | 対象プロジェクト。省略するとフォルダ選択ダイアログが出ます |
| `-OutputDir <フォルダ>` | 出力先(既存のフォルダを指定) |
| `-Groups a,b` | 含める依存グループ。既定では dev も含めません |
| `-Extras a,b` | 含める extras |
| `-Exclude 'docs/**','tests'` | ZIP から除外するファイル(git pathspec の書式) |
| `-TrackedOnly` | git に add 済みのファイルだけを入れる |
| `-PythonVersion 3.13` | Python のバージョンを指定(`.python-version` より優先) |
| `-ImportName <名前>` | 動作確認で import するパッケージ名(既定は pyproject の name) |
| `-NoPopup` | 終了時のポップアップを出さない |

### 設定ファイル

毎回同じオプションを使う場合は、設定ファイルに書けます。キー名はオプション名の先頭を小文字にしたものです。

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

### WinPython の不要なファイルの削除

`config\settings.json` で `"pruneWinPython": true` にしているので、通常は WinPython の最上位から次のファイルとフォルダを削除します。
展開したときに、使わないファイルが目に入らないようにするためです。

- 削除する: `Jupyter Lab.exe`, `Jupyter Notebook.exe`, `Spyder.exe`, `Spyder reset.exe`, `VS Code.exe`, `notebooks\`, `wheelhouse\`
- 残す: `python\`, `scripts\`, `IDLE (Python GUI).exe`, `WinPython Command Prompt.exe` など

削除したくないときは、`config\settings.local.json` に `"pruneWinPython": false` と書きます。
(`build-offline.bat` に `-PruneWinPython:$false` を付けると、エラーになります。)

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
ファイル名は、`build-offline.ps1` の `$WinPythonTable` にある URL の末尾と同じです。
置いたファイルが正しいかは SHA-256 で照合し、一致しなければダウンロードし直します。

## 出力される ZIP

ファイル名は `<name>-<version>_yyyymmddTHHmmss.zip` です。中身は次のとおりです。

```
myproject-1.0.0_20261006T120000.zip
├─ winpython.zip   ← WinPython と依存ライブラリ
├─ src\            ← 自分のコード
└─ (その他、gitignore されていないファイル)
```

SHA-256 は ZIP には入りません。画面・ポップアップ・ログ(`logs\`)に出るので、必要なら控えてください。

## 持ち出し先での準備

1. 外側の ZIP を、好きなフォルダ(例: `D:\apps\myproject\`)に展開します。
2. その中の `winpython.zip` を、同じフォルダの `winpython\` に展開します(フォルダ名は小文字の `winpython`)。

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
