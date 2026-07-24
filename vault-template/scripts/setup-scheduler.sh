#!/usr/bin/env bash
# setup-scheduler.sh — exbrain スケジューラ登録の単一エントリポイント
# macOS (launchd) / Windows (schtasks) の両OSで brain-compile / brain-pull / brain-lint を冪等に登録する。
# 使い方: setup-scheduler.sh [--dry-run] [--help]
#   --dry-run : 実際には登録・変更せず、実行予定の内容を表示するのみ
# 設計原則:
#   - 既存の実機タスクを壊さない。--dry-run では書き込み系コマンドを一切呼ばない
#   - 冪等: 既に同一内容で登録済みなら何もしない
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh" || {
  echo "ERROR: $SCRIPT_DIR/lib/platform.sh の読み込みに失敗しました（未作成または壊れています）" >&2
  exit 1
}

VAULT="${VAULT:-$HOME/vault}"
DRY_RUN=0

usage(){
  cat <<'EOF'
使い方: setup-scheduler.sh [--dry-run] [--help]

exbrain の定期実行ジョブ（brain-compile / brain-pull / brain-lint）を
OS標準のスケジューラ（macOS: launchd / Windows: schtasks）に登録する。

オプション:
  --dry-run   実際には登録・変更せず、実行予定の内容を表示するのみ
  --help, -h  このヘルプを表示

環境変数:
  VAULT       vaultのパス（既定: $HOME/vault）
EOF
}

for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
  esac
done

log(){ echo "[setup-scheduler] $*" >&2; }

# ジョブ定義: name|windows_taskname|script_rel|extra_args|windows_schedule_args|macos_plist
JOBS='
brain-compile|\brain-compile|scripts/brain-compile.sh||/sc DAILY /st 23:30|com.YOURNAME.brain-compile.plist
brain-pull|\brain-pull|scripts/vault-sync.sh|--pull-only|/sc HOURLY|com.YOURNAME.brain-pull.plist
brain-lint|\brain-lint|scripts/brain-lint.sh||/sc WEEKLY /d SUN /st 09:00|com.YOURNAME.brain-lint.plist
'

RESULTS=""   # "job|result" を改行区切りで蓄積
OVERALL_RC=0

add_result(){ RESULTS="${RESULTS}$1|$2
"; }

# ============================================================
# Windows実装
# ============================================================
setup_windows(){
  # Git Bash の実体（bin\bash.exe）パスを解決（3段階フォールバック）
  local bash_win=""
  local git_root_win
  git_root_win="$(win_path "/")"
  git_root_win="${git_root_win%\\}"
  if [ -n "$git_root_win" ]; then
    local candidate_posix
    candidate_posix="$(cygpath -u "${git_root_win}\\bin\\bash.exe" 2>/dev/null)"
    if [ -n "$candidate_posix" ] && [ -x "$candidate_posix" ]; then
      bash_win="${git_root_win}\\bin\\bash.exe"
    fi
  fi
  if [ -z "$bash_win" ]; then
    local bash_path
    bash_path="$(command -v bash 2>/dev/null)"
    [ -n "$bash_path" ] && bash_win="$(win_path "$bash_path")"
  fi
  if [ -z "$bash_win" ]; then
    bash_win="C:\\Program Files\\Git\\bin\\bash.exe"
  fi

  local vault_win
  vault_win="$(win_path "$VAULT")"

  local have_iconv=0
  command -v iconv >/dev/null 2>&1 && have_iconv=1

  echo "$JOBS" | while IFS='|' read -r name taskname script extra_args sched plist; do
    [ -z "$name" ] && continue

    local script_win_rel
    script_win_rel="$(printf '%s' "$script" | sed 's#/#\\#g')"
    local cmd="\"$bash_win\" ${vault_win}\\${script_win_rel}"
    [ -n "$extra_args" ] && cmd="$cmd $extra_args"

    log "=== $name (windows task: $taskname) ==="
    log "期待コマンド: $cmd"

    local exists=1
    MSYS_NO_PATHCONV=1 schtasks.exe /query /tn "$taskname" >/dev/null 2>&1
    if [ $? -eq 0 ]; then exists=0; fi

    if [ "$exists" -eq 1 ]; then
      # 存在しない
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] 未登録 → 作成予定: schtasks /create /tn \"$taskname\" /tr \"$cmd\" $sched /f"
        echo "$name|would-create"
      else
        MSYS_NO_PATHCONV=1 schtasks.exe /create /tn "$taskname" /tr "$cmd" $sched /f >/dev/null 2>&1
        if [ $? -eq 0 ]; then
          log "作成しました: $taskname"
          echo "$name|created"
        else
          log "作成に失敗しました: $taskname"
          echo "$name|failed"
        fi
      fi
    else
      # 既に存在する → /TR を取得して比較
      local raw current_tr=""
      raw="$(MSYS_NO_PATHCONV=1 schtasks.exe /query /tn "$taskname" /fo LIST /v 2>/dev/null)"
      if [ "$have_iconv" -eq 1 ]; then
        raw="$(printf '%s' "$raw" | iconv -f CP932 -t UTF-8 2>/dev/null)"
      fi
      current_tr="$(printf '%s\n' "$raw" | sed -n 's/^\(実行するタスク\|Task To Run\): *//p' | head -1)"
      current_tr="$(printf '%s' "$current_tr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      if [ -n "$current_tr" ] && [ "$current_tr" = "$cmd" ]; then
        log "変更なし（一致）: $taskname"
        echo "$name|unchanged"
      else
        if [ "$DRY_RUN" -eq 1 ]; then
          log "[dry-run] 既存タスクと差異あり（または比較不能）→ 更新予定"
          echo "$name|would-update"
        else
          MSYS_NO_PATHCONV=1 schtasks.exe /create /tn "$taskname" /tr "$cmd" $sched /f >/dev/null 2>&1
          if [ $? -eq 0 ]; then
            log "更新しました: $taskname"
            echo "$name|updated"
          else
            log "更新に失敗しました: $taskname"
            echo "$name|failed"
          fi
        fi
      fi
    fi
  done > "$SCRIPT_DIR/.setup-scheduler.tmp"

  while IFS='|' read -r n r; do
    [ -z "$n" ] && continue
    add_result "$n" "$r"
  done < "$SCRIPT_DIR/.setup-scheduler.tmp"
  rm -f "$SCRIPT_DIR/.setup-scheduler.tmp"
}

# ============================================================
# macOS実装
# ============================================================
setup_macos(){
  local user
  user="$(whoami)"
  local agents_dir="$HOME/Library/LaunchAgents"

  echo "$JOBS" | while IFS='|' read -r name taskname script extra_args sched plist; do
    [ -z "$name" ] && continue

    local src="$SCRIPT_DIR/../launchd/$plist"
    local dst_label="com.$user.$name"
    local dst="$agents_dir/$dst_label.plist"

    log "=== $name (macos label: $dst_label) ==="

    if [ ! -f "$src" ]; then
      log "テンプレートが見つかりません: $src"
      echo "$name|failed"
      continue
    fi

    local rendered
    rendered="$(sed -e "s/YOURNAME/$user/g" -e "s#/Users/$user/vault#$VAULT#g" "$src")"

    local loaded=1
    launchctl print "gui/$(id -u)/$dst_label" >/dev/null 2>&1
    if [ $? -eq 0 ]; then loaded=0; fi

    local same=1
    if [ -f "$dst" ] && [ "$(cat "$dst" 2>/dev/null)" = "$rendered" ]; then same=0; fi

    if [ "$DRY_RUN" -eq 1 ]; then
      if [ ! -f "$dst" ]; then
        log "[dry-run] 未作成 → 作成予定: $dst"
        echo "$name|would-create"
      elif [ "$same" -eq 0 ] && [ "$loaded" -eq 0 ]; then
        log "[dry-run] 変更なし: $dst"
        echo "$name|unchanged"
      else
        log "[dry-run] 差異あり → 更新予定: $dst（bootout → bootstrap）"
        echo "$name|would-update"
      fi
      continue
    fi

    if [ -f "$dst" ] && [ "$same" -eq 0 ] && [ "$loaded" -eq 0 ]; then
      log "変更なし: $dst"
      echo "$name|unchanged"
      continue
    fi

    printf '%s' "$rendered" > "$dst"
    if [ "$loaded" -eq 0 ]; then
      launchctl bootout "gui/$(id -u)" "$dst" >/dev/null 2>&1
    fi
    launchctl bootstrap "gui/$(id -u)" "$dst" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      log "登録しました: $dst"
      if [ -f "$dst.prev_exists" ]; then echo "$name|updated"; else echo "$name|created"; fi
    else
      log "登録に失敗しました: $dst"
      echo "$name|failed"
    fi
  done > "$SCRIPT_DIR/.setup-scheduler.tmp"

  while IFS='|' read -r n r; do
    [ -z "$n" ] && continue
    add_result "$n" "$r"
  done < "$SCRIPT_DIR/.setup-scheduler.tmp"
  rm -f "$SCRIPT_DIR/.setup-scheduler.tmp"
}

# ============================================================
# メイン
# ============================================================
KIND="$(os_kind)"
log "OS種別: $KIND / VAULT: $VAULT / dry-run: $DRY_RUN"

case "$KIND" in
  windows) setup_windows ;;
  macos)   setup_macos ;;
  *)
    log "未対応のOSです（$KIND）。macOS / Windows のみサポートしています。"
    exit 0
    ;;
esac

echo ""
echo "job | result"
echo "----|------"
printf '%s' "$RESULTS" | while IFS='|' read -r n r; do
  [ -z "$n" ] && continue
  echo "$n | $r"
done

if printf '%s' "$RESULTS" | grep -q '|failed$'; then
  OVERALL_RC=1
fi

notify "exbrain scheduler" "setup-scheduler 完了（dry-run=$DRY_RUN）" 2>/dev/null

exit "$OVERALL_RC"
