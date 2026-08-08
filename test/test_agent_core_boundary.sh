#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="${repo_root}/scripts/check-agent-core-boundary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/lib" "${fixture}/test"
touch "${fixture}/models.toml" "${fixture}/test/dune"
cat > "${fixture}/lib/dune" <<'EOF'
(library
 (name agent_core_fixture)
 (public_name masc.agent_core))
EOF

AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null

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
