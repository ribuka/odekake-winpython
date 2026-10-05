# Handoff 補足(2026-10-05 Claudeチャットでの検討結果)
handoff-original.md を前提に、その後変わった点・判明した点・未確定点。矛盾する場合はこのファイルを優先。

## 1. スコープ変更(確定)
- 作るのは特定リポジトリのWinPython化ではなく、任意の uv プロジェクトに使える汎用 PS1 スクリプト。
- スクリプトはこの専用リポジトリに置く。
- そのため original の以下は無効:
  - §1「$PSScriptRoot から repo root を解決」→ 対象プロジェクトは -ProjectRoot(必須引数)で受け取る。
  - 「repository-local」「対象 repo を inspect して決める」系 → 対象ごとに変わる部分は引数で受ける。

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
1. 対象指定: -ProjectRoot 必須(専用リポジトリ化で事実上確定、最終承認は未)
2. Pythonバージョン: .python-version → 無ければ -PythonVersion。3.13/3.14 → URL+SHA256 の対応表。代替: 固定1本
3. プロジェクト本体: 既定 A(ソース同梱、--no-emit-project、git archive HEAD でコピー)、-InstallProject で B。A は未コミット変更が入らない。B は build-system 必須で console script が移設で壊れうる
4. smoke test: --version と pip check は常時。import は -ImportName 指定時のみ
5. 起動用 .bat: 初期版では生成しない(必要なら -EntryCommand)
6. PowerShell: 5.1/7 両対応
7. 成果物名の <version>: プロジェクト版か WinPython 版か未定。dynamic version だと静的に読めない
8. -Force: 再DLと出力上書きを別スイッチに分ける案
9. .build/ と dist/ の置き場所: 対象プロジェクト側 / このリポジトリ側 / 引数 — 未定
10. dev 依存: --no-dev 固定で開始する案
