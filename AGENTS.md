# odekake-winpython

- uv プロジェクトを WinPython ベースのオフライン持ち出し用 ZIP にする、汎用 PowerShell スクリプトのリポジトリ。
- Always respond in Japanese.

## 作業ルール
- docs/spec.md の **(未決定)** はユーザーの判断待ち。勝手に確定しない。「実装時に提案すること」とあるものは、案を出して承認を得る。
- ユーザーは対等で批判的な技術パートナーを求めている。前提や設計の問題は率直に指摘し、推測と確認済み事実を分けること。
- 仕様に関わる決定や判明した事実は、その都度 docs/spec.md に反映する。

## Github

### Commit

- Before creating a commit, read `.agents/docs/commit.md` and follow it.
- コミット前に、個人情報(ユーザー名、メールアドレス、`C:\Users\...` などのローカルパス、端末名、トークン)が入っていないか確認する。
- `config/settings.json` には個人のパスを書かない(個人用は `settings.local.json`)。

### Pull request

- When creating a pull request, read `.agents/docs/pull-request.md` and follow it.

## Temporary files

- Create all temporary scripts and investigation files under `tmp/` at the repository root.
- NEVER create temporary files elsewhere; delete them when the task is complete.
