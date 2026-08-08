#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
public_count_tokens="$root/lib/llm_provider/count_tokens_sync.mli"
public_http_client="$root/lib/llm_provider/http_client.mli"
private_count_tokens="$root/lib/llm_provider/exact_output_count_tokens.mli"
private_measurement_transport="$root/lib/llm_provider/exact_output_measurement_transport.ml"
callback_checker_source="$root/test/check_public_mli_callbacks.ml"
flow_admission="$root/lib/llm_provider/exact_output_flow_admission.ml"
provider_dune="$root/lib/llm_provider/dune"

if command -v rg >/dev/null 2>&1
then
  search_n() {
    rg -n -- "$@"
  }
  search_q() {
    rg -q -- "$@"
  }
else
  search_n() {
    grep -En -- "$@"
  }
  search_q() {
    grep -Eq -- "$@"
  }
fi

if search_n \
  'measure_completion_request_with_before_dispatch|completion_request_dispatch_error|measurement_transport_stage|before_dispatch:' \
  "$public_count_tokens"
then
  echo "exact-output dispatch fence leaked through public Count_tokens_sync" >&2
  exit 1
fi

if search_n 'before_dispatch:' "$public_http_client"
then
  echo "public Http_client must not expose a pre-dispatch callback" >&2
  exit 1
fi

private_surface_leaked=false
while IFS= read -r interface
do
  if search_n \
    'measurement_dispatch_intent|create_measurement_dispatch_intent|commit_fence|mark_dispatch_started' \
    "$interface"
  then
    private_surface_leaked=true
  fi
done < <(
  find "$root/lib/llm_provider" \
    -maxdepth 1 \
    -name '*.mli' \
    ! -name '*.pp.mli' \
    ! -name 'exact_output_count_tokens.mli' \
    -print
)
if [[ "$private_surface_leaked" == true ]]
then
  echo "private exact-output dispatch capability escaped through another interface" >&2
  exit 1
fi

for private_module in \
  exact_output_count_tokens \
  exact_output_measurement_transport \
  exact_output_flow_admission \
  exact_output_ready_admission
do
  search_q "^[[:space:]]*${private_module}$" "$provider_dune"
done

if search_n 'Http_client_phase_observer' "$flow_admission" "$private_measurement_transport"
then
  echo "exact-output measurement must not infer dispatch from a scoped observer" >&2
  exit 1
fi

search_q "type 'callback_error measurement_dispatch_intent" "$private_count_tokens"
search_q "dispatch_intent:'callback_error measurement_dispatch_intent" "$private_count_tokens"
search_q 'create_measurement_dispatch_intent' "$flow_admission"

callback_checker="$(mktemp)"
trap 'rm -f "$callback_checker"' EXIT
ocamlc \
  -intf-suffix .no-interface \
  -I +compiler-libs \
  ocamlcommon.cma \
  "$callback_checker_source" \
  -o "$callback_checker"
"$callback_checker" \
  --check-exact-transport \
  "$private_measurement_transport"

echo "exact-output single-surface boundary: ok"
