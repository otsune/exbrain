#!/usr/bin/env bash
# platform.sh — OS差異を吸収する共通ヘルパ（macOS / Windows(Git Bash) / Linux）
# source されて使われるライブラリのため set -e は入れない。
# 提供関数: os_kind / date_offset / notify / win_path

# os_kind — 実行OSを macos / windows / linux のいずれかでecho
os_kind() {
  case "${OSTYPE:-}" in
    darwin*) echo "macos"; return 0 ;;
    msys*|cygwin*|win32*) echo "windows"; return 0 ;;
    linux*) echo "linux"; return 0 ;;
  esac
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Linux) echo "linux" ;;
    *) echo "linux" ;;
  esac
}

# date_offset <base> <days> — base("YYYY-MM-DD"|"today") から days日ずらした日付をYYYY-MM-DDでecho
# GNU date (date -d) を先に試し、失敗したら BSD date (date -v / date -j -f) にフォールバック
date_offset() {
  base="$1"; days="$2"
  case "$days" in
    -*) sign="$days" ;;
    *) sign="+$days" ;;
  esac

  out=""
  if [ "$base" = "today" ]; then
    out=$(date -d "$days days" +%F 2>/dev/null)
    [ -z "$out" ] && out=$(date -v${sign}d +%F 2>/dev/null)
  else
    out=$(date -d "$base $days days" +%F 2>/dev/null)
    [ -z "$out" ] && out=$(date -j -f %F -v${sign}d "$base" +%F 2>/dev/null)
  fi

  if [ -n "$out" ]; then
    echo "$out"
    return 0
  fi
  return 1
}

# notify <title> <message> — ベストエフォートのデスクトップ通知。常にrc=0
notify() {
  title="$1"; message="$2"
  case "$(os_kind)" in
    macos)
      osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1
      ;;
    windows)
      powershell.exe -NoProfile -Command "
        \$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);
        \$texts = \$t.GetElementsByTagName('text');
        \$texts.Item(0).AppendChild(\$t.CreateTextNode('$title')) > \$null;
        \$texts.Item(1).AppendChild(\$t.CreateTextNode('$message')) > \$null;
        \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$t);
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('exbrain').Show(\$toast);
      " >/dev/null 2>&1
      ;;
    *)
      : # linuxなど未対応OSは何もしない
      ;;
  esac
  return 0
}

# win_path <posix-path> — windowsならcygpath -wの結果、それ以外は入力をそのままecho
win_path() {
  path="$1"
  if [ "$(os_kind)" = "windows" ]; then
    cygpath -w "$path" 2>/dev/null || echo "$path"
  else
    echo "$path"
  fi
}
