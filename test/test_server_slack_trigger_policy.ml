(* RFC-0317 — the server's resolved-config trigger-policy parser for the Slack
   gateway must delegate to the single canonical grammar in
   [Slack_gateway_state], so production config and the (separately test-covered)
   grammar cannot drift. Mirror of [test_server_discord_trigger_policy].

   These assertions pin the wrapper's contract: an empty value is unset
   (=> default), the four valid forms parse through to the same variant the
   strict grammar yields, and an unparseable value (or empty user_only id)
   falls back to the default rather than producing a half-formed policy. *)

open Alcotest
module G = Server_slack_in_process_gateway
module State = Channel_gate_slack_state

external unsetenv : string -> unit = "masc_test_unsetenv"

let ps p = Slack_gateway_state.trigger_policy_to_string p
let default_str = ps G.default_trigger_policy

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> unsetenv key)
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let with_temp_base f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-slack-trigger-policy-status-%d-%d"
         (Unix.getpid ())
         (Random.bits ()))
  in
  with_env Env_config_core.base_path_env_key base_path (fun () ->
    with_env Env_config_core.base_path_input_env_key base_path f)
;;

let with_temp_toml content f =
  let path = Filename.temp_file "masc-slack-trigger-policy-" ".toml" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       let out = open_out_bin path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr out)
         (fun () -> output_string out content);
       f path)
;;

let load_error_to_string error = G.trigger_policy_load_error_to_string error

let test_with_env_restores_unset () =
  let key = "MASC_SLACK_TRIGGER_POLICY_TEST_UNSET" in
  unsetenv key;
  with_env key "all" (fun () ->
    check (option string) "set inside scope" (Some "all") (Sys.getenv_opt key));
  check (option string) "restored unset" None (Sys.getenv_opt key)
;;

let test_empty_is_default () =
  check string "empty => default" default_str (ps (G.parse_trigger_policy ""))

let test_whitespace_is_default () =
  check string "whitespace => default" default_str
    (ps (G.parse_trigger_policy "   "))

let test_valid_values_parse_through () =
  (* Each valid form yields exactly what the strict grammar yields,
     proving the wrapper delegates rather than re-implementing. *)
  List.iter
    (fun raw ->
      let expected =
        match Slack_gateway_state.parse_trigger_policy raw with
        | Ok p -> ps p
        | Error msg -> failf "strict grammar rejected %S: %s" raw msg
      in
      check string (Printf.sprintf "%S parses through" raw) expected
        (ps (G.parse_trigger_policy raw)))
    [ "mention_only"; "mention_or_thread"; "all"; "user_only:U123" ]

let test_unknown_falls_back_to_default () =
  (* A typo must not produce a policy the operator did not write. The wrapper
     logs (via Log.Server) and returns the default. *)
  check string "typo => default" default_str
    (ps (G.parse_trigger_policy "mention_ony"))

let test_user_only_empty_id_falls_back () =
  (* The strict grammar rejects an empty id; the wrapper falls back to the
     default instead of constructing User_only "". *)
  check string "user_only: empty id => default" default_str
    (ps (G.parse_trigger_policy "user_only:"))

let test_missing_runtime_toml_is_typed_missing () =
  let path = Filename.temp_file "masc-slack-trigger-policy-missing-" ".toml" in
  Sys.remove path;
  match G.load_trigger_policy_from_toml ~path with
  | Ok G.Runtime_toml_missing -> ()
  | Ok G.Trigger_policy_missing ->
    fail "expected missing runtime.toml, got missing key"
  | Ok (G.Trigger_policy_loaded policy) ->
    failf "expected missing runtime.toml, got policy %s" (ps policy)
  | Error error ->
    failf "expected typed missing, got %s" (load_error_to_string error)
;;

let test_dangling_runtime_toml_symlink_is_unreadable () =
  let link_path = Filename.temp_file "masc-slack-trigger-policy-link-" ".toml" in
  Sys.remove link_path;
  let missing_target = link_path ^ ".missing" in
  Unix.symlink missing_target link_path;
  Fun.protect
    ~finally:(fun () -> try Sys.remove link_path with Sys_error _ -> ())
    (fun () ->
       match G.load_trigger_policy_from_toml ~path:link_path with
       | Error (G.Runtime_toml_unreadable _) -> ()
       | Error error ->
         failf "expected unreadable dangling symlink, got %s" (load_error_to_string error)
       | Ok _ -> fail "dangling runtime.toml symlink must not enable fallback")
;;

let test_missing_key_is_deliberate_no_config () =
  with_temp_toml "[server]\nport = 8935\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Ok G.Trigger_policy_missing -> ()
    | Ok G.Runtime_toml_missing -> fail "runtime.toml should exist"
    | Ok (G.Trigger_policy_loaded policy) ->
      failf "expected missing Slack key, got policy %s" (ps policy)
    | Error error ->
      failf "expected missing Slack key, got %s" (load_error_to_string error))
;;

let test_malformed_runtime_toml_is_error () =
  with_temp_toml "[slack\ntrigger_policy = \"all\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Runtime_toml_invalid _) -> ()
    | Error error ->
      failf "expected invalid TOML, got %s" (load_error_to_string error)
    | Ok _ -> fail "malformed runtime.toml must fail closed")
;;

let test_valid_runtime_toml_loads_policy () =
  with_temp_toml "[slack]\ntrigger_policy = \"all\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Ok (G.Trigger_policy_loaded policy) ->
      check string "policy" "all" (ps policy)
    | Ok G.Runtime_toml_missing -> fail "runtime.toml should exist"
    | Ok G.Trigger_policy_missing -> fail "trigger policy should be present"
    | Error error ->
      failf "expected valid policy, got %s" (load_error_to_string error))
;;

let test_wrong_type_runtime_toml_is_error () =
  with_temp_toml "[slack]\ntrigger_policy = 42\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Trigger_policy_invalid _) -> ()
    | Error error ->
      failf "expected invalid policy type, got %s" (load_error_to_string error)
    | Ok _ -> fail "wrong trigger-policy type must fail closed")
;;

let test_wrong_type_slack_parent_is_error () =
  with_temp_toml "slack = \"not-a-table\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Trigger_policy_invalid _) -> ()
    | Error error ->
      failf "expected invalid Slack table, got %s" (load_error_to_string error)
    | Ok _ -> fail "wrong Slack parent type must fail closed")
;;

let test_invalid_runtime_toml_policy_is_error () =
  with_temp_toml "[slack]\ntrigger_policy = \"mention_ony\"\n" (fun path ->
    match G.load_trigger_policy_from_toml ~path with
    | Error (G.Trigger_policy_invalid _) -> ()
    | Error error ->
      failf "expected invalid policy value, got %s" (load_error_to_string error)
    | Ok _ -> fail "invalid trigger-policy value must fail closed")
;;

let test_missing_bot_token_is_typed_auth_error () =
  let auth_test ~token:_ = fail "auth.test must not run without a bot token" in
  match G.resolve_authenticated_workspace ~auth_test ~bot_token:None with
  | Error G.Bot_token_missing -> ()
  | Error _ -> fail "expected Bot_token_missing"
  | Ok _ -> fail "missing bot token must fail closed"
;;

let test_auth_test_failure_is_typed_auth_error () =
  let auth_test ~token:_ = Error (Slack_rest_client.Network "offline") in
  match
    G.resolve_authenticated_workspace ~auth_test ~bot_token:(Some "xoxb-test")
  with
  | Error (G.Auth_test_failed (Slack_rest_client.Network "offline")) -> ()
  | Error _ -> fail "expected typed auth.test failure"
  | Ok _ -> fail "auth.test failure must fail closed"
;;

let test_missing_team_id_is_typed_provenance_error () =
  let assert_missing team_id =
    let auth_test ~token:_ =
      Ok { Slack_rest_client.user_id = "U1"; team_id }
    in
    match
      G.resolve_authenticated_workspace ~auth_test ~bot_token:(Some "xoxb-test")
    with
    | Error (G.Workspace_provenance_missing { bot_user_id = "U1" }) -> ()
    | Error _ -> fail "expected Workspace_provenance_missing"
    | Ok _ -> fail "auth.test without a usable team_id must fail closed"
  in
  assert_missing None;
  assert_missing (Some "   ")
;;

let test_authenticated_workspace_requires_team_id () =
  let auth_test ~token:_ =
    Ok { Slack_rest_client.user_id = "U1"; team_id = Some " T1 " }
  in
  match
    G.resolve_authenticated_workspace ~auth_test ~bot_token:(Some "xoxb-test")
  with
  | Ok { G.bot_user_id; team_id } ->
    check string "bot user id" "U1" bot_user_id;
    check string "normalized team id" "T1" team_id
  | Error error ->
    failf "expected authenticated workspace: %s"
      (G.auth_workspace_error_to_string error)
;;

let test_startup_error_is_operator_visible () =
  with_env "SLACK_APP_TOKEN" "xapp-test" (fun () ->
    with_temp_base (fun () ->
      State.record_startup_error "invalid Slack trigger policy";
      Fun.protect
        ~finally:State.clear_startup_error
        (fun () ->
           let status = State.status_json () in
           check bool "not available despite app token" false
             Yojson.Safe.Util.(status |> member "available" |> to_bool);
           check bool "not connected" false
             Yojson.Safe.Util.(status |> member "connected" |> to_bool);
           check string "status uses connector vocabulary" "offline"
             Yojson.Safe.Util.(status |> member "status" |> to_string);
           check string "error" "invalid Slack trigger policy"
             Yojson.Safe.Util.(status |> member "error" |> to_string))))
;;

let () =
  run "server_slack_trigger_policy"
    [ ( "parse_trigger_policy"
      , [ test_case "with_env restores unset" `Quick test_with_env_restores_unset
        ; test_case "empty => default" `Quick test_empty_is_default
        ; test_case "whitespace => default" `Quick test_whitespace_is_default
        ; test_case "valid values parse through strict grammar" `Quick
            test_valid_values_parse_through
        ; test_case "unknown => default (no silent coercion)" `Quick
            test_unknown_falls_back_to_default
        ; test_case "user_only empty id => default" `Quick
            test_user_only_empty_id_falls_back
        ] )
    ; ( "runtime.toml loading"
      , [ test_case "missing file => typed missing" `Quick
            test_missing_runtime_toml_is_typed_missing
        ; test_case "dangling symlink => unreadable" `Quick
            test_dangling_runtime_toml_symlink_is_unreadable
        ; test_case "missing key => deliberate no-config" `Quick
            test_missing_key_is_deliberate_no_config
        ; test_case "malformed file => error" `Quick
            test_malformed_runtime_toml_is_error
        ; test_case "valid file => configured policy" `Quick
            test_valid_runtime_toml_loads_policy
        ; test_case "wrong field type => error" `Quick
            test_wrong_type_runtime_toml_is_error
        ; test_case "wrong Slack table type => error" `Quick
            test_wrong_type_slack_parent_is_error
        ; test_case "invalid policy value => error" `Quick
            test_invalid_runtime_toml_policy_is_error
        ; test_case "startup error => offline with error" `Quick
            test_startup_error_is_operator_visible
        ] )
    ; ( "workspace authentication"
      , [ test_case "missing bot token => typed error" `Quick
            test_missing_bot_token_is_typed_auth_error
        ; test_case "auth.test failure => typed error" `Quick
            test_auth_test_failure_is_typed_auth_error
        ; test_case "missing team_id => provenance error" `Quick
            test_missing_team_id_is_typed_provenance_error
        ; test_case "team_id => authenticated workspace" `Quick
            test_authenticated_workspace_requires_team_id
        ] )
    ]
