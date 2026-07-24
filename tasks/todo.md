# exbrain fork — Windows 対応

方針: **自分用改造優先**（上流 PR は後で切り出せるものだけ）。ブランチ `win-support`。

前提: 実行環境は **Git Bash 確定**（WSL bash は sqlite3 等が不足するため不可）。

---

## Phase 0 — ベースライン

- [x] `win-support` ブランチ作成
- [x] `~/vault` の既存 Windows パッチを `vault-template/scripts/` へバックポート
  - [x] `vault-healthcheck.sh` — git接続プローブ / date フォールバック / schtasks プローブ（27行）
  - [x] `brain-compile.sh` — `date -d` 化（4行）

## Phase 1 — スクリプトのクロスプラットフォーム化

- [x] `vault-template/scripts/lib/platform.sh` を新設（共通ヘルパ）
  - [x] `os_kind()` — macos / windows / linux 判定
  - [x] `date_offset <base|today> <±N days>` — GNU/BSD 両対応
  - [x] `notify <title> <msg>` — osascript / PowerShell toast / no-op を自動選択
  - [x] `win_path <posix>` — cygpath -w ラッパ
- [x] `brain-compile.sh` — date を `date_offset` に置換、claude CLI 候補に Windows パスを追加
- [x] `vault-healthcheck.sh` — 定期ジョブプローブを **3分岐**に（launchd / schtasks / どちらも無い→🟡を明示）
- [x] `brain-lint.sh` / `vault-sync.sh` — `osascript` を `notify` に置換

## Phase 2 — スケジューラ登録の自動化

- [x] `vault-template/scripts/setup-scheduler.sh` を新設（`launchd/*.plist` の Windows 対応物）
  - [x] brain-compile（毎日 23:30）/ brain-pull（毎時）/ brain-lint（日曜 09:00）を schtasks で登録
  - [x] `MSYS_NO_PATHCONV=1` + `cygpath` でパス化けを回避
  - [x] CP932 出力を UTF-8 に正規化して判定
  - [x] 冪等（登録済みコマンドを比較し、同一なら何もしない）
  - [x] macOS では launchctl 登録にフォールバック（同一エントリポイント）

## Phase 3 — クラウド認知パイプラインの扱い（別判断）

- [ ] 朝夕の目（07:00 / 18:30）と週次 Dreaming（日曜 21:30）が**クラウド側に1件も存在しない**問題への対応方針を決める
  - 案A: ローカル schtasks で `sync-agent-to-vault.sh` 相当を回す
  - 案B: claude.ai の Scheduled Tasks に登録し直す（リポジトリ変更なし）
- 判断まで着手しない

## Phase 4 — ドキュメント

- [x] `README_JP.md` Step 5 を `setup-scheduler.sh` 一発に置換（従来の launchctl 手順は補足に降格）
- [x] 前提条件に「Git Bash 必須 / WSL bash 不可」を明記
- [x] Step 1 の iCloud 同期が macOS 専用である旨を明記
- [x] `README.md`（英語）にも同内容を反映

---

## 検証（完了条件）

- [x] 全変更スクリプトの `bash -n` 構文チェック
- [x] `platform.sh` の関数を実機確認（`os_kind`=windows、`date_offset today -3`=2026-07-22、`2026-07-25 +1`=2026-07-26、不正入力で rc=1、`notify` rc=0）
- [x] `vault-healthcheck.sh` の定期ジョブプローブに else 節が入り、3分岐すべてで行が出ることを確認
- [x] `setup-scheduler.sh --dry-run` を 2回連続実行し、3ジョブとも `unchanged` で冪等性を確認
- [x] 実機の schtasks は一切変更していない（`/query` のみ）

## Review

### 完了

Phase 0-2 と Phase 4 を実装。`git diff --stat`: 既存4スクリプト +42/-10、新規2ファイル（`lib/platform.sh`、`setup-scheduler.sh`）、README 2本 +26/-14。

### 実装中に見つかった不具合（いずれも修正済み）

1. **`vault-healthcheck.sh` のサイレント欠落** — 定期ジョブプローブが `if launchctl / elif schtasks` で終わっており、どちらも無い環境では行が1つも出ずプローブの存在自体が消えていた。else 節を追加
2. **Git Bash のパス解決ミス** — `command -v bash` は `/usr/bin/bash` を返し、`cygpath -w` すると `...\Git\usr\bin\bash.exe`（MSYS の生 bash、2.4MB）になる。実際に必要なのは `...\Git\bin\bash.exe`（ランチャ、45.9KB）。`cygpath -w /` が Git インストールルートを返すことを利用して解決
3. **`cmd //c "chcp 65001 & schtasks /query /tn ..."` が動かない** — 「指定されたパスが見つかりません」で失敗し比較が常に不成立になっていた。`MSYS_NO_PATHCONV=1 schtasks.exe /query /fo LIST /v | iconv -f CP932` に変更
4. **CSV ヘッダ名の誤り** — `タスクの実行` ではなく `実行するタスク` が正しい。LIST 形式に切り替えて CSV クォート処理ごと不要にした
5. **`python3` 依存** — この環境の `python3` は Microsoft Store のアプリ実行エイリアス スタブで信頼できない。`sed` に置換して依存を排除

### 残作業

- Phase 3（クラウド認知パイプラインの扱い）は方針未定のため未着手
- 未 push。`origin/win-support` への push は未実施
