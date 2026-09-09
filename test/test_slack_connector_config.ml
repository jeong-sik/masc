open Alcotest
module Config = Server_slack_connector_config
module Env = Env_config_slack
module State = Channel_gate_slack_state

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:""))
    (fun () ->
       Unix.putenv name value;
       f ())
;;

let with_config contents f =
  let config_root = Filename.temp_file "slack-connector-config-" "" in
  Sys.remove config_root;
  Unix.mkdir config_root 0o700;
  let path = Filename.concat config_root "runtime.toml" in
  let previous = Env.connector_state () in
  Fun.protect
    ~finally:(fun () ->
      Env.configure_connector previous;
      if Sys.file_exists path then Sys.remove path;
      Unix.rmdir config_root)
    (fun () ->
       Option.iter
         (fun text ->
            let channel = open_out_bin path in
            Fun.protect
              ~finally:(fun () -> close_out channel)
              (fun () -> output_string channel text))
         contents;
       with_env "SLACK_APP_TOKEN" "xapp-test-disabled" (fun () ->
         with_env "SLACK_BOT_TOKEN" "xoxb-test-disabled" (fun () -> f ~config_root ~path)))
;;

let check_tokens expected =
  check bool "app token access" expected (Option.is_some (Env.app_token_opt ()));
  check bool "bot token access" expected (Option.is_some (Env.bot_token_opt ()))
;;

let test_default_enabled () =
  List.iter
    (fun contents ->
       with_config contents (fun ~config_root ~path:_ ->
         Config.configure ~config_root;
         check bool "enabled" true (Env.connector_state () = Env.Enabled);
         check_tokens true))
    [ None; Some "[slack]\npoll_enabled = false\n" ]
;;

let test_disabled_blocks_outbound () =
  with_config
    (Some "[slack]\nenabled = false\npoll_enabled = true\n")
    (fun ~config_root ~path:_ ->
       Config.configure ~config_root;
       check bool "disabled" true (Env.connector_state () = Env.Disabled);
       check_tokens false;
       (* These would attempt HTTP without the policy. No Eio runtime or HTTP
         mock is installed, so success proves rejection before the effect. *)
       (match State.send_message ~channel_id:"C_TEST" ~content:"test" () with
        | Error State.Missing_token -> ()
        | _ -> fail "disabled post must stop before REST");
       (match
          State.edit_message ~channel_id:"C_TEST" ~message_id:"1.0" ~content:"test" ()
        with
        | Error State.Missing_token -> ()
        | _ -> fail "disabled edit must stop before REST");
       check
         (option string)
         "operator reason"
         (Some "Slack connector disabled by [slack] enabled=false")
         (Env.unavailable_reason ());
       with_env
         "MASC_SLACK_BINDING_STORE_PATH"
         (Filename.concat config_root "bindings.json")
         (fun () ->
            with_env
              "MASC_SLACK_BINDING_AUDIT_PATH"
              (Filename.concat config_root "audit.jsonl")
              (fun () ->
                 let status = State.connector_json () in
                 let field key = Yojson.Safe.Util.member key status in
                 check
                   string
                   "existing offline status vocabulary"
                   "offline"
                   (Yojson.Safe.Util.to_string (field "status"));
                 check
                   bool
                   "unavailable"
                   false
                   (Yojson.Safe.Util.to_bool (field "available"));
                 check
                   string
                   "connector projection explains disable policy"
                   "Slack connector disabled by [slack] enabled=false"
                   (Yojson.Safe.Util.to_string (field "error")))))
;;

let test_true_restores_enabled () =
  with_config (Some "[slack]\nenabled = true\n") (fun ~config_root ~path:_ ->
    Env.configure_connector Env.Disabled;
    Config.configure ~config_root;
    check_tokens true;
    check (option string) "no config error" None (Env.unavailable_reason ()))
;;

let test_invalid_enabled () =
  List.iter
    (fun contents ->
       with_config (Some contents) (fun ~config_root ~path ->
         (match Config.load ~path with
          | Error (Config.Invalid_enabled _) -> ()
          | _ -> fail "present non-boolean must be a typed error");
         Config.configure ~config_root;
         check_tokens false;
         check
           (option string)
           "safe error detail"
           (Some ("slack.enabled must be a boolean in " ^ path))
           (Env.unavailable_reason ())))
    [ "[slack]\nenabled = \"xoxb-do-not-log\"\n"; "slack = \"not a table\"\n" ]
;;

let test_invalid_toml () =
  with_config (Some "[slack\nxoxb-do-not-log") (fun ~config_root ~path ->
    (match Config.load ~path with
     | Error (Config.Invalid_toml _) -> ()
     | _ -> fail "malformed TOML must be a typed error");
    Config.configure ~config_root;
    check_tokens false;
    check
      (option string)
      "parse error omits source contents"
      (Some ("Slack connector configuration is invalid TOML: " ^ path))
      (Env.unavailable_reason ()))
;;

let test_unreadable_target () =
  with_config None (fun ~config_root ~path ->
    (* A broken explicit symlink is not an absent optional configuration. *)
    Unix.symlink (Filename.concat config_root "missing-target") path;
    Fun.protect
      ~finally:(fun () -> Unix.unlink path)
      (fun () ->
         (match Config.load ~path with
          | Error (Config.Unreadable _) -> ()
          | _ -> fail "unreadable existing config must not enable connector");
         Config.configure ~config_root;
         check_tokens false))
;;

let () =
  run
    "slack connector configuration"
    [ ( "master switch"
      , [ test_case
            "missing policy preserves enabled behavior"
            `Quick
            test_default_enabled
        ; test_case
            "disabled suppresses tokens and outbound effects"
            `Quick
            test_disabled_blocks_outbound
        ; test_case "true restores enabled behavior" `Quick test_true_restores_enabled
        ; test_case "wrong type disables with safe error" `Quick test_invalid_enabled
        ; test_case "invalid TOML disables with safe error" `Quick test_invalid_toml
        ; test_case "unreadable target disables" `Quick test_unreadable_target
        ] )
    ]
;;
