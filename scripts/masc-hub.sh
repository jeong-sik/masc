#!/bin/bash
# MASC Hub - Multi-Agent TUI Dashboard with tmux
# Launches a 4-pane layout for real-time multi-agent coordination
#
# Layout:
# +------------------+------------------+
# |    Dashboard     |    SSE Events    |
# |   (masc-watch)   |   (curl -N)      |
# +------------------+------------------+
# |    Task Board    |    Agent Shell   |
# |   (tasks list)   |   (interactive)  |
# +------------------+------------------+
#
# Usage: masc-hub [room] [port]
#   room: MASC room/cluster name (default: from ME_ROOT or 'default')
#   port: MASC server port (default: 8935)

set -e

# Configuration
ROOM="${1:-${MASC_CLUSTER_NAME:-$(basename "${ME_ROOT:-$(pwd)}")}}"
PORT="${2:-${MASC_PORT:-8935}}"
SESSION_NAME="masc-hub"
MASC_URL="http://127.0.0.1:${PORT}"

# Resolve base path (same logic as masc-watch)
resolve_base_path() {
    if [ -n "$MASC_BASE_PATH" ]; then
        echo "$MASC_BASE_PATH"
        return
    fi
    if [ -n "$ME_ROOT" ]; then
        echo "$ME_ROOT"
        return
    fi
    if [ -f ".git" ]; then
        local gitdir
        gitdir="$(sed -n 's/^gitdir: //p' .git)"
        if [ -n "$gitdir" ]; then
            case "$gitdir" in
                */.git/worktrees/*) echo "${gitdir%/.git/worktrees/*}"; return ;;
                */.git) echo "${gitdir%/.git}"; return ;;
            esac
        fi
    fi
    if [ -d ".git" ]; then
        pwd -P
        return
    fi
    if command -v git >/dev/null 2>&1; then
        local git_root
        git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$git_root" ]; then
            echo "$git_root"
            return
        fi
    fi
    pwd -P
}

BASE_PATH="$(resolve_base_path)"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Colors for echo
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

# Check dependencies
check_deps() {
    local missing=""

    if ! command -v tmux &>/dev/null; then
        missing="$missing tmux"
    fi

    if ! command -v curl &>/dev/null; then
        missing="$missing curl"
    fi

    if ! command -v jq &>/dev/null; then
        missing="$missing jq"
    fi

    if [ -n "$missing" ]; then
        error "Missing dependencies:$missing. Install with: brew install$missing"
    fi
}

# Check if MASC server is running
check_server() {
    if ! curl -s "${MASC_URL}/health" &>/dev/null; then
        warn "MASC server not responding at ${MASC_URL}"
        warn "Start with: ./start-masc-mcp.sh --port ${PORT}"
        return 1
    fi
    return 0
}

# Kill existing session if requested
cleanup_session() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        info "Killing existing session: $SESSION_NAME"
        tmux kill-session -t "$SESSION_NAME"
    fi
}

# Create the tmux session with 4 panes
create_session() {
    info "Creating tmux session: $SESSION_NAME"
    info "Room: $ROOM | Port: $PORT | Base: $BASE_PATH"

    # Create new detached session with first pane (Dashboard)
    tmux new-session -d -s "$SESSION_NAME" -n "masc" -c "$BASE_PATH"

    # Split horizontally (left | right)
    tmux split-window -h -t "$SESSION_NAME:0" -c "$BASE_PATH"

    # Split left pane vertically (top-left | bottom-left)
    tmux split-window -v -t "$SESSION_NAME:0.0" -c "$BASE_PATH"

    # Split right pane vertically (top-right | bottom-right)
    tmux split-window -v -t "$SESSION_NAME:0.2" -c "$BASE_PATH"

    # Configure panes
    # Pane 0: Dashboard (top-left) - masc-watch with ANSI refresh
    tmux send-keys -t "$SESSION_NAME:0.0" "cd '$BASE_PATH' && export MASC_BASE_PATH='$BASE_PATH'" Enter
    tmux send-keys -t "$SESSION_NAME:0.0" "clear && echo '=== MASC Dashboard ===' && ./bin/masc-watch 2" Enter

    # Pane 1: Task Board (bottom-left) - refreshing task view
    tmux send-keys -t "$SESSION_NAME:0.1" "cd '$BASE_PATH'" Enter
    tmux send-keys -t "$SESSION_NAME:0.1" "watch -n 2 -c 'jq -r \"select(.status != \\\"done\\\") | \\\"[\"+.id+\\\"] \\\" + .title + \\\" (\\\" + .status + \\\")\\\"\" .masc/tasks/*.json 2>/dev/null || echo \"No tasks\"'" Enter

    # Pane 2: SSE Events (top-right) - live event stream
    tmux send-keys -t "$SESSION_NAME:0.2" "cd '$BASE_PATH'" Enter
    tmux send-keys -t "$SESSION_NAME:0.2" "echo '=== SSE Events (${MASC_URL}/sse?room=${ROOM}) ===' && curl -N '${MASC_URL}/sse?room=${ROOM}'" Enter

    # Pane 3: Agent Shell (bottom-right) - interactive shell
    tmux send-keys -t "$SESSION_NAME:0.3" "cd '$BASE_PATH'" Enter
    tmux send-keys -t "$SESSION_NAME:0.3" "echo '=== Agent Shell ===' && echo 'Room: $ROOM | Port: $PORT' && echo 'Use: claude, gemini, codex CLI'" Enter

    # Set pane titles (requires tmux 2.3+)
    tmux select-pane -t "$SESSION_NAME:0.0" -T "Dashboard"
    tmux select-pane -t "$SESSION_NAME:0.1" -T "Tasks"
    tmux select-pane -t "$SESSION_NAME:0.2" -T "SSE Events"
    tmux select-pane -t "$SESSION_NAME:0.3" -T "Shell"

    # Enable pane border status
    tmux set-option -t "$SESSION_NAME" pane-border-status top
    tmux set-option -t "$SESSION_NAME" pane-border-format " #{pane_title} "

    # Set even layout
    tmux select-layout -t "$SESSION_NAME:0" tiled

    # Focus on shell pane for user interaction
    tmux select-pane -t "$SESSION_NAME:0.3"

    success "Session created!"
}

# Attach to session
attach_session() {
    info "Attaching to session... (Detach with Ctrl+b d)"
    tmux attach-session -t "$SESSION_NAME"
}

# Main
main() {
    check_deps

    # Handle arguments
    case "${1:-}" in
        -k|--kill)
            cleanup_session
            exit 0
            ;;
        -h|--help)
            echo "Usage: masc-hub [room] [port]"
            echo "       masc-hub -k|--kill    Kill existing session"
            echo "       masc-hub -h|--help    Show this help"
            echo ""
            echo "Environment:"
            echo "  MASC_CLUSTER_NAME  Room name (default: basename of ME_ROOT)"
            echo "  MASC_PORT          Server port (default: 8935)"
            echo "  MASC_BASE_PATH     Override base path"
            echo ""
            echo "Panes:"
            echo "  Top-left:     Dashboard (masc-watch)"
            echo "  Bottom-left:  Task Board (watch tasks)"
            echo "  Top-right:    SSE Events (curl stream)"
            echo "  Bottom-right: Agent Shell (interactive)"
            exit 0
            ;;
    esac

    # Reuse existing session if available
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        warn "Session '$SESSION_NAME' already exists"
        echo -n "Attach to existing? [Y/n] "
        read -r response
        if [ "${response,,}" != "n" ]; then
            attach_session
            exit 0
        fi
        cleanup_session
    fi

    # Optional: check server, but don't fail
    if ! check_server; then
        echo -n "Continue anyway? [y/N] "
        read -r response
        if [ "${response,,}" != "y" ]; then
            exit 1
        fi
    fi

    create_session
    attach_session
}

main "$@"
