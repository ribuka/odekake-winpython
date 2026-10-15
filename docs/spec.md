# odekake-winpython 設計メモ

コードやテストからは読み取れないことだけを書く。次の2種類である。

- **設計の判断**: なぜそうしたか。検討して採らなかった案も含む。
- **確かめた事実**: 調べ直すと高くつくもの。日付を付ける。

ほかの情報は、次の場所にある。

- 利用者向けの使い方、オプションと設定の一覧: README.md
- 細かな挙動: コード(`build_offline.py`, `odekake\*.py`)とテスト(`tests\`)
- 作業の経緯、確認の記録、未着手の課題: GitHub の issue と PR、git 履歴

表記:
- **(推測)** **(未検証)**: 裏付けがない。
- **(未決定)**: ユーザーの判断待ち。勝手に決めない。
- 印のない記述は、決定済み、または確認済み。

---

## 目的とスコープ

- 任意の uv プロジェクトを、オフラインの Windows 環境へ持ち出すための ZIP にする。特定のリポジトリ専用ではない。
- **対象プロジェクト**(ZIP にする uv プロジェクト)は、このリポジトリの外にある。
- 対象プロジェクトには何も書かない。設定もログもキャッシュも、このリポジトリに置く。
- ビルドする PC も Windows に限る。成果物は Windows 専用の WinPython を含み、ビルドの途中で同梱の `python.exe` を実行して確かめるため。

## 成果物の構成

```
<name>-<version>_yyyymmddTHHmmss.zip   ← 外側 ZIP(持ち出し申請の対象。1ファイル)
├─ winpython.zip   ← WinPython と依存ライブラリ。自分のコードは含まない(7z を選んだときは winpython.7z)
├─ src\            ← 自分のコード(ファイルのまま)
└─ (その他、対象プロジェクトのファイル)
```

開発時の `.venv` を WinPython に置き換えるイメージで設計した。

- **winpython.zip を入れ子にする理由**: ファイル数の多いランタイムを1ファイルで運ぶため。依存が近い別のプロジェクトで流用できる可能性もある。
- winpython.zip からは、WinPython の配布物の最上位フォルダ(`WPy64-313150` など)を取り除く。展開すると、すぐに `python\` や `scripts\` が出てくる。
- 搬入先では `<project>\winpython\` に展開する決まりにする。
  - `.venv` という名前は使わない。uv が壊れた venv とみなして作り直す恐れがあるため。(推測)
- **自分のコードはインストールしない**。代わりに `winpython\python\Lib\site-packages\odekake-src.pth` を置き、中身を `..\..\..\..\src` にする。
  - 搬入先で `src\` を直接編集できる。
  - 同じ決まり(`winpython\` と `src\` が並ぶ)を守るプロジェクトどうしなら、`.pth` は共通で使える。
  - 対象プロジェクトは `[build-system]` を持ち、自分のコードが `src\` にあることを前提にする。
- 起動用の .bat は作らない。起動方法は、利用者が搬入先で用意する。
- 外側 ZIP の SHA-256 は、ファイルにして入れない。持ち出し申請の対象を1ファイルに保つため(ZIP 自身のハッシュを ZIP に入れることは、原理的にもできない)。画面・ポップアップ・ログに、`Get-FileHash` と同じ大文字の16進で出す。搬入先で `Get-FileHash` と照合するため。
- 各ファイルのハッシュ一覧(SHA256SUMS)も入れない。
- WinPython の中のファイルは、役割の分からないものは消さない。

### 外側 ZIP に入れるファイル

- 既定は、gitignore されていない全ファイル(未 add のファイルを含む)。`trackedOnly` で add 済みのファイルだけにできる。
- `.gitattributes` で `export-ignore` が付いたファイルは、既定で除く(`git archive` に合わせた。issue #12)。
  - `.gitattributes` は作業ツリーのものを読む(`git archive` の既定はコミット済みのもの)。未 add のファイルも ZIP に入れるので、それに合わせた。
  - 判定の方法は「確かめた事実」の git の項を参照。
- `exclude` は git の pathspec(glob)の書式にした。`:(exclude,glob)<パターン>` として git に渡す。
  - .gitignore とは違い、`*.log` は最上位のファイルにしか当たらない。どの階層にも当てるなら `**/*.log`。
- 対象プロジェクトに `winpython.zip`、`winpython.7z`、`winpython\` のどれかがあると、成果物と衝突するのでエラーにする(選んだ形式によらず3つとも。大文字小文字は区別しない)。
- ZIP のエントリ名の区切りは、必ず `/` にする。PowerShell 版で、.NET Framework の `ZipFile.CreateFromDirectory` が `\` を使い、ZIP の規格に反していたことから決めた(2026-10-06、実プロジェクトの成果物で判明)。

## 対象プロジェクトの読み取り

- 対象は git リポジトリでなければならない。ファイルの収集に git を使うため。
- `version` が dynamic のときは、対象プロジェクトの `VERSION` ファイル(1行)から読む。
- 名前の変換:
  - ZIP 名とログ名には、`name` の `_` を `-` に置き換えたものを使う(リポジトリのフォルダ名に寄せる)。
  - 動作確認で import する名前には、`name` の `-` を `_` に置き換えたものを使う。`importName` で上書きできる。
- ZIP 名には常にタイムスタンプを付ける。出力を上書きすることがない。
- 出力先の既定は、Windows の既知フォルダ(Downloads)として `SHGetKnownFolderPath` で取得する。`%USERPROFILE%\Downloads` と決め打ちにしないのは、フォルダを移している環境があるため。

## WinPython と Python バージョン

- 使うのは WinPython の **dot** 版(最小構成)。
- 版は、Python のマイナー番号ごとに1つのリリースに固定する(`build_offline.py` の `WINPYTHON_TABLE`)。
  - 選ぶ規則: その版の dot の .zip があり、SHA-256 を2か所(GitHub API の digest と https://winpython.github.io/md5_sha1.txt)で確かめられる、いちばん新しい安定版リリース。
  - 各マイナー系で、WinPython にある最新のパッチ版を同梱する。`.python-version` が `3.12.2` でも、3.12.10 を使う。パッチ版そのものの同梱は issue #5。
  - URL は規則から組み立てず、完全な形で持つ。タグ名(`17.12.20260522/WinPython`、`16.6.20250620final` など)がリリース名とも日付とも一致せず、ファイル名の大文字小文字(`WinPython64-` / `Winpython64-`)もリリースによって違うため。
  - 表にない版はエラーにする。最新版へのフォールバックはしない。
  - 3.11 以前は載せない。
- Python バージョンの優先順位は、**引数 > `.python-version` > 設定ファイル**。設定の一般の優先順位(引数 > 設定ファイル)の例外で、設定ファイルの値は `.python-version` がないときだけ使う。引数と `.python-version` のマイナー番号が違えば警告する。
- WinPython のキャッシュは、SHA-256 が一致すれば使い、違えばダウンロードし直す。`--force` は設けない。
- WinPython の zip を展開するときは、各ファイルの更新日時を zip のエントリの日時に戻す。`zipfile` は戻さないため。

## 依存のインストール(installer)

- 既定は uv モード。`uv sync` で、WinPython の python フォルダに直接入れる。
  - 理由: 非公開の index(`explicit = true`)の依存を入れられるようにするため(issue #10)。`uv export` の requirements.txt には index の情報が出ず、pip は PyPI しか探さない。uv なら、普段の `uv sync` と同じ認証の仕組みがそのまま効く。
- pip モード(`installer: "pip"`)も、uv モードで問題が出たときの逃げ道として残す。
- どちらのモードでも、先に `uv export --frozen` で依存を書き出す。WinPython をダウンロードする前に lock の不備に気づくためと、入れる依存をログに残すため。
- pyproject の `default-groups` は無視し、`groups` に指定したものだけを入れる。既定では dev も入れない。
- 検討して採らなかった方式:
  - `uv export --format pylock.toml` を pip で入れる: pip が experimental の警告を出す。
  - requirements.txt と `--extra-index-url`: 認証情報を pip 用に別に用意する必要があり、汎用のスクリプトに向かない。

### uv モードの引数

`UV_PROJECT_ENVIRONMENT=<winpython\python>` にして、`uv sync --frozen --inexact --no-install-project --no-default-groups --python <python.exe> --link-mode copy --no-editable` を実行する。

- `--inexact`: 付けないと、lock にないもの(WinPython 同梱の pip、wppm、packaging、setuptools など)が消される。
- `--link-mode copy`: uv のキャッシュへのハードリンクにしない。成果物がキャッシュと結びつかないようにするため。
- `--no-editable`: path 依存やワークスペースのメンバーが、開発機の絶対パスを指す editable にならないようにするため。
- `--compile-bytecode` は付けない。
- `--no-config` は付けない。個人の uv 設定(`uv.toml`、`UV_*` 環境変数)が index の認証に効いてほしいため。その分、成果物が個人の設定に左右されうる。

### pip モードの事前検査

- `uv export` の直後に、requirements.txt の各依存を uv.lock の `[[package]]` と照合する。`source = { registry = ... }` が PyPI 以外なら、エラーにする。
  - pyproject の `[[tool.uv.index]]` ではなく uv.lock を見るのは、実際に解決された結果だから。
- 環境マーカーで index を切り替えると、uv.lock に同じ `name==version` が registry 違いで複数入る。requirements.txt からはどれが選ばれたか分からないので、1つでも PyPI 以外があればエラーにする(安全側に倒す。PR #11 のレビューで判明)。
- PyPI のミラーを既定の index にしている環境(`UV_DEFAULT_INDEX` など)では、PyPI のパッケージでもエラーになる。(推測) その場合は uv モードを使う。
- ハッシュは外さない。PyPI に同名のパッケージがあっても、ハッシュが合わないので誤って入ることはない。

## WinPython のアーカイブ形式(winPythonArchiveFormat)

- 既定は zip。PowerShell の `Expand-Archive` は 7z を扱えず、搬入先が Windows 10 や古いビルドだと 7-Zip が要るため(issue #13)。
- 7z は、Windows に標準で入っている `%SystemRoot%\System32\tar.exe`(bsdtar)で作る。7-Zip は使わない。追加で何も入れなくてよいことを優先した。7-Zip で作るより 4% ほど大きくなる。
  - パスを System32 に固定するのは、PATH の `tar` が Git for Windows の GNU tar のことがあり、これは 7z を作れないため。
  - tar に `.` を渡すと、エントリ名が `./` で始まる。そのため、最上位の項目を名前で並べて渡す。
- 7z を作れないときは、zip に切り替えずにエラーで止める。WinPython をダウンロードする前に、小さな 7z を試しに作って確かめる。
- 外側 ZIP の中では、winpython.zip / winpython.7z を無圧縮(stored)で格納する。すでに圧縮されているため。

## WinPython の不要なファイルの削除(pruneWinPython)

- 目的は容量の削減ではなく、展開したときに目に入るノイズを減らすこと。対象は WinPython の最上位の階層だけ。削除するものは `build_offline.py` の `PRUNE_TARGETS`。
- スクリプトの既定値は false のまま、コミットする `config\settings.json` で true にする。真偽値を「既定が false になる向き」で名付ける決まりを崩さずに、通常は削除するため。

## 設定

- 形式は JSON。PowerShell 版のときに、YAML と TOML は標準のパーサーがない、psd1 はなじみがない、という理由で選んだ。Python に移ったあとも、既存の設定ファイルとの互換のため JSON のまま。
- `config\settings.json`(コミットする、共通)と `config\settings.local.json`(gitignore、個人用)を、このリポジトリに置く。対象プロジェクトを汚さないため。
- 優先順位は、**引数 > settings.local.json > settings.json > 既定値**。キー単位で上書きする。
- プロジェクトごとの設定欄は設けない。プロジェクトごとの指定(`groups`, `extras`, `exclude` など)は引数で渡す。
- 真偽値は、既定が false になる向きで名付ける。引数は `--x` / `--no-x` の両方を受け付け、設定ファイルの値をどちらの向きにも上書きできる。
- 未知のキーはエラーにする(打ち間違いを見つけるため)。大文字小文字だけが違うキーもエラー。決まった値だけを受け付ける項目(`installer` など)も、大文字小文字を区別する。
- `projectRoot` と `configPath` は設定キーにしない。設定ファイルの場所がそれらで決まるため。
- `outputDir` のフォルダがなければエラーにする。打ち間違いで意図しないフォルダを作らないため。
- 配列の引数は、カンマ区切り(`--groups a,b`)も受け付ける。PowerShell 版の `-Groups a,b` と同じ書き方ができるように残した。

### initialDir

- フォルダ選択ダイアログの初期位置。個人のパスになるので、`settings.local.json` に書く。
- 引数は設けない。引数で指定するなら `--project-root` を使えばよいため。
- 環境変数は `%NAME%` の形だけを展開する。`$NAME` は展開しない(`\\server\c$` などを壊さないため)。
- 相対パスはエラーにする。.bat から起動すると基準が分かりにくいため。展開できなかった環境変数が残って相対パスになった場合も同じ。
- フォルダがなければ、警告して、初期位置を指定せずにダイアログを開く。

## 実行・ログ・UI

- 実装は Python 3.11 以上(`tomllib` を使うため)。インタープリターは uv が用意する。ビルドにはもともと uv が必須なので、利用者が Python を別に入れる必要がない。
- 実行時の依存は loguru だけ。ほかは標準ライブラリで書く。
- `build-offline.bat` は `uv run --project "%~dp0." ...` で起動し、成功・失敗にかかわらず毎回 `pause` する。ダブルクリックで実行するため。`.` を足す理由は「確かめた事実」の .bat の項を参照。
- GUI はフォルダ選択(tkinter)と、終了時のポップアップだけ。ほかの設定は設定ファイルと引数で行う。
  - ポップアップは、`ctypes` で Win32 の `MessageBoxW` を呼び、最前面に出す。tkinter に頼らない。
  - tkinter が使えない Python で起動したときは、ダイアログを出さずに「`--project-root` を指定すること」というエラーで止める。
- ログは、このリポジトリの `logs\` に書く(持ち出さない)。コンソールとログファイルの両方に、loguru で書く。
  - ログファイルの名前に `<name>` が要るので、pyproject を読むまではメモリにためておき、ログファイルを開くときにまとめて書き出す。
  - 外部コマンド(uv, pip など)の出力も、受け取ってログに書く。
- 外部コマンドは、`subprocess` に引数をリストで渡す(シェルを通さない)。終了コードが 0 でなければ、ビルドを失敗にする。
- ビルド中は、子プロセスの `PYTHONPATH`、`PYTHONHOME`、`VIRTUAL_ENV` などを外し、`PYTHONNOUSERSITE=1` にする。開発環境の影響を受けないようにするため(`uv run` が設定する `VIRTUAL_ENV` もここで外れる)。
- 動作確認の import は `python -I` で行う。カレントフォルダを sys.path に入れず、`.pth` を経由して import できることを確かめるため。
- 作業用フォルダ `.build\work\` は、成功したら消し、失敗したら調査用に残す。
- 画面とログの文言、コードのコメント、テスト名は英語にする(issue #17)。`docs\` と README は日本語。

## Python への移行(issue #22)

2026-10-07 に、実装を PowerShell から Python に移した。対象プロジェクトの指定方法、設定ファイル、ビルドの流れ、成果物の構成は変えていない。引数の名前は変わった(`-ProjectRoot` → `--project-root` など)ので、バージョンを 0.2.0 に上げた。

理由:
- 利用者兼レビュアーが ps1 を読み慣れておらず、変更のレビューが形だけになるため。
- PowerShell 特有の落とし穴(5.1 と 7 の違い、BOM、外部コマンドへの引数のクォート、`$LASTEXITCODE` の確かめ忘れ、関数の戻り値に余計な出力が混ざる、要素が1つの配列が配列でなくなる、など)で、実装の間違いが起きやすいため。
- 手書きしていた処理(TOML の読み込み、ZIP の区切り文字など)を、標準ライブラリで書けるため。

## テスト

- pytest で書く。CI(`.github/workflows/ci.yml`)は ubuntu で動く。Windows でしか動かない処理に依存するテストは skip する。ほかのテストは ubuntu でも通るように書く。
- テストはネットワークを使わない。git はローカルに作ったリポジトリにだけ使う。
- `get_project_files` のテストは、`GIT_CONFIG_GLOBAL` を空のファイルに、`GIT_CONFIG_NOSYSTEM=1` にして呼ぶ。利用者のグローバルな除外設定などに、結果が左右されないようにするため。
- `odekake\` のモジュールは `from odekake import log` として `log.write_log` / `log.run` を呼ぶ。テストで差し替えられるようにするため。

---

## 確かめた事実

### WinPython(2026-10-06 確認)

- 2026-03 以降の配布物は、dot / slim / dotf / slimf の4種だけ。最小は dot。exe と zip/7z の中身は同じ。
- 3.12 の dot 版がある最後の安定版リリースは、2025-03 リリース(タグ `16.6.20250620final`)。2026-03 リリースには 3.13.15 / 3.14.7 / 3.15.0 しかない。
- 3.13.15 dot の zip の中身:
  - 最上位は `WPy64-313150`。その下に `python\`、`scripts\`、`notebooks\`、`wheelhouse\`、各種のランチャー(.exe)、`license.txt`。
  - `._pth` ファイルがないので、`.pth` が効く。pip 26.2.1 と packaging 26.2 を同梱。lock が別の版を指していれば、入れ替わる。
  - `scripts\env.bat` は、PATH(`python\`、`python\Scripts` など)、`PYTHONIOENCODING=utf-8`、`HOME` を設定する。
- 3.12.10 dot の zip の中身:
  - 最上位は `WPy64-312101`。`python\python.exe` と `python\Lib\site-packages\` は 3.13 と同じ深さなので、`.pth` の中身はそのまま使える。
  - `._pth` はない。pip 25.1.1、packaging 25.0、setuptools 79.0.1 を同梱。pip 25.1.1 で、`uv export` が出すハッシュ付きの requirements を入れられる。
  - `wheelhouse\` がない。空の `settings\` と `t\` がある(役割が分からないので消さない)。
- `.pth` の方式で、`src\` のパッケージを import でき、フォルダごと移した後も import できた。

### git(git 2.54.0、2026-10-06 確認)

- pathspec の `:(exclude,glob)` では、`tests` はフォルダごと、`*.log` は最上位だけ、`**/*.log` は全階層に当たる。
- `git ls-files` は export-ignore を見ない。pathspec の `:(exclude,attr:export-ignore)` はファイル自身の属性だけを見るので、フォルダに付いた export-ignore は効かない。
- `git check-attr export-ignore` も同じ。`/tests/ export-ignore` のとき、`tests/x.py` は unspecified。フォルダを `tests/`(末尾に `/`)で問い合わせると set になり、`tests` では unspecified。`docs export-ignore`(末尾に `/` なし)は、`docs` でも `docs/` でも set。
  - そのため `get_project_files` は、ファイルと、その親フォルダすべて(末尾に `/`)を問い合わせ、どれかが set なら除く。`git archive` はフォルダを中身ごと除くので、それに合わせた。
- check-attr は、パスだけで判定するので、未 add のファイルにも効く。
- 既知の制限: 文字列値の `export-ignore=set` は、check-attr の出力が真偽値の set と同じなので、区別できずに除外される(`git archive` は除外しない)。まず書かれない記法なので、直さない(PR #14 のレビュー)。

### uv と pip(uv 0.11.16、2026-10-06 確認)

- `uv export --format requirements-txt` は index の情報を出さない(`mylib==0.1.0 --hash=...` だけ)。非公開の index にしかない依存を pip で入れると、`No matching distribution found` で失敗する(ローカルの擬似 index で再現)。
- `uv export` は既定でハッシュを出す。PyPI の依存だけなら、ハッシュ付きのまま pip に渡して入る。
- uv モードで入れたパッケージの `INSTALLER` は `uv`。搬入先の pip(26.2.1)で `pip uninstall` できた。
- uv モードの成果物でも、元の WinPython の `site-packages` 直下の項目はすべて残った。対象プロジェクトには何も作られなかった。

### tar.exe と 7z(Windows 11 26200、bsdtar 3.8.8 / libarchive 3.8.8、2026-10-06 確認)

- WinPython 3.13.15 dot(4323 ファイル)を固めた大きさ: 元の配布 zip 28.2 MB、tar.exe の 7z(LZMA2、既定のレベル)17.5 MB、7-Zip 26.04 の既定 16.9 MB。7-Zip との差は、exe/dll 向けの BCJ フィルタと辞書の大きさによると思われる。(推測)
- tar.exe で作った 7z は、7-Zip の `7zr t` で異常がなく、`7zr x` と `tar.exe -xf` のどちらで展開しても動いた。
- `tar -tf` の一覧はコンソールのコードページで出るので、日本語の名前が化けて見える。7z の中には UTF-16 で入っており、展開すれば正しい名前になる。

### .bat と Windows(2026-10-07 確認)

- .bat に `--project "%~dp0"` と書くと、末尾の `\"` がエスケープとして読まれ、`--project` の値がコマンド行の残り全部になって失敗した。`"%~dp0."` にすると動く。
- `SHGetKnownFolderPath` で取ったダウンロードフォルダは、シェルの `shell:Downloads` と同じパスだった。
- `build-offline.bat` をダブルクリックすると、フォルダ選択ダイアログ(tkinter)がコンソールの前面に出て、`initialDir` のフォルダで開いた。完了時のポップアップは最前面に出た(ユーザーが確認)。
- PowerShell 版と Python 版で同じ試験用プロジェクトを4通りの設定でビルドし、外側 ZIP と winpython の中身(名前とサイズ)が一致した。違ったのは、外側 ZIP の中の winpython.zip の格納方法だけだった(PowerShell 版は deflate の無圧縮ブロック、Python 版は stored)。

---

## 既知の制限と未確認事項

- インターネットもシステムの Python もない PC での実行は、未確認。日本語と空白を含む別のパスに展開して動くことは確認済み。
- 失敗したときのポップアップの表示。(未確認)
- ハッシュのない行(path 依存、git 依存など)がある場合に、pip モードが失敗するか。(未検証)
- Windows 11 の新しいビルドのエクスプローラーで 7z を展開できるか。(未確認) Windows 10 や古いビルドの `tar.exe` は、7z(LZMA2)を読めない可能性がある。(推測)
