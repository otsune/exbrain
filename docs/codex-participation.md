# Codex CLI を exbrain に参加させる手順

作成: 2026-08-10 ｜ 対象: codex-cli 0.147.0 / vault = `~/vault`

## 概要

Codex CLI を exbrain(`~/vault`)に「**読み取り + daily 追記**」レベルで参加させる。

- 読み取り: どの cwd からでも `INDEX.md` 経由で vault を参照できる
- 書き込み: `daily/<YYYY-MM-DD>.md` の `## Sessions` 節への追記のみ(4層モデルの所有権ルールと衝突しない範囲)
- git 同期: 既存の自動化(`vault-sync.sh`、毎時 `brain-pull` タスク)に任せる。Codex 側の追加作業なし

## 前提知識

Codex の指示注入は次の合成で決まる(深い階層が優先):

1. グローバル `~/.codex/AGENTS.md` — 全セッションに常時注入
2. cwd から上位方向の `AGENTS.md` 階層 — vault 内で起動したときだけ `vault/AGENTS.md` が効く

`vault/CLAUDE.md`(スキーマ正本)は Codex からは自動では読まれないため、`vault/AGENTS.md` を薄いラッパとして新設し「まず CLAUDE.md を読め」と誘導する。

## 手順

### ① `~/vault/AGENTS.md` を新設(適用済み)

Codex 向け参加規約。内容の要点:

- スキーマ正本 `CLAUDE.md` を作業前に必ず読む
- 読み取りは `INDEX.md` → リンクを辿る順。フルスキャン禁止
- 書き込み許可は `daily/<YYYY-MM-DD>.md` の `## Sessions` 追記のみ(形式 `- HH:MM codex: <1行>`)
- 禁止: raw 層の既存行書き換え、`MEMORY.md`/`DREAMS.md`(クラウド認知の所有物)、identity 層(人間のみ)、`INDEX.md` の FRESHNESS ブロック、wiki 層への書き込み
- daily note が無い日は `on-session-end.sh` と同一の雛形(`Schedule/Sessions/Thoughts/Links`)で作成可

### ② `~/.codex/AGENTS.md` にマーカー付きブロックを追記(適用済み)

`<!-- exbrain:participation:start -->` 〜 `<!-- exbrain:participation:end -->` で囲んだブロックを末尾に追加。headroom の `<!-- headroom:rtk-instructions -->` と同じ共存手法で、他ツールの自動書き換えと衝突しない。

内容: exbrain の存在と入口(`~/vault/INDEX.md`)、書き込み前に `~/vault/AGENTS.md` を読む義務、セッション成果の daily 追記指示(workspace 外書き込みの承認プロンプトは正常である旨)。

### ③ `~/.codex/hooks.json` の SessionStart にプライマー注入を追加(**手動適用が必要**)

Claude 側と同じ primer の内容(「## 🧠 exbrain — 今の文脈」)を Codex のセッション開始フックで注入する。

> ⚠️ **Codex hooks は plain stdout を無視する**(検証済み)。`{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "..."}}` 形式の JSON を出力したものだけがコンテキスト注入される(実装参考: `~/skills/tldraw-offline/inject-server-context.sh`)。そのため `session-primer.sh` を直接呼ぶのではなく、出力を JSON に包むラッパー `~/vault/scripts/codex-session-primer.sh` を経由する。

> ⚠️ hooks.json の変更は「毎セッション自動実行されるフックの追加」にあたるため、エージェントによる自動適用は権限制御で拒否される。**ユーザーが手動で追記すること。**

`~/.codex/hooks.json` の `SessionStart` → `hooks` 配列(herdr エントリの後)に追加:

```json
{
  "command": "bash /c/Users/user/vault/scripts/codex-session-primer.sh",
  "commandWindows": "$b=$env:GIT_BASH; if (-not $b) { $b='C:\\Program Files\\Git\\bin\\bash.exe' }; & $b -lc '/c/Users/user/vault/scripts/codex-session-primer.sh'",
  "timeout": 15,
  "type": "command"
}
```

注意:

- ラッパーの中身は「`session-primer.sh` を実行 → 出力を python3 で additionalContext JSON に包む」だけ。primer が空/失敗のときは何も出力しない
- `on-session-start.sh` は使わない。vault-sync + healthcheck を含み、PID ロックで Claude 側セッションと競合しうる
- `config.toml` の `[hooks.state...]` に trusted_hash 管理があるため、初回起動時に Codex がフック信頼の確認を出すことがある(承認すればよい)

## 動作確認

```bash
# 1. グローバル AGENTS.md のブロックが見えているか
codex exec --cd ~/dev/fluent "あなたに与えられている exbrain 関連の指示を要約して"

# 2. vault 内で参加規約が効いているか
codex exec --cd ~/vault "この vault で書き込みが許可されている範囲を答えて"
# → 「daily の Sessions 追記のみ」と答えれば OK

# 3. (③適用後) フック注入の確認 — 対話起動して:
#    「セッション開始時に注入された exbrain の文脈があれば引用して」
# → 「## 🧠 exbrain — 今の文脈」が引用されれば OK

# 4. daily 追記テスト
codex --cd ~/vault   # 「今日の daily の Sessions にテスト行を追記して」
bash ~/vault/scripts/vault-sync.sh   # auto(vault): コミットに乗ることを確認
```

## ロールバック

1. `~/.codex/AGENTS.md` から `<!-- exbrain:participation:start/end -->` ブロックを削除
2. `~/.codex/hooks.json` から追加した SessionStart エントリを削除
3. `~/vault/AGENTS.md` を削除

## 既知の制約・課題

- **Claude Code の codex プラグイン経路(`/codex:rescue` 等)は `ephemeral: true` の app-server 呼び出し**のため、CLI フラグ(`--add-dir` 等)で介入できない。効くのは AGENTS.md 階層とグローバル AGENTS.md のみ。rollout が残らないため Codex ネイティブ memories の生成材料にもならない
- `~/.codex/config.toml` は headroom が自動書き換えする(`.bak` が5世代)。config.toml への手書き追記は避ける
- vault 側の既存不整合はすべて解消済み(2026-08-10):
  - `/ask-brain` を実装 — Claude 用 `~/.claude/commands/ask-brain.md`、Codex 用 `~/.codex/prompts/ask-brain.md`(どちらも INDEX 経由・出典必須・読み取り専用)
  - `RED-LINES.md` / `clips/_index.md` の frontmatter `{{date}}` 未展開を修正
  - `templates/daily-note.md` の節名を `## Log` → `## Sessions` に修正(vault-template 側も同時修正)

## 発展(今回のスコープ外)

- wiki 層への Codex 書き込み許可(誤書き込み対策の設計が必要)
- `~/.codex/memories/extensions/ad_hoc/notes/` への vault ダイジェスト流し込み(Codex ネイティブメモリとの統合)
- vault 検索用 MCP サーバーの追加(`vault/.codex/config.toml` に open-knowledge の前例あり)
