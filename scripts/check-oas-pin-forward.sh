#!/usr/bin/env bash
# Prove that an installed agent_sdk pin SHA moved strictly forward from the
# SSOT pin SHA: EXPECTED_SHA must be an ancestor of INSTALLED_SHA in the
# history of TRACK_REF on REMOTE.
#
# This is the exact proof used by check-oas-pin.sh on the drift path: the
# shared opam switch may be pinned ahead of this checkout's recorded pin when
# a concurrent session on a newer branch repinned agent_sdk.  Forward drift
# is safe to build against (the CMI CRC guard in dune-local.sh keeps _build
# consistent with the actually installed interfaces); backward or divergent
# drift is not.
#
# Usage:
#   scripts/check-oas-pin-forward.sh EXPECTED_SHA INSTALLED_SHA REMOTE TRACK_REF
#
# Exit 0: EXPECTED_SHA is an ancestor of INSTALLED_SHA (forward drift proven).
# Exit 1: not proven — backward, divergent, unreachable, or unverifiable.
#         Callers must treat this as fail-closed; this script never guesses.
#
# Only the TRACK_REF history is fetched (plus whatever it reaches).  An
# INSTALLED_SHA that is not reachable from TRACK_REF cannot be proven forward
# and is rejected, matching the ref-reachability policy of check-oas-pin.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oas-pin-ref.sh
source "${SCRIPT_DIR}/oas-pin-ref.sh"

if [[ $# -ne 4 ]]; then
  echo "usage: $0 EXPECTED_SHA INSTALLED_SHA REMOTE TRACK_REF" >&2
  exit 2
fi

expected_sha="$1"
installed_sha="$2"
remote="$3"
track_ref="$4"

[[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "${installed_sha}" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ "${expected_sha}" != "${installed_sha}" ]] || exit 1
[[ -n "${remote}" && -n "${track_ref}" ]] || exit 1
remote_ref="$(oas_pin_remote_ref "${track_ref}")" || exit 1

scratch="$(mktemp -d -t oas-pin-forward.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT

if ! GIT_DIR="${scratch}" git init -q --bare; then
  exit 1
fi
if ! GIT_DIR="${scratch}" git fetch -q --no-tags "${remote}" \
       "+${remote_ref}:${remote_ref}" 2>/dev/null; then
  exit 1
fi
GIT_DIR="${scratch}" git merge-base --is-ancestor \
  "${expected_sha}" "${installed_sha}" 2>/dev/null
