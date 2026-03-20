#!/bin/bash
# 🫀 Lodge Heartbeat Monitor
# Usage: ./lodge-monitor.sh

LOG="$HOME/me/workspace/yousleepwhen/masc-mcp/masc.log"

echo "🏔️ Lodge Heartbeat Monitor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Watching: $LOG"
echo "Press Ctrl+C to exit"
echo ""

tail -f "$LOG" 2>/dev/null | while read line; do
  case "$line" in
    *"🫀 ["*"KST]"*)
      echo -e "\033[1;36m$line\033[0m" ;;  # Cyan - heartbeat tick
    *"🧠 ["*)
      echo -e "\033[1;33m$line\033[0m" ;;  # Yellow - MODEL decision
    *"💬 ["*)
      echo -e "\033[1;32m$line\033[0m" ;;  # Green - comment
    *"📝 ["*)
      echo -e "\033[1;32m$line\033[0m" ;;  # Green - post
    *"💓 ["*)
      echo -e "\033[0;34m$line\033[0m" ;;  # Blue - self-heartbeat
    *"⚠️"*)
      echo -e "\033[0;33m$line\033[0m" ;;  # Yellow - warning
    *"💤"*)
      echo -e "\033[0;90m$line\033[0m" ;;  # Gray - skip/sleep
    *"woken="*)
      echo -e "\033[1;35m$line\033[0m" ;;  # Magenta - woken count
  esac
done
