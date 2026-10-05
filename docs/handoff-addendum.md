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
- uv export はデフォルトでプロジェクト自身を出力する。§1.5 の方式では `--no-emit-project` 相当で除外する(フラグ名は要確認)。
- uv export はデフォルトでハッシュを出力するはず。pip はハッシュ照合モードになり、ハッシュのない行(path/git 依存など)があると失敗する(推測、要確認)。
- pip 生成の console script ランチャー(.exe)は python.exe の絶対パスを埋め込むため、移設で壊れる可能性が高い。python -m 起動なら影響なし。
- PS 5.1/7 両対応なら ZIP 作成は System.IO.Compression.ZipFile 推奨(5.1 の Compress-Archive に難ありという認識。未検証)。
- PS 5.1 の Start-Transcript は外部コマンド(uv, pip)の出力を記録しないことがある(推測)。外部コマンドの出力は明示的にログへ書き出す。
- 作業用フォルダも搬入先と同じ配置(`<project>\winpython\` + `src\`)で組み立て、`.pth` が効くことを import の確認で検証する。

## 4. 決定事項(2026-10-06 確定)
1. 対象指定 → §1.5
2. Python バージョン: `.python-version` から読み、なければ設定か引数で指定する。マイナーバージョン(3.13 等)で「URL + SHA-256」の対応表を引く。表にないバージョンはエラー(latest へのフォールバックはしない)。
3. プロジェクト本体の扱い → §1.5
4. 動作確認: `python --version`、`pip check`、`import <パッケージ名>` を毎回実行する。パッケージ名は pyproject の `name` の `-` を `_` に置き換えたもの。設定で上書きできる。
5. 起動用 .bat:
   - アプリ起動用の .bat は生成しない。対象アプリの起動方法はユーザーが搬入先で自分で整える。
   - 本スクリプトを起動する .bat をこのリポジトリに置く(PowerShell スクリプトはダブルクリックで実行できないため)。`powershell.exe` 固定で `-NoProfile -ExecutionPolicy Bypass -File "%~dp0<script>.ps1" %*` を実行し、成功・失敗にかかわらず毎回 pause する。
   - 終了時に結果をポップアップ(MessageBox)で表示する。成功時は出力パスと SHA-256、失敗時はエラー内容とログのパス。既定で表示し、引数・設定で抑止できる(例: `-NoPopup`)。
6. PowerShell: 5.1/7 両対応。
7. 成果物名 → §1.5
8. `-Force` は設けない。キャッシュ済み WinPython が期待 SHA-256 と一致しなければ自動で再ダウンロードする。
9. 置き場所: 出力先は §1.5。キャッシュと作業用フォルダはこのリポジトリの `.build\`。
10. dev 依存: 設定項目として持つ。既定は含めない(`--no-dev`)。
11. 設定ファイル: `<ProjectRoot>\odekake-winpython.json`。優先順位は 引数 > 設定ファイル > 既定値。

## 5. 未確定・要確認
- 設定項目と引数の名前(未 add ファイルを含めるか、出力先、Python バージョン、dev 依存、import 名、ポップアップ抑止)。
- 要確認の事実: 2026-03 dot zip の URL・SHA-256・展開後の構造、`uv export` の正確なフラグ、PS 7 の STA、PS 5.1 のフォルダ選択ダイアログの見た目。
