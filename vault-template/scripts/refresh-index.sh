#!/usr/bin/env bash
# refresh-index.sh — INDEX.md の鮮度ダッシュボードを決定論的に再生成する（LLM不使用）
# MEMORY.md / DREAMS.md / open-loops.md / 当日dailyのfrontmatter日付から
# 状態記号(🟢/🟡/🔴)を機械的に計算し、INDEX.md内の
# <!-- FRESHNESS:START --> 〜 <!-- FRESHNESS:END --> の間だけを書き換える。
# 日付が読めない場合は黙って🟢にせず🔴+理由を書く（誤報防止が目的そのものなので厳守）。
set +e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
VAULT="${VAULT:-$HOME/vault}"
IDX="$VAULT/INDEX.md"

DRY_RUN=0
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=1
done

[ -f "$IDX" ] || { echo "refresh-index.sh: ERROR: $IDX が見つからない" >&2; exit 1; }

# マーカー存在チェック（誤爆防止。CRLFの\rを許容して検出）
start_line=$(grep -n '^<!-- FRESHNESS:START -->\r\{0,1\}$' "$IDX" | head -1 | cut -d: -f1)
end_line=$(grep -n '^<!-- FRESHNESS:END -->\r\{0,1\}$' "$IDX" | head -1 | cut -d: -f1)
if [ -z "$start_line" ] || [ -z "$end_line" ] || [ "$end_line" -le "$start_line" ]; then
  echo "refresh-index.sh: ERROR: INDEX.md に <!-- FRESHNESS:START/END --> マーカーが見つからない。書き換えを中止する" >&2
  exit 1
fi

# 改行コード検出（既存ファイルのスタイルをそのまま踏襲する）
# 注意: grep/sed/awk はGit Bash上でテキストモード変換により\rを読み落とすことがあるため、
# ファイルから直接readするbash組込みで検出する（read < file はパイプを介さないため\rが残る）
IFS= read -r _first_line < "$IDX"
case "$_first_line" in
  *$'\r') EOL=$'\r\n' ;;
  *) EOL=$'\n' ;;
esac

today=$(date +%F)
today_epoch=$(date_epoch "$today") || { echo "refresh-index.sh: ERROR: 今日の日付epoch取得に失敗" >&2; exit 1; }

# row_for_date <label> <相対パス> <key1> <key2 or ""> <green日数> <yellow日数>
# key1優先、無ければkey2にフォールバック（DREAMSのlast_dreaming/updated用）。行末EOLは付けない。
row_for_date() {
  label="$1"; path="$2"; key1="$3"; key2="$4"; green="$5"; yellow="$6"
  if [ ! -f "$VAULT/$path" ]; then
    printf '| [[%s]] | - | 🔴 %s が存在しない |' "$label" "$path"
    return
  fi
  val=$(grep -m1 "^${key1}:" "$VAULT/$path" 2>/dev/null | awk '{print $2}' | tr -d '\r')
  used_key="$key1"
  if [ -z "$val" ] && [ -n "$key2" ]; then
    val=$(grep -m1 "^${key2}:" "$VAULT/$path" 2>/dev/null | awk '{print $2}' | tr -d '\r')
    used_key="$key2"
  fi
  if [ -z "$val" ]; then
    keys="$key1"; [ -n "$key2" ] && keys="$key1: / $key2:"
    printf '| [[%s]] | - | 🔴 frontmatterに%sが無い |' "$label" "$keys"
    return
  fi
  d_epoch=$(date_epoch "$val")
  if [ -z "$d_epoch" ]; then
    printf '| [[%s]] | %s | 🔴 %s:の日付形式が不正 |' "$label" "$val" "$used_key"
    return
  fi
  days=$(( (today_epoch - d_epoch) / 86400 ))
  if [ "$days" -le "$green" ]; then mark="🟢"
  elif [ "$days" -le "$yellow" ]; then mark="🟡"
  else mark="🔴"
  fi
  printf '| [[%s]] | %s | %s %s日前 |' "$label" "$val" "$mark" "$days"
}

if [ -f "$VAULT/daily/$today.md" ]; then
  daily_row=$(printf '| [[daily/%s]] | 存在 | 🟢 |' "$today")
else
  daily_row=$(printf '| [[daily/%s]] | 不在 | 🔴 |' "$today")
fi

tmpfile=$(mktemp)
{
  # sed/awkはテキストモード変換で\rを失うため、既存行の保存はhead/tailで行う（bash組込みread同様\rを保持する）
  head -n "${start_line}" "$IDX"
  printf '%s%s' '<!-- refresh-index.sh が生成（手で編集しない） -->' "$EOL"
  printf '%s%s' '| 対象 | 最終更新 | 状態 |' "$EOL"
  printf '%s%s' '|------|---------|------|' "$EOL"
  printf '%s%s' "$(row_for_date MEMORY MEMORY.md updated "" 3 7)" "$EOL"
  printf '%s%s' "$(row_for_date DREAMS DREAMS.md last_dreaming updated 8 15)" "$EOL"
  printf '%s%s' "$(row_for_date open-loops open-loops.md updated "" 7 14)" "$EOL"
  printf '%s%s' "$daily_row" "$EOL"
  tail -n +"${end_line}" "$IDX"
} > "$tmpfile"

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$tmpfile"
  rm -f "$tmpfile"
  exit 0
fi

# 冪等性: 内容に変化が無ければファイルもmtimeも触らない
if cmp -s "$tmpfile" "$IDX"; then
  rm -f "$tmpfile"
  exit 0
fi

mv "$tmpfile" "$IDX"
exit 0
