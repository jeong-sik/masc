#!/usr/bin/env bash
# Fail when an HTTP route demands a tool name that the tool catalog does not carry.
#
# Route handlers authorize through with_tool_auth/with_tool_actor_auth
# ~tool_name:"...". Authorization
# looks that name up in Tool_catalog and denies outright when the lookup misses:
#
#   lib/auth/auth.ml
#     match Tool_catalog.registered_metadata tool_name with
#     | Some metadata -> check_permission ... metadata.required_permission
#     | None -> Error (Forbidden { action = "use unregistered tool: " ^ tool_name })
#
# So a route whose tool name was never registered is closed to every credential,
# including admin ones. Nothing in the adding PR notices: the string is a literal,
# the code compiles, and the route reads as protected rather than unreachable.
#
# That is how POST /api/v1/prompts sat unusable. The dashboard drew its prompt
# editor with working Save and Clear buttons, the persistence layer was complete,
# and masc_prompt_override was absent from the catalog, so both buttons returned
# insufficient_role for two authenticated agents. The error names a role problem,
# which sends the reader looking at permissions instead of at registration (#29085).
#
# This compares the two lists in a second.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit

demanded="$(mktemp)"
trap 'rm -f "$demanded"' EXIT

rg --only-matching --no-line-number 'with_tool(_actor)?_auth ~tool_name:"[a-z_]+"' lib/server \
  | sed 's/.*"\(.*\)"/\1/' \
  | sort -u > "$demanded"

if [ ! -s "$demanded" ]; then
  echo "[route-tool-catalog] no tool-auth call sites found - the scan pattern is stale"
  exit 1
fi

missing=0
while read -r tool; do
  [ -n "$tool" ] || continue
  if ! rg --quiet --no-line-number "\"$tool\"" \
       lib/tool/tool_catalog.ml lib/tool_catalog_surfaces/*.ml 2>/dev/null; then
    echo "[route-tool-catalog] FAIL - route demands \"$tool\" but no catalog entry declares it"
    echo "                     every credential hits \"use unregistered tool\" on that route"
    missing=$((missing + 1))
  fi
done < "$demanded"

demanded_count="$(wc -l < "$demanded" | tr -d ' ')"

if [ "$missing" -gt 0 ]; then
  echo "[route-tool-catalog] $missing of $demanded_count route tool names are unregistered"
  echo "                     register them in lib/tool/tool_catalog.ml with the permission the route needs"
  exit 1
fi

echo "[route-tool-catalog] OK - $demanded_count route tool names, all registered in the catalog"
