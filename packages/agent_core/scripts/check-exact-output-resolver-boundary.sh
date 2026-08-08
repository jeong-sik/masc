#!/usr/bin/env bash
set -eEuo pipefail

trap 'status=$?; printf "exact-output resolver boundary ratchet aborted at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$status"' ERR

required_basenames=(
  exact_output.ml
  exact_output_flow.ml
  exact_output_resolver.ml
  exact_output_catalog_binding.ml
  exact_output_flow_admission.ml
  exact_output_ready_admission.ml
  exact_output_plan.ml
  complete_common.ml
  backend_anthropic.ml
  backend_ollama.ml
  backend_openai.ml
  backend_openai_serialize.ml
  backend_openai_responses.ml
  backend_gemini.ml
  backend_glm.ml
)

if [[ "$#" -ne "${#required_basenames[@]}" ]]; then
  echo \
    "usage: $0 ${required_basenames[*]}" \
    >&2
  exit 2
fi

source_files=("$@")
for source_file in "${source_files[@]}"; do
  if [[ ! -f "$source_file" ]]; then
    echo "exact-output resolver boundary source missing: $source_file" >&2
    exit 2
  fi
done

for required in "${required_basenames[@]}"; do
  found=false
  for source_file in "${source_files[@]}"; do
    if [[ "$(basename "$source_file")" == "$required" ]]; then
      found=true
      break
    fi
  done
  if [[ "$found" != true ]]; then
    echo "exact-output resolver boundary source omitted: $required" >&2
    exit 2
  fi
done

# Preserve line numbers while removing nested OCaml comments, ordinary strings,
# and quoted strings. Ratchets must inspect code tokens, not examples or
# historical names in comments and diagnostics.
strip_ocaml_noncode() {
  awk '
    BEGIN {
      comment_depth = 0
      in_string = 0
      escaped = 0
      in_quoted = 0
      quoted_end = ""
    }
    {
      line = $0
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        next_c = i < length(line) ? substr(line, i + 1, 1) : ""
        if (comment_depth > 0) {
          if (c == "(" && next_c == "*") {
            comment_depth++
            out = out "  "
            i++
          } else if (c == "*" && next_c == ")") {
            comment_depth--
            out = out "  "
            i++
          } else {
            out = out " "
          }
        } else if (in_quoted) {
          if (substr(line, i, length(quoted_end)) == quoted_end) {
            out = out sprintf("%*s", length(quoted_end), "")
            i += length(quoted_end) - 1
            in_quoted = 0
            quoted_end = ""
          } else {
            out = out " "
          }
        } else if (in_string) {
          out = out " "
          if (escaped) {
            escaped = 0
          } else if (c == "\\") {
            escaped = 1
          } else if (c == "\"") {
            in_string = 0
          }
        } else if (c == "(" && next_c == "*") {
          comment_depth = 1
          out = out "  "
          i++
        } else if (c == "\"") {
          in_string = 1
          out = out " "
        } else if (match(substr(line, i), /^\{[A-Za-z0-9_]*\|/)) {
          opener = substr(line, i, RLENGTH)
          delimiter = substr(opener, 2, length(opener) - 3)
          quoted_end = "|" delimiter "}"
          in_quoted = 1
          out = out sprintf("%*s", length(opener), "")
          i += length(opener) - 1
        } else {
          out = out c
        }
      }
      print out
    }
  '
}

scan_code() {
  local description="$1"
  local pattern="$2"
  shift 2
  local failed=false
  local source_file hits
  for source_file in "$@"; do
    hits="$(strip_ocaml_noncode < "$source_file" | grep -En -- "$pattern" || true)"
    if [[ -n "$hits" ]]; then
      while IFS= read -r hit; do
        printf '%s:%s\n' "$source_file" "$hit" >&2
      done <<< "$hits"
      failed=true
    fi
  done
  if [[ "$failed" == true ]]; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

# [Cli_common_env.trim_non_empty] is a pure normalization SSOT, not an ambient
# environment read. Permit only that exact identifier; every other
# [Cli_common_env.*] use remains a boundary violation. The token boundary keeps
# similarly prefixed helpers from inheriting the exception.
scan_cli_common_env_usage() {
  local failed=false
  local source_file hits
  for source_file in "$@"; do
    hits="$(
      strip_ocaml_noncode < "$source_file" \
        | awk '{
            gsub(/Cli_common_env[.]trim_non_empty([^[:alnum:]_]|$)/, "")
            print
          }' \
        | grep -En -- 'Cli_common_env[.][[:alnum:]_]+' \
        || true
    )"
    if [[ -n "$hits" ]]; then
      while IFS= read -r hit; do
        printf '%s:%s\n' "$source_file" "$hit" >&2
      done <<< "$hits"
      failed=true
    fi
  done
  if [[ "$failed" == true ]]; then
    echo \
      "exact-output boundary violation: ambient Cli_common_env lookup found" \
      >&2
    return 1
  fi
}

# Print only explicitly named top-level OCaml [let] definitions while keeping
# one output line per input line. This lets a boundary rule follow a concrete
# exact-output call path without granting a file-wide exemption to a legacy
# wrapper in the same module.
extract_named_functions() {
  local source_file="$1"
  local names="$2"
  strip_ocaml_noncode < "$source_file" \
    | awk -v names="$names" '
    BEGIN {
      count = split(names, requested, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (requested[i] != "") required[requested[i]] = 1
      }
      capture = 0
    }
    /^let%[[:alnum:]_]+[[:space:]]/ {
      capture = 0
    }
    /^let[[:space:]]/ {
      declaration = $0
      sub(/^let[[:space:]]+(rec[[:space:]]+)?/, "", declaration)
      name = declaration
      sub(/[[:space:](].*$/, "", name)
      capture = (name in required)
      if (capture) found[name] = 1
    }
    {
      if (capture) print $0
      else print ""
    }
    END {
      missing = 0
      for (name in required) {
        if (!found[name]) {
          print "exact-output ratchet function missing: " name > "/dev/stderr"
          missing = 1
        }
      }
      if (missing) exit 3
    }
  '
}

scan_named_functions() {
  local description="$1"
  local pattern="$2"
  local source_file="$3"
  local names="$4"
  local extracted hits
  extracted="$(mktemp)"
  if ! extract_named_functions "$source_file" "$names" > "$extracted"; then
    rm -f "$extracted"
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  hits="$(strip_ocaml_noncode < "$extracted" | grep -En -- "$pattern" || true)"
  rm -f "$extracted"
  if [[ -n "$hits" ]]; then
    while IFS= read -r hit; do
      printf '%s:%s\n' "$source_file" "$hit" >&2
    done <<< "$hits"
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

# Print every top-level definition except the explicitly named functions while
# preserving one output line per input line. This ratchets exclusive ownership
# of effects such as target-map lookup and Provider_config secret injection.
exclude_named_functions() {
  local source_file="$1"
  local names="$2"
  strip_ocaml_noncode < "$source_file" \
    | awk -v names="$names" '
    BEGIN {
      count = split(names, requested, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (requested[i] != "") excluded_names[requested[i]] = 1
      }
      exclude = 0
    }
    /^let%[[:alnum:]_]+[[:space:]]/ {
      exclude = 0
    }
    /^let[[:space:]]/ {
      declaration = $0
      sub(/^let[[:space:]]+(rec[[:space:]]+)?/, "", declaration)
      name = declaration
      sub(/[[:space:](].*$/, "", name)
      exclude = (name in excluded_names)
      if (exclude) found[name] = 1
    }
    {
      if (exclude) print ""
      else print $0
    }
    END {
      missing = 0
      for (name in excluded_names) {
        if (!found[name]) {
          print "exact-output ratchet function missing: " name > "/dev/stderr"
          missing = 1
        }
      }
      if (missing) exit 3
    }
  '
}

scan_outside_named_functions() {
  local description="$1"
  local pattern="$2"
  local source_file="$3"
  local names="$4"
  local extracted hits
  extracted="$(mktemp)"
  if ! exclude_named_functions "$source_file" "$names" > "$extracted"; then
    rm -f "$extracted"
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  hits="$(strip_ocaml_noncode < "$extracted" | grep -En -- "$pattern" || true)"
  rm -f "$extracted"
  if [[ -n "$hits" ]]; then
    while IFS= read -r hit; do
      printf '%s:%s\n' "$source_file" "$hit" >&2
    done <<< "$hits"
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

require_code_pattern() {
  local description="$1"
  local pattern="$2"
  local source_file="$3"
  if ! strip_ocaml_noncode < "$source_file" | grep -E -- "$pattern" >/dev/null; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

# Match a declaration across formatting-only line breaks. The producer is
# fully consumed by awk before grep runs, avoiding grep -q/SIGPIPE failures
# under pipefail.
require_code_sequence() {
  local description="$1"
  local pattern="$2"
  local source_file="$3"
  local compact
  compact="$(strip_ocaml_noncode < "$source_file" | awk '{ printf "%s ", $0 } END { print "" }')"
  if ! grep -E -- "$pattern" <<< "$compact" >/dev/null; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

require_code_occurrence_count() {
  local description="$1"
  local pattern="$2"
  local expected="$3"
  local source_file="$4"
  local actual
  actual="$(
    strip_ocaml_noncode < "$source_file" \
      | awk -v pattern="$pattern" '
          {
            remaining = $0
            while (match(remaining, pattern)) {
              count++
              remaining = substr(remaining, RSTART + RLENGTH)
            }
          }
          END { print count + 0 }
        '
  )"
  if [[ "$actual" -ne "$expected" ]]; then
    echo \
      "exact-output boundary violation: $description (expected $expected, found $actual)" \
      >&2
    return 1
  fi
}

scan_code_sequence() {
  local description="$1"
  local pattern="$2"
  local source_file="$3"
  local compact
  compact="$(strip_ocaml_noncode < "$source_file" | awk '{ printf "%s ", $0 } END { print "" }')"
  if grep -E -- "$pattern" <<< "$compact" >/dev/null; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

require_named_function_pattern() {
  local description="$1"
  local pattern="$2"
  local source_file="$3"
  local name="$4"
  local extracted compact
  extracted="$(mktemp)"
  if ! extract_named_functions "$source_file" "$name" > "$extracted"; then
    rm -f "$extracted"
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  compact="$(awk '{ printf "%s ", $0 } END { print "" }' "$extracted")"
  if ! grep -E -- "$pattern" <<< "$compact" >/dev/null; then
    rm -f "$extracted"
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  rm -f "$extracted"
}

extract_named_type_block() {
  local source_file="$1"
  local type_name="$2"
  strip_ocaml_noncode < "$source_file" \
    | awk -v target="$type_name" '
    BEGIN {
      capture = 0
      found = 0
      done = 0
        }
        function declaration_name(line) {
          sub(/^type[[:space:]]+/, "", line)
          sub(/[^[:alnum:]_].*$/, "", line)
          return line
        }
        /^type[[:space:]]+/ {
          current = declaration_name($0)
          if (capture) {
            capture = 0
            done = 1
          }
          if (!done && current == target) {
            capture = 1
            found = 1
          }
        }
        capture && /^(val|module|exception|class|include|external|open)[[:space:]]/ {
          capture = 0
          done = 1
        }
        capture {
          print
        }
        END {
          if (!found) exit 3
        }
      '
}

require_type_block_pattern() {
  local description="$1"
  local source_file="$2"
  local type_name="$3"
  local pattern="$4"
  local block compact
  if ! block="$(extract_named_type_block "$source_file" "$type_name")"; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  compact="$(printf '%s\n' "$block" | awk '{ printf "%s ", $0 } END { print "" }')"
  if ! grep -E -- "$pattern" <<< "$compact" >/dev/null; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

require_opaque_type() {
  local description="$1"
  local source_file="$2"
  local type_name="$3"
  local block compact
  if ! block="$(extract_named_type_block "$source_file" "$type_name")"; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  compact="$(printf '%s\n' "$block" | awk '{ printf "%s ", $0 } END { print "" }')"
  if grep -E -- \
    "type[[:space:]]+${type_name}[[:space:]]*:?[[:space:]]*=" \
    <<< "$compact" \
    >/dev/null
  then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
}

require_type_constructor_set() {
  local description="$1"
  local source_file="$2"
  local type_name="$3"
  shift 3
  local block actual expected
  if ! block="$(extract_named_type_block "$source_file" "$type_name")"; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  actual="$(
    printf '%s\n' "$block" \
      | awk '
          {
            rest = $0
            while (match(rest, /(^|[=|])[[:space:]]*[A-Z][[:alnum:]_]*/)) {
              constructor = substr(rest, RSTART, RLENGTH)
              sub(/^[=|][[:space:]]*/, "", constructor)
              sub(/^[[:space:]]*/, "", constructor)
              print constructor
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
        ' \
      | sort -u \
      | paste -s -d ' ' -
  )"
  expected="$(printf '%s\n' "$@" | sort -u | paste -s -d ' ' -)"
  if [[ "$actual" != "$expected" ]]; then
    echo \
      "exact-output boundary violation: $description (expected: $expected; actual: $actual)" \
      >&2
    return 1
  fi
}

require_type_field_set() {
  local description="$1"
  local source_file="$2"
  local type_name="$3"
  shift 3
  local block actual expected
  if ! block="$(extract_named_type_block "$source_file" "$type_name")"; then
    echo "exact-output boundary violation: $description" >&2
    return 1
  fi
  actual="$(
    printf '%s\n' "$block" \
      | awk '
          {
            rest = $0
            while (match(rest, /(^|[;{])[[:space:]]*[a-z][[:alnum:]_]*[[:space:]]*:/)) {
              field = substr(rest, RSTART, RLENGTH)
              sub(/^[;{][[:space:]]*/, "", field)
              sub(/^[[:space:]]*/, "", field)
              sub(/[[:space:]]*:$/, "", field)
              print field
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
        ' \
      | sort -u \
      | paste -s -d ' ' -
  )"
  expected="$(printf '%s\n' "$@" | sort -u | paste -s -d ' ' -)"
  if [[ "$actual" != "$expected" ]]; then
    echo \
      "exact-output boundary violation: $description (expected: $expected; actual: $actual)" \
      >&2
    return 1
  fi
}

scan_public_error_accessors() {
  local source_file="$1"
  local hits
  hits="$(
    strip_ocaml_noncode < "$source_file" \
      | awk '
          match($0, /^[[:space:]]*val[[:space:]]+(target_selection_error|wire_admission_error|admission_error)_[[:alnum:]_]+/) {
            accessor = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*val[[:space:]]+/, "", accessor)
            if (accessor != "target_selection_error_disposition" && accessor != "admission_error_disposition") {
              printf "%d:%s\n", NR, $0
            }
          }
        '
  )"
  if [[ -n "$hits" ]]; then
    while IFS= read -r hit; do
      printf '%s:%s\n' "$source_file" "$hit" >&2
    done <<< "$hits"
    echo \
      "exact-output boundary violation: detailed exact-output error accessor escaped" \
      >&2
    return 1
  fi
}

exact_output_source=""
exact_output_flow_source=""
exact_output_flow_admission_source=""
exact_output_ready_admission_source=""
resolver_source=""
catalog_binding_source=""
exact_output_plan_source=""
anthropic_source=""
downstream_sources=()
for source_file in "${source_files[@]}"; do
  case "$(basename "$source_file")" in
    exact_output.ml) exact_output_source="$source_file" ;;
    exact_output_flow.ml)
      exact_output_flow_source="$source_file"
      downstream_sources+=("$source_file")
      ;;
    exact_output_flow_admission.ml)
      exact_output_flow_admission_source="$source_file"
      downstream_sources+=("$source_file")
      ;;
    exact_output_ready_admission.ml)
      exact_output_ready_admission_source="$source_file"
      downstream_sources+=("$source_file")
      ;;
    exact_output_resolver.ml) resolver_source="$source_file" ;;
    exact_output_catalog_binding.ml) catalog_binding_source="$source_file" ;;
    exact_output_plan.ml)
      exact_output_plan_source="$source_file"
      downstream_sources+=("$source_file")
      ;;
    backend_anthropic.ml) anthropic_source="$source_file" ;;
    *) downstream_sources+=("$source_file") ;;
  esac
done

# Provider_config.capabilities_for_config_model is deliberately allowed: it
# reads only the capability snapshot already frozen into the selected config.
ambient_forbidden='Provider_catalog|Provider_runtime_binding|Provider_registry\.default|Model_catalog\.(global|set_global|set_global_overlay|clear_global|load_default|load_file)|Capability_manifest|(Capabilities|Caps)\.(for_[[:alnum:]_]+|[[:alnum:]_]+_for_(model_id|provider_id|config_model))|Sys\.getenv(_opt)?|Unix\.getenv(_opt)?|select_target|Marshal'
scan_code \
  "global, legacy, ambient, or representation-dependent lookup found" \
  "$ambient_forbidden" \
  "$exact_output_source" \
  "$resolver_source" \
  "$catalog_binding_source" \
  "${downstream_sources[@]}"
scan_cli_common_env_usage \
  "$exact_output_source" \
  "$resolver_source" \
  "$catalog_binding_source" \
  "${downstream_sources[@]}"
# Only the canonical resolver loader may parse the private structural catalog.
# Admission and every Complete_common serializer descendant consume frozen
# Provider_config values.
scan_code \
  "downstream structural catalog lookup found" \
  'Model_catalog' \
  "$exact_output_source" \
  "${downstream_sources[@]}"

model_identity_classifier='String\.(lowercase_ascii|uppercase_ascii|starts_with|ends_with|contains|equal).*model(_id)?|model(_id)?.*String\.(lowercase_ascii|uppercase_ascii|starts_with|ends_with|contains|equal)'
scan_code \
  "provider/model identity classification escaped the private catalog boundary" \
  "$model_identity_classifier" \
  "$exact_output_source" \
  "$resolver_source"
require_code_pattern \
  "private catalog boundary lost exact model identity matching" \
  'String\.equal.*model_id|model_id.*String\.equal' \
  "$catalog_binding_source"

scan_code \
  "resolver or catalog binding depends on the public facade or execution plan" \
  'Exact_output\.|Exact_output_plan|Exact_output_execution|Plan\.|Exec\.' \
  "$resolver_source" \
  "$catalog_binding_source"
require_code_pattern \
  "resolver no longer delegates identity binding to its private catalog boundary" \
  'Exact_output_catalog_binding' \
  "$resolver_source"
# Anthropic intentionally retains one legacy/non-exact wrapper that resolves
# the historical ambient thinking policy. Do not whitelist that symbol across
# the module. Instead, ratchet the exact entrypoints and every private helper
# on their frozen-policy artifact path, then pin the callers that enter it.
anthropic_exact_functions='request_payload effort_for_config thinking_config_for_config validate_thinking_controls output_config_for_config required_output_token_receipt required_output_token_error_message required_output_token_value build_request_payload build_request_artifact_from_receipt build_request_artifact_with_thinking_control'
complete_common_exact_functions='thinking_control_request_rejection_reason validate_thinking_control_request validate_all_with_thinking_control serialize_http_request_with_thinking_control'
exact_region_forbidden="${ambient_forbidden}|Model_catalog|nonexact_anthropic_thinking_control"
scan_named_functions \
  "Anthropic frozen-policy artifact path performed an ambient or catalog lookup" \
  "$exact_region_forbidden" \
  "$anthropic_source" \
  "$anthropic_exact_functions"
scan_named_functions \
  "Complete_common exact validate/serialize path performed an ambient or catalog lookup" \
  "$exact_region_forbidden" \
  "$(dirname "$exact_output_source")/complete_common.ml" \
  "$complete_common_exact_functions"

require_code_pattern \
  "Exact_output_plan no longer calls frozen-policy validation" \
  'Complete_common\.validate_all_with_thinking_control' \
  "$exact_output_plan_source"
require_code_pattern \
  "Exact_output_plan no longer calls frozen-policy serialization" \
  'Complete_common\.serialize_http_request_with_thinking_control' \
  "$exact_output_plan_source"
require_named_function_pattern \
  "Complete_common serialization policy lost the frozen Anthropic artifact entrypoint" \
  'Backend_anthropic\.build_request_artifact_with_thinking_control' \
  "$(dirname "$exact_output_source")/complete_common.ml" \
  'serialize_http_request_with_policy'
require_named_function_pattern \
  "Complete_common exact serializer no longer delegates to the serialization policy" \
  'serialize_http_request_with_policy' \
  "$(dirname "$exact_output_source")/complete_common.ml" \
  'serialize_http_request_with_thinking_control'
require_named_function_pattern \
  "Complete_common exact serializer no longer selects the frozen Anthropic policy" \
  'Frozen_anthropic_thinking_control[[:space:]]+anthropic_thinking_control' \
  "$(dirname "$exact_output_source")/complete_common.ml" \
  'serialize_http_request_with_thinking_control'
require_named_function_pattern \
  "Complete_common exact validator no longer forwards the frozen Anthropic policy" \
  'validate_thinking_control_request[[:space:]]+\?anthropic_thinking_control' \
  "$(dirname "$exact_output_source")/complete_common.ml" \
  'validate_all_with_thinking_control'
require_named_function_pattern \
  "Anthropic frozen artifact entrypoint no longer requires an explicit policy" \
  '~anthropic_thinking_control' \
  "$anthropic_source" \
  'build_request_artifact_with_thinking_control'
require_named_function_pattern \
  "Anthropic frozen artifact entrypoint bypassed its receipt-bound helper" \
  'build_request_artifact_from_receipt' \
  "$anthropic_source" \
  'build_request_artifact_with_thinking_control'
require_named_function_pattern \
  "Anthropic receipt-bound helper no longer forwards the explicit frozen policy" \
  '\?anthropic_thinking_control' \
  "$anthropic_source" \
  'build_request_artifact_from_receipt'

# Pricing is raw catalog evidence only. It must never enter generation,
# identity, admission, serialization, or receipt projections.
scan_code \
  "pricing entered the exact-output functional path" \
  'Pricing|input_per_million|output_per_million|cache_write_multiplier|cache_read_multiplier' \
  "$exact_output_source" \
  "$anthropic_source" \
  "${downstream_sources[@]}"
scan_named_functions \
  "pricing entered resolver generation, identity, or resolution" \
  'Pricing|input_per_million|output_per_million|cache_write_multiplier|cache_read_multiplier' \
  "$resolver_source" \
  'load_resolver_snapshot resolve_target'
scan_named_functions \
  "pricing entered exact catalog binding or functional capability projection" \
  'Pricing|input_per_million|output_per_million|cache_write_multiplier|cache_read_multiplier' \
  "$catalog_binding_source" \
  'resolve_exact capabilities_of_catalog_binding functional_capability_projection anthropic_thinking_control_of_model'

module_dir="$(dirname "$exact_output_source")"
exact_output_interface="$module_dir/exact_output.mli"
resolver_interface="$module_dir/exact_output_resolver.mli"

# The public surface admits an exact catalog member into one opaque,
# snapshot-bound handle. The former syntax-only constructor and overlay/path
# convenience labels must not return under another compatibility layer.
scan_code \
  "legacy exact-output catalog admission surface returned" \
  'type[[:space:]]+catalog_overlay|Unknown_target|\?overlay([[:space:]:]|$)|\?catalog_path([[:space:]:]|$)' \
  "$exact_output_source" \
  "$resolver_source" \
  "$exact_output_interface" \
  "$resolver_interface"
scan_code \
  "raw target_ref constructor or public type returned" \
  '^[[:space:]]*type[[:space:]]+target_ref([[:space:]]*(=|$))|^[[:space:]]*val[[:space:]]+target_ref[[:space:]]*:' \
  "$exact_output_interface"
require_code_pattern \
  "canonical facade lost its opaque admitted target handle" \
  '^[[:space:]]*type[[:space:]]+admitted_target[[:space:]]*$' \
  "$exact_output_interface"
require_code_sequence \
  "catalog admission no longer returns the opaque admitted target handle" \
  'val[[:space:]]+admit_target_ref[[:space:]]*:[[:space:]]*resolver_snapshot[[:space:]]*->[[:space:]]*string[[:space:]]*->[[:space:]]*\(admitted_target,[[:space:]]*target_catalog_admission_error\)[[:space:]]*result' \
  "$exact_output_interface"
require_code_sequence \
  "target resolution no longer consumes only the admitted target handle" \
  'val[[:space:]]+resolve_target[[:space:]]*:[[:space:]]*admitted_target[[:space:]]*->[[:space:]]*\(selected_target,[[:space:]]*target_selection_error\)[[:space:]]*result' \
  "$exact_output_interface"

# Membership lookup is performed exactly when the admitted handle is frozen.
# Resolution may only inspect that handle; accepting or consulting another
# resolver snapshot would permit a same-id target to be rebound after admission.
require_named_function_pattern \
  "catalog admission no longer consults the frozen target map" \
  'snapshot\.targets' \
  "$resolver_source" \
  'admit_target_ref'
require_named_function_pattern \
  "catalog admission no longer performs an exact target-map lookup" \
  'String_map\.(find_opt|mem)' \
  "$resolver_source" \
  'admit_target_ref'
scan_outside_named_functions \
  "target-map lookup escaped catalog admission" \
  'snapshot\.targets' \
  "$resolver_source" \
  'admit_target_ref'

# Credential observations are frozen before admission. Resolution may inject
# only the already-frozen Secret into Provider_config; it must never reread the
# environment, reopen a catalog, rebuild provider config, or create a Secret
# from ambient bytes.
resolve_ambient_forbidden="${ambient_forbidden}|Cli_common_env\.|Model_catalog|Exact_output_catalog_binding|Binding\.|getenv|resolver_snapshot|snapshot|String_map\.(find_opt|mem)|PC\.make|Provider_config\.make|Secret\.of_string"
scan_named_functions \
  "target resolution performed ambient lookup or rebuilt frozen configuration" \
  "$resolve_ambient_forbidden" \
  "$resolver_source" \
  'resolve_target'
scan_named_functions \
  "catalog admission performed environment lookup or normalization" \
  'Cli_common_env\.' \
  "$resolver_source" \
  'admit_target_ref'
require_named_function_pattern \
  "target resolution no longer consumes the frozen credential observation" \
  'credential' \
  "$resolver_source" \
  'resolve_target'
require_named_function_pattern \
  "Provider_config secret injection disappeared from admitted target resolution" \
  'api_key[[:space:]]*=' \
  "$resolver_source" \
  'resolve_target'
scan_outside_named_functions \
  "Provider_config secret injection escaped admitted target resolution" \
  'api_key[[:space:]]*=' \
  "$resolver_source" \
  'resolve_target'

require_code_pattern \
  "canonical facade no longer re-exports the private resolver" \
  'include[[:space:]]+Exact_output_resolver' \
  "$exact_output_source"
scan_code \
  "secondary target projection exposed by the canonical facade" \
  'type[[:space:]]+(resolver_snapshot|selected_target|target_identity)[[:space:]]*=|val[[:space:]]+(target_(identity_id|provider_id|model_id|base_url|request_path)|selected_target_(provider_id|model_id|base_url|request_path)|target_identity_(provider_id|model_id|base_url|request_path))|Invalid_target_ref[[:space:]]+of[[:space:]]+string' \
  "$module_dir/exact_output.mli"
scan_code \
  "secondary capability projection exposed" \
  'val[[:space:]]+(of_model_catalog_entry|exact_output_[[:alnum:]_]+|functional_projection)' \
  "$module_dir/capabilities.mli"
scan_code \
  "catalog target projection exposed" \
  'type[[:space:]]+target_entry|val[[:space:]]+(target_entries|lookup_target_exact|exact_output_[[:alnum:]_]+)' \
  "$module_dir/model_catalog.mli"

for private_module in \
  exact_output_count_tokens \
  exact_output_plan \
  exact_output_execution \
  exact_output_flow \
  exact_output_generation_receipt \
  exact_output_provider_trace \
  exact_output_resolver \
  exact_output_catalog_binding
do
  if ! sed -n '/(private_modules/,/)/p' "$module_dir/dune" \
    | grep -E "^[[:space:]]*$private_module([[:space:]]|\)|$)" >/dev/null; then
    echo "exact-output public facade violation: $private_module is not private" >&2
    exit 1
  fi
done

scan_code \
  "public CountTokens surface exposed exact-output measurement primitives" \
  'exact_completion_(artifact|measurement_request)|freeze_exact_completion_artifact|count_exact_completion_request_with_evidence|exact_generation_artifact_serialization_count' \
  "$module_dir/count_tokens_sync.mli"

# The generic outer executor is private, affine, and policy-free. The facade is
# the only place allowed to interpret exact receipt/cause types.
require_code_pattern \
  "private exact-output flow lost its affine execution gate" \
  'Atomic\.compare_and_set' \
  "$exact_output_flow_source"
require_code_pattern \
  "private exact-output flow no longer terminalizes exceptions and cancellation" \
  'Fun\.protect' \
  "$exact_output_flow_source"
scan_code \
  "private exact-output flow acquired provider, model, tier, pricing, retry, cascade, or string policy" \
  'Provider|provider|Model|model|Tier|tier|Pricing|pricing|Retry|retry|Cascade|cascade|String\.|Str\.|Re\.' \
  "$exact_output_flow_source"
require_code_sequence \
  "canonical facade lost outer exact-flow execution" \
  'val[[:space:]]+execute_flow_once[[:space:]]*:' \
  "$exact_output_interface"
require_code_sequence \
  "canonical facade lost immutable flow snapshot construction" \
  'val[[:space:]]+snapshot_flow[[:space:]]*:' \
  "$exact_output_interface"
require_code_sequence \
  "outer exact flow lost typed candidate-visit progress" \
  'type[[:space:]]+candidate_visit_count([[:space:]]|$)' \
  "$exact_output_interface"
require_type_constructor_set \
  "outer exact flow lost provider-neutral rejection projection" \
  "$exact_output_interface" \
  candidate_rejection_disposition \
  Runtime_slot_unavailable \
  Runtime_contract_rejected \
  Input_contract_rejected \
  Output_requirement_rejected \
  Input_capacity \
  Request_preparation_failed
require_type_block_pattern \
  "outer exact flow lost the typed input-capacity payload" \
  "$exact_output_interface" \
  candidate_rejection_disposition \
  'Input_capacity[[:space:]]+of[[:space:]]+input_capacity_disposition([^[:alnum:]_]|$)'
require_type_constructor_set \
  "outer exact flow lost the closed token/byte capacity projection" \
  "$exact_output_interface" \
  input_capacity_disposition \
  Token_measurement_required \
  Context_window_exceeded \
  Token_capacity_rejected \
  Serialized_request_body_too_large
require_type_constructor_set \
  "outer exact flow lost the closed provider-neutral capacity rejection projection" \
  "$exact_output_interface" \
  token_capacity_rejection \
  Capacity_evidence_not_yet_valid \
  Capacity_evidence_expired \
  Capacity_boundary_unknown \
  Capacity_input_rejected
require_type_field_set \
  "outer exact flow changed the closed token/byte capacity fields" \
  "$exact_output_interface" \
  input_capacity_disposition \
  accepted_through_tokens \
  rejected_from_tokens \
  input_tokens \
  reserved_output_tokens \
  max_context_tokens \
  actual_bytes \
  limit_bytes
require_type_block_pattern \
  "token measurement disposition lost accepted-through token evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'Token_measurement_required[[:space:]]+of[[:space:]]*\{[^}]*accepted_through_tokens[[:space:]]*:'
require_type_block_pattern \
  "token measurement disposition lost rejected-from token evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'Token_measurement_required[[:space:]]+of[[:space:]]*\{[^}]*rejected_from_tokens[[:space:]]*:'
require_type_block_pattern \
  "context-window disposition lost its closed token fields" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'Context_window_exceeded[[:space:]]+of[[:space:]]*\{[^}]*input_tokens[[:space:]]*:[^}]*reserved_output_tokens[[:space:]]*:[^}]*max_context_tokens[[:space:]]*:'
require_type_block_pattern \
  "serialized request disposition lost actual-byte evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'Serialized_request_body_too_large[[:space:]]+of[[:space:]]*\{[^}]*actual_bytes[[:space:]]*:'
require_type_block_pattern \
  "serialized request disposition lost byte-limit evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'Serialized_request_body_too_large[[:space:]]+of[[:space:]]*\{[^}]*limit_bytes[[:space:]]*:'
require_type_block_pattern \
  "outer exact flow changed accepted-through token evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'accepted_through_tokens[[:space:]]*:[[:space:]]*int([^[:alnum:]_]|$)'
require_type_block_pattern \
  "outer exact flow changed rejected-from token evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'rejected_from_tokens[[:space:]]*:[[:space:]]*int[[:space:]]+option([^[:alnum:]_]|$)'
require_type_block_pattern \
  "outer exact flow changed serialized request byte evidence" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'actual_bytes[[:space:]]*:[[:space:]]*int([^[:alnum:]_]|$)'
require_type_block_pattern \
  "outer exact flow changed serialized request byte limit" \
  "$exact_output_interface" \
  input_capacity_disposition \
  'limit_bytes[[:space:]]*:[[:space:]]*int([^[:alnum:]_]|$)'
require_named_function_pattern \
  "exact CountTokens path rebuilt the generation request instead of freezing one artifact" \
  'Backend_anthropic[.]build_request_artifact_with_thinking_control' \
  "$(dirname "$exact_output_source")/exact_output_count_tokens.ml" \
  'freeze_exact_completion_artifact'
scan_named_functions \
  "exact CountTokens artifact returned to legacy generation or count-token reconstruction" \
  'build_request_artifact([^_]|$)|build_count_tokens_request|nonexact_anthropic_thinking_control|serialized_request_body' \
  "$(dirname "$exact_output_source")/exact_output_count_tokens.ml" \
  "freeze_exact_completion_artifact count_tokens_body_of_generation_artifact"
require_opaque_type \
  "target-selection errors stopped being opaque" \
  "$exact_output_interface" \
  target_selection_error
require_opaque_type \
  "wire-admission errors stopped being opaque" \
  "$exact_output_interface" \
  wire_admission_error
require_opaque_type \
  "request-admission errors stopped being opaque" \
  "$exact_output_interface" \
  admission_error
require_code_sequence \
  "outer exact flow lost its OAS-owned identity" \
  'type[[:space:]]+flow_id([[:space:]]|$)' \
  "$exact_output_interface"
require_type_block_pattern \
  "outer exact flow lost immutable candidate visits" \
  "$exact_output_interface" \
  flow_candidate_visit \
  'type[[:space:]]+flow_candidate_visit[[:space:]]*=[[:space:]]*private[[:space:]]*\{'
require_type_field_set \
  "outer exact flow changed immutable candidate-visit fields" \
  "$exact_output_interface" \
  flow_candidate_visit \
  flow_id \
  ordinal \
  identity
require_type_block_pattern \
  "outer exact flow changed candidate-visit flow identity" \
  "$exact_output_interface" \
  flow_candidate_visit \
  'flow_id[[:space:]]*:[[:space:]]*flow_id([^[:alnum:]_]|$)'
require_type_block_pattern \
  "outer exact flow changed candidate-visit ordinal" \
  "$exact_output_interface" \
  flow_candidate_visit \
  'ordinal[[:space:]]*:[[:space:]]*flow_visit_ordinal([^[:alnum:]_]|$)'
require_type_block_pattern \
  "outer exact flow changed candidate-visit identity" \
  "$exact_output_interface" \
  flow_candidate_visit \
  'identity[[:space:]]*:[[:space:]]*flow_candidate_identity([^[:alnum:]_]|$)'
require_code_sequence \
  "candidate rejection no longer stores the immutable visit" \
  'val[[:space:]]+candidate_rejection_visit[[:space:]]*:[[:space:]]*candidate_rejection_receipt[[:space:]]*->[[:space:]]*flow_candidate_visit' \
  "$exact_output_interface"
require_code_sequence \
  "admitted candidate no longer stores the immutable visit" \
  'type[[:space:]]+admitted_flow_candidate[[:space:]]*=[[:space:]]*\{[^}]*visit[[:space:]]*:[[:space:]]*flow_candidate_visit' \
  "$exact_output_interface"
require_code_sequence \
  "execution receipt no longer stores the immutable visit" \
  'type[[:space:]]+flow_attempt_receipt[[:space:]]*=[[:space:]]*private[[:space:]]*\{[^}]*visit[[:space:]]*:[[:space:]]*flow_candidate_visit[^}]*receipt[[:space:]]*:[[:space:]]*receipt' \
  "$exact_output_interface"
require_code_sequence \
  "outer exact flow start stopped failing closed on identity allocation" \
  'val[[:space:]]+start_flow[[:space:]]*:[[:space:]]*flow_snapshot[[:space:]]*->[[:space:]]*\(flow_attempt,[[:space:]]*flow_start_error\)[[:space:]]*result' \
  "$exact_output_interface"
require_named_function_pattern \
  "outer exact flow start stopped allocating one canonical OAS-owned identity" \
  'Random_id[.]create' \
  "$exact_output_source" \
  "start_flow"
require_named_function_pattern \
  "outer exact flow start stopped precomputing immutable visits" \
  'List[.]mapi' \
  "$exact_output_source" \
  "start_flow"
require_opaque_type \
  "outer exact flow lost typed candidate-rejection receipts" \
  "$exact_output_interface" \
  candidate_rejection_receipt
require_code_sequence \
  "outer exact flow stopped freezing caller-declared order directly" \
  'val[[:space:]]+snapshot_flow[[:space:]]*:[[:space:]]*first:flow_candidate[[:space:]]*->[[:space:]]*rest:flow_candidate[[:space:]]+list[[:space:]]*->[[:space:]]*messages:Types[.]message[[:space:]]+list' \
  "$exact_output_interface"
require_code_sequence \
  "outer exact-flow evidence lost its sole declared candidate snapshot" \
  'type[[:space:]]+flow_evidence[[:space:]]*=[[:space:]]*private.*flow_id[[:space:]]*:.*declared_candidate_snapshot.*candidate_visit_count.*measurements.*admissions.*attempts.*advances' \
  "$exact_output_interface"
require_opaque_type \
  "validated exact flow lost its current durable evidence snapshot" \
  "$exact_output_interface" \
  validated_flow_evidence_snapshot
require_code_sequence \
  "validated exact flow lost its direct durable evidence adapter" \
  'val[[:space:]]+snapshot_validated_flow_evidence.*project_accepted:.*project_rejection:.*validated_flow_success.*validated_flow_evidence_snapshot' \
  "$exact_output_interface"
require_code_sequence \
  "validated exact flow lost its parametric semantic verdict or nonempty trace" \
  'type[[:space:]]+([^[:space:]]+[[:space:]]*,[[:space:]]*[^[:space:]]+)[[:space:]]+semantic_verdict[[:space:]]*=.*Accept.*Reject_and_advance.*type[[:space:]]+[^[:space:]]+[[:space:]]+semantic_rejection_trace[[:space:]]*=[[:space:]]*private.*first.*rest' \
  "$exact_output_interface"
require_code_sequence \
  "validated exact flow lost its single declared-flow entrypoint" \
  'val[[:space:]]+execute_flow_once.*validate:[[:space:]]*\(flow_success[[:space:]]*->[[:space:]]*([^[:space:]]+[[:space:]]*,[[:space:]]*[^[:space:]]+)[[:space:]]+semantic_verdict\)' \
  "$exact_output_interface"
scan_code \
  "validated exact flow regained a parallel or compatibility entrypoint" \
  'execute_flow_once_validated|Compatibility entrypoint|always-\[Accept\]' \
  "$exact_output_source" \
  "$exact_output_interface"
scan_code \
  "outer exact flow revived a legacy attempt or admission alias" \
  'candidate_attempt_count|admission_rejection|ready_flow|admit_flow' \
  "$exact_output_source" \
  "$exact_output_interface" \
  "$exact_output_flow_source"
scan_code \
  "outer exact flow acquired an implicit clock or environment policy" \
  'Unix\.gettimeofday|Sys\.getenv|Eio\.Time\.now' \
  "$exact_output_source" \
  "$exact_output_flow_source"
require_code_sequence \
  "outer flow candidate no longer accepts a catalog-admitted target" \
  'val[[:space:]]+make_flow_candidate[[:space:]]*:[[:space:]]*id:string[[:space:]]*->[[:space:]]*admitted_target:admitted_target' \
  "$exact_output_interface"
scan_code \
  "outer flow catalog-admitted target label was rebound to a selected target" \
  'admitted_target[[:space:]]*:[[:space:]]*selected_target' \
  "$exact_output_interface"
require_code_sequence \
  "outer flow candidate no longer stores its catalog-admitted target" \
  'type[[:space:]]+flow_candidate[[:space:]]*=[[:space:]]*\{[^}]*admitted_target[[:space:]]*:[[:space:]]*admitted_target' \
  "$exact_output_source"
scan_named_functions \
  "outer flow selected credentials before current-candidate execution" \
  'resolve_target' \
  "$exact_output_source" \
  "make_flow_candidate snapshot_flow start_flow"
require_code_pattern \
  "outer exact flow no longer prepares only the executing candidate" \
  'let[[:space:]]+execute_flow_candidate([^[:alnum:]_]|$)' \
  "$exact_output_source"
require_named_function_pattern \
  "current exact-flow candidate no longer resolves its frozen target" \
  'resolve_target[[:space:]]+candidate[.]admitted_target' \
  "$exact_output_source" \
  "execute_flow_candidate"
require_named_function_pattern \
  "current exact-flow candidate lost typed target-selection rejection" \
  'Target_selection_rejected' \
  "$exact_output_source" \
  "execute_flow_candidate"
require_named_function_pattern \
  "current exact-flow candidate lost typed request-admission rejection" \
  'Request_admission_rejected' \
  "$exact_output_source" \
  "execute_flow_candidate"
require_code_sequence \
  "outer exact flow lost typed candidate exhaustion" \
  'Flow_candidates_exhausted[[:space:]]+of' \
  "$exact_output_interface"
require_code_sequence \
  "private exact-output flow lost typed advance-error refinement" \
  'advanceable:.*option.*failure:.*advanceable_error' \
  "$module_dir/exact_output_flow.mli"
scan_named_functions \
  "outer exact-flow advance refinement returned to runtime exceptions" \
  'invalid_arg|failwith' \
  "$exact_output_source" \
  "advanceable_flow_failure execute_flow_once"
scan_code \
  "speculative ready-flow admission projection returned" \
  'type[[:space:]]+ready_flow|val[[:space:]]+(ready_flow_admissions|admit_flow)|let[[:space:]]+(ready_flow_admissions|admit_flow)' \
  "$exact_output_interface" \
  "$exact_output_source"
scan_code \
  "obsolete outer-flow admission or attempt-count surface returned" \
  'candidate_attempt_count|admission_rejection|Flow_admission_failed|Flow_candidate_admission_rejected|Flow_step_admission_rejected' \
  "$exact_output_interface" \
  "$exact_output_source" \
  "$module_dir/exact_output_flow.mli" \
  "$exact_output_flow_source"
scan_code \
  "provider, model, credential, or raw serving evidence escaped the public rejection surface" \
  'Missing_target_credential|Target_credential_invalid|Target_credential_read_failed|Unsupported_target_model|Target_selection_rejected|Request_admission_rejected|candidate_rejection_cause|Token_measurement_required[[:space:]]+of[[:space:]]+Serving_constraint[.]t' \
  "$exact_output_interface"
scan_code \
  "raw serving-constraint evidence escaped the public exact-output facade" \
  'Serving_constraint' \
  "$exact_output_interface"
scan_public_error_accessors "$exact_output_interface"
scan_code \
  "before-advance successor lost its immutable flow visit" \
  'next:flow_candidate_identity' \
  "$exact_output_interface"
scan_named_functions \
  "candidate rejection fabricated a call or execution attempt identity" \
  'start_attempt|Call_id|Random_id' \
  "$exact_output_source" \
  "record_candidate_rejection"
scan_code \
  "parallel public exact-output flow module escaped the single facade" \
  '^[[:space:]]*module[[:space:]]+(Flow|Exact_output_flow)' \
  "$exact_output_interface"

echo "exact-output resolver boundary: OK"
