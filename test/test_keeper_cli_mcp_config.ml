(* #10049: tests for Claude Code / Kimi CLI MCP config auto-construction. *)

open Alcotest

module K = Masc_mcp.Keeper_cli_mcp_config

let mkdir_p path =
  let rec loop dir =
    if String.equal dir "" || String.equal dir "." || Sys.file_exists dir
    then ()
    else (
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755)
  in
  loop path
;;

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_base f =
  let base = Filename.temp_file "keeper-cli-mcp-config-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)
;;

let test_build_json_shape () =
  let out = K.build_json ~url:"http://127.0.0.1:8935/mcp" ~bearer_token:"tok" in
  let json = Yojson.Safe.from_string out in
  let open Yojson.Safe.Util in
  let masc =
    json |> member "mcpServers" |> member "masc"
  in
  check string "url field"
    "http://127.0.0.1:8935/mcp"
    (masc |> member "url" |> to_string);
  check string "type field" "http" (masc |> member "type" |> to_string);
  check string "authorization header" "Bearer tok"
    (masc |> member "headers" |> member "Authorization" |> to_string)

let test_feature_flag_env_name () =
  check string "env key is stable"
    "MASC_AUTO_CONSTRUCT_CLAUDE_MCP" K.feature_flag_env

let test_try_construct_disabled_by_default () =
  (* Flag default flipped to true (#10059 validation): explicit "false"
     disables auto-construct and returns None even when token file would
     have been resolvable. *)
  Unix.putenv K.feature_flag_env "false";
  let base = Filename.get_temp_dir_name () in
  let out = K.try_construct_for_keeper ~base_path:base ~agent_name:"nobody" in
  check (option string) "explicit-false flag returns None" None out

let test_try_construct_default_true_no_token () =
  (* Flag default true: still returns None when no token file exists for
     the keeper, so auto-construct fails closed without a credential. *)
  Unix.putenv K.feature_flag_env "";
  let base = Filename.get_temp_dir_name () in
  let out = K.try_construct_for_keeper ~base_path:base ~agent_name:"nobody" in
  check (option string) "missing token returns None" None out

let test_effective_config_prefers_explicit () =
  Unix.putenv K.feature_flag_env "false";
  with_temp_base (fun base ->
    let explicit = {|{"mcpServers":{"masc":{"type":"http"}}}|} in
    let out =
      K.effective_for_keeper
        ~base_path:base
        ~agent_name:"keeper"
        ~configured:(Some explicit)
    in
    check (option string) "explicit config wins" (Some explicit) out)
;;

let test_warning_not_required_when_auto_construct_succeeds () =
  Unix.putenv K.feature_flag_env "";
  with_temp_base (fun base ->
    let auth_dir = Masc_mcp.Auth.auth_dir base in
    mkdir_p auth_dir;
    write_file (Filename.concat auth_dir "keeper.token") "token-for-test\n";
    let effective =
      K.effective_for_keeper ~base_path:base ~agent_name:"keeper" ~configured:None
    in
    let required =
      K.missing_catalog_warning_required_for_effective
        ~requires_runtime_mcp_header_sync:true
        ~effective_claude_mcp_config:effective
    in
    check bool "auto-constructed config suppresses warning" false required)
;;

let test_warning_required_when_auto_construct_fails () =
  Unix.putenv K.feature_flag_env "";
  with_temp_base (fun base ->
    let effective =
      K.effective_for_keeper ~base_path:base ~agent_name:"keeper" ~configured:None
    in
    let required =
      K.missing_catalog_warning_required_for_effective
        ~requires_runtime_mcp_header_sync:true
        ~effective_claude_mcp_config:effective
    in
    check bool "missing token keeps warning" true required)
;;

let test_warning_not_required_without_runtime_mcp_sync () =
  let required =
    K.missing_catalog_warning_required_for_effective
      ~requires_runtime_mcp_header_sync:false
      ~effective_claude_mcp_config:None
  in
  check bool "non-cli labels do not warn" false required
;;

let () =
  run "keeper_cli_mcp_config" [
    "build_json", [
      test_case "shape includes url/type/Authorization" `Quick
        test_build_json_shape;
    ];
    "flag", [
      test_case "env key stable" `Quick test_feature_flag_env_name;
      test_case "explicit false → None" `Quick test_try_construct_disabled_by_default;
      test_case "default true + no token → None" `Quick
        test_try_construct_default_true_no_token;
    ];
    "effective", [
      test_case "explicit config wins" `Quick test_effective_config_prefers_explicit;
      test_case "auto-construct suppresses warning" `Quick
        test_warning_not_required_when_auto_construct_succeeds;
      test_case "missing token keeps warning" `Quick
        test_warning_required_when_auto_construct_fails;
      test_case "runtime MCP sync not needed" `Quick
        test_warning_not_required_without_runtime_mcp_sync;
    ]
  ]
