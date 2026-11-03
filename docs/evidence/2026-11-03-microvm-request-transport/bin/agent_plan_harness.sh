#!/usr/bin/env bash
# Builds a small program from masc's own Apple boot code, cut verbatim from
# the repository: the plan, its digest, the argv renderer, the inspect parser
# and the assessment. Only what the Apple agent path does not reach is a stub
# (the scratch root constant, the Kata shim id, the policy proxy env).
#
# usage: agent_plan_harness.sh <repo root> <out dir>
# Each piece of keeper_sandbox_microvm.ml runs from the first line of one
# definition to the line before the next one, found by their first lines.
set -euo pipefail
repo=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
microvm="$repo/lib/keeper/keeper_sandbox_microvm.ml"
mkdir -p "$out"
# piece FIRST NEXT: lines of $microvm from the one starting with FIRST up to,
# not including, the one starting with NEXT. Each FIRST must occur once.
piece() {
  local count
  count=$(awk -v s="$1" 'index($0, s) == 1 { n++ } END { print n + 0 }' "$microvm")
  if [ "$count" != 1 ]; then
    echo "agent_plan_harness: '$1' starts $count lines of $microvm" >&2
    exit 1
  fi
  awk -v s="$1" -v e="$2" 'index($0, s) == 1 { on = 1 } on && index($0, e) == 1 { exit } on { print }' "$microvm"
}
{
  cat <<'EOF'
[@@@warning "-a"]
module Exec_ssh_protocol = struct let default_scratch_root = "/tmp" end
module Keeper_microvm_kata_vmm = struct let default_shim_runtime_id = "io.containerd.kata.v2" end
module Agent_core_sha256 = struct
  let digest_string s = Digestif.SHA256.digest_string s
  let to_hex = Digestif.SHA256.to_hex
end
module Keeper_sandbox_runtime_setup = struct
  let sandbox_owner_pid_label_key = "masc.mcp.owner_pid"
  let sandbox_started_at_label_key = "masc.mcp.started_at"
end
module Egress_proxy_decision = struct let client_env ~proxy_url = ["HTTPS_PROXY", proxy_url] end
EOF
  echo "module Keeper_microvm_guest_size = struct"; cat "$repo/lib/config/keeper_microvm_guest_size.ml"; echo "end"
  echo "module Keeper_microvm_backend = struct"; cat "$repo/lib/keeper/keeper_microvm_backend.ml"; echo "end"
  echo "module Keeper_microvm_image_command = struct"; cat "$repo/lib/keeper/keeper_microvm_image_command.ml"; echo "end"
  echo "module Keeper_microvm_boot_plan = struct"; cat "$repo/lib/keeper/keeper_microvm_boot_plan.ml"; echo "end"
  echo "module Sandbox = struct"; echo "module Backend = Keeper_microvm_backend"
  piece 'let command_argv_for backend' '(** Flags Docker takes that [container run] rejects'
  piece 'let work_volume_guest_root = ' '(** What each runtime is told about the network.'
  # policy_proxy .. apple_network_args
  piece '(* The proxy a policy guest is pointed at' 'let network_args_for'
  # label keys, constraint_refusal .. apple_turn_start_argv
  piece '(** The runtime a guest was booted on' '(* [--user uid:gid] is a value'
  piece '(* Apple inspect configuration.' 'let running_of_inspect_json_for'
  echo "end"
  cat "$here/agent_plan_harness_main.ml"
} > "$out/harness.ml"
(cd "$out" && ocamlfind ocamlopt -package yojson,digestif.ocaml -linkpkg harness.ml -o harness)
