#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="${repo_root}/scripts/check-agent-core-boundary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

make_valid_fixture() {
  rm -rf "${fixture:?}"/*
  mkdir -p "${fixture}/lib" "${fixture}/test"
  : > "${fixture}/lib/dune"
  : > "${fixture}/test/dune"
  : > "${fixture}/models.toml"
}

expect_rejected() {
  local label="$1"
  if AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null 2>&1; then
    echo "boundary self-test: ${label} was accepted" >&2
    exit 1
  fi
}

make_valid_fixture
AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null

rm "${fixture}/models.toml"
expect_rejected "missing model catalog"

make_valid_fixture
mkdir -p "${fixture}/nested"
: > "${fixture}/nested/dune-project"
expect_rejected "nested independent Dune project"

make_valid_fixture
: > "${fixture}/nested.opam"
expect_rejected "independent opam package"

make_valid_fixture
ln -s "${repo_root}/scripts/check-agent-core-boundary.sh" \
  "${fixture}/lib/coordinator_source.ml"
expect_rejected "source symlink"

make_valid_fixture
printf 'type event = Operator_requested | Operator_repair_required | Server_error\n' \
  > "${fixture}/lib/allowed_constructors.ml"
AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null

printf 'open Server_runtime\n' > "${fixture}/lib/open_bypass.ml"
expect_rejected "opened coordinator module"

make_valid_fixture
printf 'module M : sig end = Server_runtime\n' \
  > "${fixture}/lib/constrained_alias_bypass.ml"
expect_rejected "constrained coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/manifest_signature_alias_bypass.ml" <<'EOF'
module M :
  sig
    type t = int
  end =
  Server_runtime
EOF
expect_rejected "manifest signature coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/with_type_alias_bypass.ml" <<'EOF'
module M : S with type t = int = Server_runtime
EOF
expect_rejected "with-type coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/module_type_of_alias_bypass.ml" <<'EOF'
module M : module type of Server_runtime = Server_runtime
EOF
expect_rejected "module-type-of coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/recursive_alias_bypass.ml" <<'EOF'
module rec Safe : S = Safe_impl
and Unsafe : S = Server_runtime
EOF
expect_rejected "recursive coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/parenthesized_alias_bypass.ml" <<'EOF'
module M = ((Server_runtime : S))
EOF
expect_rejected "parenthesized coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/character_literal_alias_bypass.ml" <<'EOF'
let double_quote = '\"'
module M = Server_runtime
let another_double_quote = '\"'
EOF
expect_rejected "character literal hiding a coordinator alias"

make_valid_fixture
cat > "${fixture}/lib/alias_syntax_inert.ml" <<'EOF'
(* module M : sig type t = int end = Server_runtime *)
let documentation = "module M : sig type t = int end = Server_runtime"
type 'a box = 'a
let double_quote = '\"'
let decimal_byte = '\123'
let hex_byte = '\x7f'
let octal_byte = '\o177'
EOF
AGENT_CORE_ROOT="${fixture}" "${gate}" >/dev/null

echo "agent-core boundary self-test: ok"
