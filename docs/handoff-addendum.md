# Handoff 補足(2026-10-05 Claudeチャットでの検討結果)
handoff-original.md を前提に、その後変わった点・判明した点・未確定点。矛盾する場合はこのファイルを優先。

## 1. スコープ変更(確定)
- 作るのは特定リポジトリのWinPython化ではなく、任意の uv プロジェクトに使える汎用 PS1 スクリプト。
- スクリプトはこの専用リポジトリに置く。
- そのため original の以下は無効:
  - §1「$PSScriptRoot から repo root を解決」→ 対象プロジェクトは -ProjectRoot(必須引数)で受け取る。
  - 「repository-local」「対象 repo を inspect して決める」系 → 対象ごとに変わる部分は引数で受ける。

## 1.5 成果物の構成(確定、2026-10-05)
original §7 の A/B(ソース同梱 / pip install)はどちらも採らない。開発時の `.venv` を WinPython に置き換えるイメージ。

```
<project>.zip
├─ winpython.zip   ← WinPython + 依存ライブラリ。自分のコードは含まない
├─ src\            ← 自分のコード(ファイルのまま。搬入先で編集する可能性あり)
├─ pages\
└─ (その他 gitignore されていないファイル)
```

- WinPython を二重 ZIP にするのは、ファイル数の多いランタイムを1ファイルで運ぶため。また依存が近い別プロジェクトで流用する可能性がある。
- 搬入先では `<project>\winpython\` に展開する規約とする。ビルド時に WinPython 配布物の最上位フォルダ(`WPy64-...` 等)を取り除き、winpython.zip を展開すると直接 `winpython\python\...` になるようにする。
  - `.venv` という名前は使わない。uv が壊れた venv とみなして作り直す恐れがある(推測)。
- 対象プロジェクトは `[build-system]`(hatchling 等)を持ち、開発時は uv が自分のコードを editable インストールしている前提。そのため自分のコードはインストールせず、site-packages に `.pth` を1つ置いて `src` を import パスに加える(例: `..\..\..\src`。正確な相対パスは展開後の構造で確定)。
  - 「`<project>\winpython\` に展開し、コードは `<project>\src\`」という規約を守るプロジェクト間なら、`.pth` は共通で使える。
- uv export は `--no-emit-project` 相当で自分のプロジェクトを除外する(フラグ名は要確認)。
- 外側の ZIP に入れるファイル: 既定は「gitignore されていない全ファイル」(未 add のファイルを含む。`git ls-files --cached --others --exclude-standard` 相当)。設定で「add 済みのみ」に切り替えられる。
- 起動は `python -m <module>` 形式を推奨する。pip が生成する `.exe` ランチャーは絶対パスを埋め込むため、移設で壊れる可能性が高い。
- 設定は設定ファイルと引数の両方で指定できるようにする。
  - 設定ファイルは JSON 形式で、対象プロジェクト直下に置く。`-ConfigPath` で別のファイルも指定できる。
  - YAML / TOML / psd1 は採らない。YAML と TOML は PowerShell に標準のパーサーがなく、psd1 は PowerShell を書かない人に馴染みがない。
  - JSON にはコメントを書けない(PS 5.1)が、許容する。
- 完成した ZIP の出力先: 既定はユーザーのダウンロードフォルダ。`%USERPROFILE%\Downloads` を決め打ちにせず、Windows の既知フォルダとして場所を取得する(フォルダを移設している環境に対応するため)。設定や引数で変更できる。
- 外側 ZIP の名前: `<プロジェクト名>-<バージョン>_yyyymmddTHHmmss.zip`。タイムスタンプ(ローカル時刻)は常に付ける。そのため出力の上書きは発生しない。
  - バージョンは pyproject.toml の `version` から読む。dynamic の場合は `<ProjectRoot>\VERSION`(1行。前後の空白と改行は除去)から読む。dynamic で VERSION ファイルもない場合はエラー。
  - 内側の ZIP は `winpython.zip` で固定。
- 外側 ZIP の SHA-256: ハッシュファイルは作らない(持ち出し申請の対象を1ファイルに保つため。ZIP 自身のハッシュを ZIP 内に入れることは原理的に不可能)。
  - ビルド時に画面へ表示し、このリポジトリの `logs\yyyymmddTHHmmss_<name>.log` にも記録する。`<name>` は pyproject.toml の `name`。ログにはビルド全体のログも書く。ログは持ち出さない。
  - タイムスタンプはビルド開始時に1回だけ取得し、ログと ZIP の両方に同じ値を使う。
  - ZIP の中に各ファイルのハッシュ一覧(SHA256SUMS)は入れない。
  - 用途: 持ち出し申請の書類に値を記載し、搬入先で `Get-FileHash` と照合する。
  - `logs/` と `.build/` は、このリポジトリで gitignore する。

- 対象プロジェクトの指定(pyproject.toml と uv.lock があるフォルダ):
  - `-ProjectRoot` で指定されていれば、それを使う。
  - 指定がなければ、フォルダ選択ダイアログ(.NET `FolderBrowserDialog`)を出す。キャンセルしたら何もせず終了する。
  - pyproject.toml または uv.lock がなければエラー。
  - GUI はフォルダ選択だけ。その他の設定は設定ファイルと引数で行う。
  - 要検証: PS 5.1 では古い形式のダイアログになる可能性がある。PS 7 の標準の実行モードが STA かどうか。

## 2. 確認済みの事実(2026-10-05、Web調査)
- WinPython は 2026-03 以降、dot / slim / dotf / slimf の4種のみ。最小は dot。
- 2026-03(2026-08-22)の dot は Python 3.13.15 と 3.14.7。exe と zip で配布、約28MB。zip なので標準機能で展開可能。
- exe と zip/7z は中身同一。
- 全ファイルの SHA-256 が md5_sha1.txt で公開 → 期待ハッシュを固定して検証可能。
- 2026-04 はベータ(10/4時点 b3)。安定版で固定するなら 2026-03。
- 参照: https://winpython.github.io/ , https://winpython.github.io/releases.html
- 未確認: 2026-03 dot zip の正確なURLとSHA-256、展開後のトップディレクトリ名。

## 3. 実装上の注意
- uv export はデフォルトでプロジェクト自身を出力する。ソース同梱方式なら --no-emit-project が必要(フラグ名は要確認)。インストール方式なら非 editable。
- pip 生成の console script ランチャー(.exe)は python.exe の絶対パスを埋め込むため、移設で壊れる可能性が高い。python -m 起動なら影響なし。
- PS 5.1/7 両対応なら ZIP 作成は System.IO.Compression.ZipFile 推奨(5.1 の Compress-Archive に難ありという認識。未検証)。

## 4. 未確定事項(提案のみ。ユーザー未承認)
1. ~~対象指定~~ → §1.5 で確定
2. Pythonバージョン: .python-version → 無ければ -PythonVersion。3.13/3.14 → URL+SHA256 の対応表。代替: 固定1本
3. ~~プロジェクト本体の扱い~~ → §1.5 で確定
4. smoke test: --version と pip check は常時。import は -ImportName 指定時のみ
5. 起動用 .bat: 初期版では生成しない(必要なら -EntryCommand)
6. PowerShell: 5.1/7 両対応
7. ~~成果物名~~ → §1.5 で確定
8. -Force: 出力の上書きはタイムスタンプで不要になった。残るのは WinPython の再ダウンロードのみ
9. 置き場所: 出力先は §1.5 で確定。キャッシュと作業用フォルダは案: このリポジトリの `.build\`
10. dev 依存: 最初から設定項目として持つ(確定)。既定は含めない(`--no-dev`)。項目名は未定
11. 設定ファイル: ファイル名(案: `odekake-winpython.json`)、引数との優先順位(案: 引数 > 設定ファイル > 既定値)。形式と置き場所は §1.5 で確定
