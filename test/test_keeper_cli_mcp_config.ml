(* #10049: tests for Claude Code / Kimi CLI MCP config auto-construction. *)

open Alcotest

module K = Masc_mcp.Keeper_cli_mcp_config

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
    ]
  ]
