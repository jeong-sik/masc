#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="${repo_root}/scripts/check-agent-core-boundary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/lib" "${fixture}/test"
touch "${fixture}/models.toml" "${fixture}/test/dune"
cat > "${fixture}/lib/dune" <<'EOF'
; masc.string_util is documentation, not a dependency.
(library
 (name agent_core_fixture)
 (public_name masc.agent_core)
 (wrapped false)) ; masc.coordinator is also only a comment.
EOF

AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null

cp "${fixture}/lib/dune" "${fixture}/lib/dune.safe"
printf '\n(rule (action (echo "documentation; still a string"))) (library (name bad) (libraries masc.keeper))\n' >> "${fixture}/lib/dune"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: quoted semicolon hid a reverse MASC dependency" >&2
  exit 1
fi

cp "${fixture}/lib/dune.safe" "${fixture}/lib/dune"
printf '\n(rule (action (echo "documentation\nstill; a string"))) (library (name bad) (libraries masc.keeper))\n' >> "${fixture}/lib/dune"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: multiline quoted semicolon hid a reverse MASC dependency" >&2
  exit 1
fi

cp "${fixture}/lib/dune.safe" "${fixture}/lib/dune"
printf '\n(library (name bad) (libraries masc.keeper))\n' >> "${fixture}/lib/dune"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: reverse MASC dependency was accepted" >&2
  exit 1
fi

rm -rf "${fixture}/lib"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: missing core tree was accepted" >&2
  exit 1
fi

echo "agent-core boundary self-test: ok"
