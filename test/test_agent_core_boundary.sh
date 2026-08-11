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
 (public_name
  masc.agent_core)
 (wrapped false)) ; masc.coordinator is also only a comment.
EOF

AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null

printf 'type event = Operator_requested | Operator_repair_required | Server_error\n' \
  > "${fixture}/lib/allowed_constructors.ml"
AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null
rm "${fixture}/lib/allowed_constructors.ml"

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

cp "${fixture}/lib/dune.safe" "${fixture}/lib/dune"
printf '\n(library (name bad) (public_name masc.agent_core.bad) (libraries masc.keeper))\n' >> "${fixture}/lib/dune"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: public_name line hid a reverse MASC dependency" >&2
  exit 1
fi

cp "${fixture}/lib/dune.safe" "${fixture}/lib/dune"
printf '(library (name bad) (libraries masc_keeper_runtime))\n' > "${fixture}/lib/deps.inc"
printf '\n(include deps.inc)\n' >> "${fixture}/lib/dune"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: included internal MASC dependency was accepted" >&2
  exit 1
fi

cp "${fixture}/lib/dune.safe" "${fixture}/lib/dune"
rm "${fixture}/lib/deps.inc"
printf '\n(library (name bad) (libraries voice_config))\n' >> "${fixture}/lib/dune"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: private coordinator library name was accepted" >&2
  exit 1
fi

cp "${fixture}/lib/dune.safe" "${fixture}/lib/dune"
printf 'open Server_runtime\n' > "${fixture}/lib/open_bypass.ml"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: opened coordinator module was accepted" >&2
  exit 1
fi
rm "${fixture}/lib/open_bypass.ml"

rm -rf "${fixture:?}/lib"
if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
  echo "boundary self-test: missing core tree was accepted" >&2
  exit 1
fi

echo "agent-core boundary self-test: ok"
