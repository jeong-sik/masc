#!/usr/bin/env bash
set -euo pipefail

# Configuration
MASC_URL="http://localhost:8935/mcp"
ROOM_ID="default222"

echo "🔮 Summoning Keepers with SOUL..."

# Helper to read file content
read_soul() {
  local path="$1"
  cat "$path"
}

# 1. Summon DM (Grim Warden)
DM_SOUL=$(read_soul "workspace/yousleepwhen/masc-mcp/memory/souls/grim-warden/SOUL.md")
WORLD_INFO=$(read_soul "workspace/yousleepwhen/masc-mcp/memory/worlds/grimland/WORLD.md")

echo " - Booting DM: Grim Warden..."
masc_perpetual_start 
  --goal "You are the Grim Warden. 

$DM_SOUL

$WORLD_INFO

Task: Manage room '$ROOM_ID'." 
  --models "glm:glm-4.7"
  --heartbeat_sec 10 > logs/dm_soul.log 2>&1 &

# 2. Summon Aragorn
ARAGORN_SOUL=$(read_soul "workspace/yousleepwhen/masc-mcp/memory/souls/aragorn/SOUL.md")

echo " - Booting Player: Aragorn..."
masc_perpetual_start 
  --goal "You are Aragorn. 

$ARAGORN_SOUL

$WORLD_INFO

Task: Play in room '$ROOM_ID' as 'aragorn-1'." 
  --models "glm:glm-4.7"
  --heartbeat_sec 10 > logs/aragorn_soul.log 2>&1 &

echo "✅ Souls infused. The society is alive."
