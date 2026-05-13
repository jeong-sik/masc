#!/usr/bin/env bash
# CI gate: every Eio.Net.accept ~sw must be followed by a per-connection
# Eio.Switch.run that closes the accepted flow on release.
#
# Background
#   Eio.Net.accept ~sw socket returns a [flow] resource registered
#   against the supplied switch. When the same long-lived server [sw]
#   is passed to both [accept] and the per-connection [Fiber.fork],
#   the flow stays alive — and its kernel FD lingers in [CLOSED] —
#   until the server itself shuts down. Under sustained connection
#   churn the FD count grows unbounded and trips the
#   [admission_queue_rejected] threshold, starving every keeper
#   subprocess.
#
#   Real fires:
#   - #10840 fixed the WS standalone accept loop after a 1Hz
#     dashboard reconnect (claude-in-chrome) leaked ~3 600 FDs/h
#     and tripped admission at fd count 3762/3000.
#   - #10846 closed the audit by patching the last unsafe site
#     in [http_server_eio.ml].
#
# Contract
#   Each [Eio.Net.accept ~sw] callsite must, within the next
#   [WINDOW_LINES] lines, contain:
#     1. [Eio.Switch.run] (per-connection switch), AND
#     2. [Switch.on_release] OR [Eio.Flow.close] OR the local
#        [on_connection_release] helper (explicit FD close when the
#        per-connection switch releases).
#
#   Either marker absent => the accept site is leaking the FD when
#   the handler exits.
#
# Output
#   Exit 0 — every accept site is paired with a Switch.run + close.
#   Exit 1 — at least one site missing the pattern; locations printed.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

WINDOW_LINES=20

failed=0

# Collect every "Eio.Net.accept ~sw" hit as file:line.
hits=$(rg -n --no-heading 'Eio\.Net\.accept[[:space:]]+~sw' lib/ bin/ 2>/dev/null || true)

if [ -z "$hits" ]; then
  echo "check-accept-fd-lifecycle: no Eio.Net.accept ~sw callsites found"
  exit 0
fi

while IFS= read -r hit; do
  file=$(printf '%s\n' "$hit" | cut -d: -f1)
  line=$(printf '%s\n' "$hit" | cut -d: -f2)
  # Read the next WINDOW_LINES lines (inclusive of the accept line).
  end=$((line + WINDOW_LINES))
  window=$(sed -n "${line},${end}p" "$file")

  has_switch_run=0
  has_close=0
  printf '%s\n' "$window" | grep -q 'Eio\.Switch\.run' && has_switch_run=1
  printf '%s\n' "$window" \
    | grep -qE 'Switch\.on_release|Eio\.Flow\.close|Eio\.Resource\.close|on_connection_release' \
      && has_close=1

  if [ "$has_switch_run" -ne 1 ] || [ "$has_close" -ne 1 ]; then
    echo "  FAIL  ${file}:${line}: Eio.Net.accept ~sw without per-connection Switch.run + Flow.close within ${WINDOW_LINES} lines"
    failed=1
  fi
done <<< "$hits"

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "check-accept-fd-lifecycle: at least one accept site is missing the FD-release pattern."
  echo "Reference: lib/http_server_h2.ml accept loop, or fixes #10840 + #10846."
  exit 1
fi

count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
echo "check-accept-fd-lifecycle: ok (${count} accept site(s) verified)"
