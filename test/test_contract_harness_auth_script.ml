open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let read_file path = In_channel.with_open_bin path In_channel.input_all

let read_source_file rel = read_file (Filename.concat (source_root ()) rel)

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let substring_index haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if nlen = 0 then Some 0
    else if idx + nlen > hlen then None
    else if String.sub haystack idx nlen = needle then Some idx
    else loop (idx + 1)
  in
  loop 0

let require_contains label source needle =
  check bool label true (contains_substring source needle)

let require_not_contains label source needle =
  check bool label false (contains_substring source needle)

let require_order label source first second =
  match (substring_index source first, substring_index source second) with
  | Some first_idx, Some second_idx ->
      check bool label true (first_idx < second_idx)
  | None, _ -> failf "%s: missing first marker: %s" label first
  | _, None -> failf "%s: missing second marker: %s" label second

let run_bash script =
  let out = Filename.temp_file "contract-harness-auth-out" ".txt" in
  let err = Filename.temp_file "contract-harness-auth-err" ".txt" in
  let out_fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let original_cwd = Sys.getcwd () in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir original_cwd;
        Unix.close out_fd;
        Unix.close err_fd)
      (fun () ->
        Sys.chdir (source_root ());
        Unix.create_process "bash" [| "bash"; "-c"; script |] Unix.stdin out_fd
          err_fd)
  in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let test_default_token_rejects_ambient_masc_token () =
  let script =
    {|
set -euo pipefail
source scripts/harness/lib/mcp_jsonrpc.sh
unset MCP_AUTH_TOKEN
unset MASC_ADMIN_TOKEN
unset MCP_TOKEN
MASC_TOKEN=ambient-token
token="$(mcp_default_auth_token)"
if [ -n "$token" ]; then
  printf 'unexpected ambient fallback: %s\n' "$token" >&2
  exit 10
fi
MCP_TOKEN=canonical-token
if [ "$(mcp_default_auth_token)" != "canonical-token" ]; then
  printf 'MCP_TOKEN not selected\n' >&2
  exit 11
fi
unset MCP_TOKEN
MASC_ADMIN_TOKEN=admin-token
if [ "$(mcp_default_auth_token)" != "admin-token" ]; then
  printf 'MASC_ADMIN_TOKEN not selected\n' >&2
  exit 12
fi
MCP_AUTH_TOKEN=mcp-token
if [ "$(mcp_default_auth_token)" != "mcp-token" ]; then
  printf 'MCP_AUTH_TOKEN not selected first\n' >&2
  exit 13
fi
|}
  in
  let code, stdout, stderr = run_bash script in
  check int "exit code" 0 code;
  check string "stdout" "" stdout;
  check string "stderr" "" stderr

let test_run_all_mints_workspace_token_before_mcp_probe () =
  let source = read_source_file "scripts/harness/contract/run_all.sh" in
  require_contains "mints token" source "harness_mint_admin_token";
  require_contains "assigns minted token to canonical env" source
    "if ! MCP_TOKEN=\"$(";
  require_contains "exports mcp token" source
    "export MCP_TOKEN\nunset MCP_AUTH_TOKEN";
  require_contains "scrubs legacy mcp alias" source "unset MCP_AUTH_TOKEN";
  require_contains "scrubs legacy admin alias" source "unset MASC_ADMIN_TOKEN";
  require_contains "empty token is fatal" source
    "FAIL: contract harness admin token is empty";
  require_order "mint before start" source "harness_mint_admin_token"
    "harness_start_server";
  require_order "mint assignment before canonical export" source
    "if ! MCP_TOKEN=\"$("
    "export MCP_TOKEN\nunset MCP_AUTH_TOKEN";
  require_order "export before initialize readiness" source
    "export MCP_TOKEN\nunset MCP_AUTH_TOKEN"
    "if ! wait_for_mcp_initialize_ready \"$MCP_URL\" 25; then";
  require_order "empty check before initialize readiness" source
    "FAIL: contract harness admin token is empty"
    "if ! wait_for_mcp_initialize_ready \"$MCP_URL\" 25; then"

let test_bootstrap_mints_admin_token_for_base_path () =
  let source = read_source_file "scripts/harness/lib/server_bootstrap.sh" in
  require_contains "bootstrap helper exists" source "harness_mint_admin_token()";
  require_contains "uses login command" source "\"$server_exe\" login";
  require_contains "scrubs ambient auth for login" source
    "env -u MCP_TOKEN -u MCP_AUTH_TOKEN -u MASC_ADMIN_TOKEN -u MASC_TOKEN";
  require_contains "uses isolated base path" source "--base-path \"$base_path\"";
  require_contains "uses target port" source "--port \"$port\"";
  require_contains "uses admin role" source "--role admin";
  require_contains "uses mcp env" source "--client-env MCP_TOKEN";
  require_contains "long lived token" source "--no-expiry";
  require_contains "json output" source "--json";
  require_contains "extracts bearer token" source ".bearer_token // empty";
  require_contains "server start scrubs canonical token" source "unset MCP_TOKEN";
  require_contains "server start scrubs legacy mcp token" source
    "unset MCP_AUTH_TOKEN";
  require_contains "server start scrubs admin token" source
    "unset MASC_ADMIN_TOKEN";
  require_contains "server start scrubs ambient token" source "unset MASC_TOKEN"

let test_mcp_jsonrpc_does_not_fallback_to_masc_token () =
  let source = read_source_file "scripts/harness/lib/mcp_jsonrpc.sh" in
  require_contains "canonical token selected" source "${MCP_TOKEN:-}";
  require_contains "mcp auth token selected" source "${MCP_AUTH_TOKEN:-}";
  require_contains "admin token selected" source "${MASC_ADMIN_TOKEN:-}";
  require_not_contains "no MASC_TOKEN branch" source
    "elif [[ -n \"${MASC_TOKEN:-}\" ]]";
  require_not_contains "no MASC_TOKEN print" source "printf '%s' \"$MASC_TOKEN\""

let () =
  run "contract_harness_auth_script"
    [
      ( "auth",
        [
          test_case "default token rejects ambient MASC_TOKEN" `Quick
            test_default_token_rejects_ambient_masc_token;
          test_case "run_all mints token before MCP probe" `Quick
            test_run_all_mints_workspace_token_before_mcp_probe;
          test_case "bootstrap mints admin token for base path" `Quick
            test_bootstrap_mints_admin_token_for_base_path;
          test_case "mcp_jsonrpc rejects MASC_TOKEN fallback" `Quick
            test_mcp_jsonrpc_does_not_fallback_to_masc_token;
        ] );
    ]
