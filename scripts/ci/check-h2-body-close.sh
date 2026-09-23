#!/usr/bin/env bash
# CI gate: an H2 response body is closed only through
# [Server_h2_gateway_helpers.h2_close_after_flush].
#
# Background
#   h2 0.13.0 ends the stream when a closed body still has bytes pending and
#   the send window is 0 (anmonteiro/ocaml-h2#278). A response larger than the
#   client's window then arrives as a 200 with a short body, and when several
#   streams share the connection window the later ones arrive empty. Ten sites
#   under lib/ wrote a body and closed it at once; #37942 routed all of them
#   through h2_close_after_flush, which closes from the flush callback.
#
#   The helper does not stop a new route from calling H2.Body.Writer.close
#   again, and a reader cannot tell the two apart from one line. That is what
#   this guard blocks, for as long as the workaround lives.
#
# Rule
#   1. The .ml files under lib/ and bin/ carry exactly one
#      H2.Body.Writer.close: the one inside h2_close_after_flush in
#      lib/server/server_h2_gateway_helpers.ml. Only .ml is read, so an .mli
#      is free to name the function the way that file's docstring does.
#   2. No .ml under lib/ or bin/ opens H2 or binds a module alias for
#      H2.Body, because either spelling hides rule 1 from a text search.
#      There is no such file today, so this costs nothing and keeps rule 1
#      honest.
#
# Removing the workaround
#   When masc requires an h2 release carrying the upstream fix, delete
#   h2_close_after_flush, put H2.Body.Writer.close back at its call sites and
#   delete this guard in the same change.
#
# Output
#   Exit 0 — the only close is the helper's, and nothing hides H2.Body.
#   Exit 1 — otherwise; the offending lines are printed.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

helper_file='lib/server/server_h2_gateway_helpers.ml'

# rg exits 1 on no match and 2 on error. A `|| true` would erase the
# difference and report a clean tree when the search itself broke.
search() {
  local pattern="$1"
  local status=0
  rg -n --no-heading -g '*.ml' "$pattern" lib bin || status=$?
  if [ "$status" -gt 1 ]; then
    echo "check-h2-body-close: rg failed with status ${status}" >&2
    return "$status"
  fi
}

failed=0

close_hits=$(search 'H2\.Body\.Writer\.close')
outside=$(printf '%s\n' "$close_hits" | grep -v "^${helper_file}:" | grep . || true)
inside=$(printf '%s\n' "$close_hits" | grep -c "^${helper_file}:" || true)

if [ -n "$outside" ]; then
  echo "check-h2-body-close: H2.Body.Writer.close outside the helper:"
  printf '%s\n' "$outside" | sed 's/^/  FAIL  /'
  echo "        Close H2 response bodies with"
  echo "        Server_h2_gateway_helpers.h2_close_after_flush, which closes"
  echo "        from the flush callback. A direct close cuts a body larger"
  echo "        than the peer's flow-control window (ocaml-h2#278, #37906)."
  failed=1
fi

if [ "$inside" -ne 1 ]; then
  echo "check-h2-body-close: ${helper_file} has ${inside} H2.Body.Writer.close,"
  echo "        expected exactly 1, the one inside h2_close_after_flush."
  echo "        If the helper is gone because h2 carries the upstream fix,"
  echo "        delete this guard in the same change."
  failed=1
fi

hidden=$(search '^\s*(let )?open H2\b|^\s*module\s+[A-Z][A-Za-z0-9_]*\s*=\s*H2\.Body\b')
if [ -n "$hidden" ]; then
  echo "check-h2-body-close: H2.Body reachable under another name:"
  printf '%s\n' "$hidden" | sed 's/^/  FAIL  /'
  echo "        This guard finds closes by the text H2.Body.Writer.close, so"
  echo "        an open or an alias would hide one. Spell H2.Body.Writer out,"
  echo "        or widen this guard in the same change."
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "check-h2-body-close: ok (1 close, inside h2_close_after_flush)"
