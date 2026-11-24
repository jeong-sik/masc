open Alcotest
open Masc

let test_driver_profiles () =
  check int "four ACP drivers" 4 (List.length Runtime_acp_client.all_drivers);
  List.iter
    (fun driver ->
       let name = Runtime_acp_client.driver_to_string driver in
       match Runtime_acp_client.driver_of_string name with
       | Some roundtripped ->
         check bool ("roundtrip " ^ name) true
           (Runtime_acp_client.equal_driver driver roundtripped)
       | None -> failf "driver_of_string failed for %s" name)
    Runtime_acp_client.all_drivers;
  check bool "unknown driver rejected" true
    (Option.is_none (Runtime_acp_client.driver_of_string "unknown_acp_driver"));
  let agy = Runtime_acp_client.profile_of_driver Antigravity in
  check string "agy command" "agy" agy.default_command;
  check (list string) "agy args" [ "acp" ] agy.default_args;
  check bool "agy uses gemini dir MCP config" true
    (agy.mcp_wiring = Runtime_acp_client.Gemini_dir_mcp_config);
  check bool "agy uses _meta systemPrompt append" true
    (agy.system_prompt_channel = Runtime_acp_client.Meta_antigravity_append);
  check bool "agy input excludes cached" true
    (agy.input_accounting = Runtime_acp_client.Exclusive_of_cached);
  check bool "agy output includes thought" true
    (agy.output_accounting = Runtime_acp_client.Inclusive_of_thought);
  let kimi = Runtime_acp_client.profile_of_driver Kimi_code in
  check string "kimi command" "kimi" kimi.default_command;
  check bool "kimi supports --skills-dir" true kimi.supports_skills_dir_flag;
  check bool "kimi uses session/new HTTP MCP" true
    (kimi.mcp_wiring = Runtime_acp_client.Session_new_http_mcp);
  check bool "kimi MCP grammar locked to live-verified Mcp_double_underscore" true
    (kimi.mcp_identifier_syntaxes = [ Runtime_acp_client.Mcp_double_underscore ]);
  let vibe = Runtime_acp_client.profile_of_driver Mistral_vibe in
  check string "vibe command" "vibe-acp" vibe.default_command;
  check (list string) "vibe strips MISTRAL_API_KEY by default" [ "MISTRAL_API_KEY" ]
    vibe.default_strip_env;
  check bool "vibe uses session/new HTTP MCP" true
    (vibe.mcp_wiring = Runtime_acp_client.Session_new_http_mcp);
  check bool "vibe input includes cached" true
    (vibe.input_accounting = Runtime_acp_client.Inclusive_of_cached);
  check bool "vibe output includes thought" true
    (vibe.output_accounting = Runtime_acp_client.Inclusive_of_thought)
;;

let find_env key arr =
  let prefix = key ^ "=" in
  Array.to_list arr
  |> List.find_map (fun entry ->
       if String.starts_with ~prefix entry
       then Some (String.sub entry (String.length prefix) (String.length entry - String.length prefix))
       else None)
;;

let test_build_environment () =
  let base_env =
    [| "PATH=/usr/bin"
     ; "MISTRAL_API_KEY=exhausted-key"
     ; "AGY_CLI_DISABLE_AUTO_UPDATE=false"
     ; "EXTRA_SECRET=drop-me"
    |]
  in
  let vibe_env =
    Runtime_acp_client.For_testing.build_environment
      ~base_env
      ~driver:Mistral_vibe
      ~extra_strip_env:[ "EXTRA_SECRET" ]
  in
  check (option string) "vibe strips MISTRAL_API_KEY" None
    (find_env "MISTRAL_API_KEY" vibe_env);
  check (option string) "vibe strips extra env" None
    (find_env "EXTRA_SECRET" vibe_env);
  check (option string) "vibe preserves PATH" (Some "/usr/bin")
    (find_env "PATH" vibe_env);
  let agy_env =
    Runtime_acp_client.For_testing.build_environment
      ~base_env
      ~driver:Antigravity
      ~extra_strip_env:[]
  in
  check (option string) "agy disables auto update" (Some "true")
    (find_env "AGY_CLI_DISABLE_AUTO_UPDATE" agy_env);
  let kimi_env =
    Runtime_acp_client.For_testing.build_environment
      ~base_env
      ~driver:Kimi_code
      ~extra_strip_env:[ "EXTRA_SECRET" ]
  in
  check (option string) "kimi strips extra env" None
    (find_env "EXTRA_SECRET" kimi_env);
  check (option string) "kimi preserves PATH" (Some "/usr/bin")
    (find_env "PATH" kimi_env)
;;

let test_parse_wire_updates_and_usage () =
  let text_ev =
    `Assoc
      [ "sessionUpdate", `String "agent_message_chunk"
      ; "content", `Assoc [ "type", `String "text"; "text", `String "hello" ]
      ]
    |> Runtime_acp_client.For_testing.parse_session_update ~driver:Antigravity
  in
  check bool "text delta parsed" true (text_ev = Some (Runtime_acp_client.Text_delta "hello"));
  let thought_ev =
    `Assoc
      [ "sessionUpdate", `String "agent_thought_chunk"
      ; "content", `Assoc [ "type", `String "text"; "text", `String "pondering" ]
      ]
    |> Runtime_acp_client.For_testing.parse_session_update ~driver:Antigravity
  in
  check bool "thought delta parsed" true
    (thought_ev = Some (Runtime_acp_client.Thought_delta "pondering"));
  let usage_ev =
    `Assoc
      [ "sessionUpdate", `String "usage_update"
      ; "used", `Int 11651
      ; "size", `Int 1048576
      ]
    |> Runtime_acp_client.For_testing.parse_session_update ~driver:Antigravity
  in
  (match usage_ev with
   | Some (Runtime_acp_client.Usage_updated { used = Some 11651; size = Some 1048576; _ }) -> ()
   | _ -> fail "expected Usage_updated with used=11651 size=1048576");
  let mode_ev =
    `Assoc
      [ "sessionUpdate", `String "current_mode_update"
      ; "currentModeId", `String "auto-approve"
      ]
    |> Runtime_acp_client.For_testing.parse_session_update ~driver:Antigravity
  in
  check bool "mode update parsed" true
    (mode_ev = Some (Runtime_acp_client.Mode_updated "auto-approve"));
  let usage =
    `Assoc
      [ "usage", `Assoc
          [ "inputTokens", `Int 15716
          ; "outputTokens", `Int 542
          ; "cachedReadTokens", `Int 17945
          ; "cachedWriteTokens", `Int 0
          ; "thoughtTokens", `Int 405
          ; "totalTokens", `Int 34203
          ]
      ]
    |> Runtime_acp_client.For_testing.parse_prompt_usage
  in
  check int "input_tokens" 15716 usage.input_tokens;
  check int "output_tokens" 542 usage.output_tokens;
  check int "cached_read_tokens" 17945 usage.cached_read_tokens;
  check int "thought_tokens" 405 usage.thought_tokens;
  check int "total_tokens" 34203 usage.total_tokens
;;

(* Pinned directly to live PR #54358 wire payloads for Antigravity and Mistral Vibe. *)
let test_driver_aware_usage_normalization () =
  let vibe_wire : Runtime_acp_client.usage =
    { input_tokens = 26920
    ; output_tokens = 166
    ; cached_read_tokens = 26112
    ; cached_write_tokens = 0
    ; thought_tokens = 0
    ; total_tokens = 27086
    ; context_used = Some 9322
    ; context_size = Some 400000
    }
  in
  let vibe_api =
    Keeper_acp_runtime.For_testing.api_usage_of_acp_usage ~driver:Mistral_vibe vibe_wire
  in
  check int "vibe input_tokens does not double-count cached_read_tokens" 26920
    vibe_api.input_tokens;
  check int "vibe output_tokens" 166 vibe_api.output_tokens;
  check int "vibe cache_read_input_tokens" 26112 vibe_api.cache_read_input_tokens;
  let agy_wire : Runtime_acp_client.usage =
    { input_tokens = 12929
    ; output_tokens = 401
    ; cached_read_tokens = 8558
    ; cached_write_tokens = 0
    ; thought_tokens = 273
    ; total_tokens = 21888
    ; context_used = Some 11093
    ; context_size = Some 1048576
    }
  in
  let agy_api =
    Keeper_acp_runtime.For_testing.api_usage_of_acp_usage ~driver:Antigravity agy_wire
  in
  check int "agy input_tokens adds exclusive input + cached_read" (12929 + 8558)
    agy_api.input_tokens;
  check int "agy output_tokens does not double-count thought_tokens" 401
    agy_api.output_tokens;
  check int "agy cache_read_input_tokens" 8558 agy_api.cache_read_input_tokens
;;

let test_stop_reason_mapping () =
  let map = Keeper_acp_runtime.For_testing.stop_reason_of_acp_stop_reason in
  check bool "End_turn -> EndTurn" true (map End_turn = Agent_core.Types.EndTurn);
  check bool "Max_tokens -> MaxTokens" true (map Max_tokens = Agent_core.Types.MaxTokens);
  check bool "Refusal -> Refusal" true (map Refusal = Agent_core.Types.Refusal);
  check bool "Max_turn_requests -> PauseTurn" true
    (map Max_turn_requests = Agent_core.Types.PauseTurn);
  check bool "Cancelled -> PauseTurn" true (map Cancelled = Agent_core.Types.PauseTurn);
  check bool "Other -> PauseTurn" true
    (map (Other_stop_reason "custom") = Agent_core.Types.PauseTurn)
;;

let test_compaction_detection () =
  check bool "any strict drop in append-only context detects compaction" true
    (Keeper_acp_runtime.For_testing.compaction_detected
       ~prev_used:(Some 10000) ~cur_used:(Some 9500));
  check bool "large context drop detects compaction" true
    (Keeper_acp_runtime.For_testing.compaction_detected
       ~prev_used:(Some 60000) ~cur_used:(Some 15000));
  check bool "equal context is not compaction" false
    (Keeper_acp_runtime.For_testing.compaction_detected
       ~prev_used:(Some 15000) ~cur_used:(Some 15000));
  check bool "monotonic context growth is not compaction" false
    (Keeper_acp_runtime.For_testing.compaction_detected
       ~prev_used:(Some 15000) ~cur_used:(Some 22000));
  check bool "missing baseline is not compaction" false
    (Keeper_acp_runtime.For_testing.compaction_detected
       ~prev_used:None ~cur_used:(Some 15000))
;;

let test_toml_materialization_all_three_drivers () =
  let source =
    {|
[providers.agy_test]
protocol = "acp"
driver = "antigravity"
command = "agy"
args = ["acp"]
is-non-interactive = true
timeout-s = 120.0

[providers.kimi_test]
protocol = "acp"
driver = "kimi_code"
command = "kimi"
args = ["acp"]
is-non-interactive = true
timeout-s = 120.0

[providers.vibe_test]
protocol = "acp"
driver = "mistral_vibe"
command = "vibe-acp"
strip-env = ["MISTRAL_API_KEY"]
mode = "auto-approve"
is-non-interactive = true
timeout-s = 120.0

[models.m_agy]
api-name = "gemini-4-neon-high"
max-context = 1048576

[models.m_kimi]
api-name = "kimi-code/k3.1-pro"
max-context = 1048576

[models.m_vibe]
api-name = "mistral-medium-3.5"
max-context = 262144

[agy_test.m_agy]
[kimi_test.m_kimi]
[vibe_test.m_vibe]

[runtime]
default = "agy_test.m_agy"
|}
  in
  let cfg =
    match Runtime_toml.parse_string source with
    | Ok cfg -> cfg
    | Error errs ->
      failf "parse failed: %s"
        (String.concat "; "
           (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs))
  in
  let runtimes, dropped = Runtime_instance.partition_bindings cfg cfg.bindings in
  check int "zero dropped ACP bindings" 0 (List.length dropped);
  check int "three materialized ACP runtimes" 3 (List.length runtimes);
  let find_acp id =
    match List.find_opt (fun (rt : Runtime_instance.t) -> String.equal rt.id id) runtimes with
    | Some { execution = Runtime_execution.Acp exec; _ } -> exec
    | Some _ -> failf "%s did not materialize as Runtime_execution.Acp" id
    | None -> failf "missing materialized runtime %s" id
  in
  let agy = find_acp "agy_test.m_agy" in
  check bool "agy driver" true (Runtime_acp_client.equal_driver Antigravity agy.driver);
  let kimi = find_acp "kimi_test.m_kimi" in
  check bool "kimi driver" true (Runtime_acp_client.equal_driver Kimi_code kimi.driver);
  let vibe = find_acp "vibe_test.m_vibe" in
  check bool "vibe driver" true (Runtime_acp_client.equal_driver Mistral_vibe vibe.driver);
  check (list string) "vibe strip_env" [ "MISTRAL_API_KEY" ] vibe.strip_env;
  check (option string) "vibe mode" (Some "auto-approve") vibe.mode
;;

(* ── Muse Code (muse acp 1.4.25, live-verified 2026-11-24) ────────────────── *)

let muse_observer_flags =
  List.concat_map
    (fun name ->
       [ "-c"
       ; Printf.sprintf "runtime_capabilities.plugin:tbh-reminders:reminder:%s.enabled=false" name
       ])
    [ "memory"
    ; "skill-reminder"
    ; "verify-reminder"
    ; "goal-reminder"
    ; "todo-reminder"
    ; "scope-reminder"
    ]
;;

let acp_execution_of_driver driver =
  let config : Runtime_execution.acp_client =
    { driver
    ; cli_path = "cli"
    ; args = []
    ; strip_env = []
    ; skills_dirs = []
    ; model = Runtime_acp_client.keep_cli_default
    ; effort = None
    ; mode = None
    ; oauth_source = None
    ; timeout_s = 1.
    }
  in
  Runtime_execution.Acp config
;;

let test_muse_profile_and_native_none () =
  let muse = Runtime_acp_client.profile_of_driver Runtime_acp_client.Muse_code in
  check string "muse command" "muse" muse.default_command;
  check (list string) "muse default args" [ "acp" ] muse.default_args;
  check bool "muse uses session/new HTTP MCP" true
    (muse.mcp_wiring = Runtime_acp_client.Session_new_http_mcp);
  check bool "muse MCP grammar locked to live-verified Mcp_double_underscore" true
    (muse.mcp_identifier_syntaxes = [ Runtime_acp_client.Mcp_double_underscore ]);
  check (list (pair string string)) "muse pins the launcher update check off"
    [ "MUSE_NO_AUTO_UPDATE", "1" ] muse.env_set;
  check (list string) "muse pins onRequest under none and read, allowAll under full"
    [ "onRequest"; "onRequest"; "allowAll" ]
    [ muse.mode_for_native_none; muse.mode_for_native_read; muse.mode_for_native_full ];
  check (option string) "muse has no effort config option" None muse.effort_config_id;
  List.iter
    (fun driver ->
       let name = Runtime_acp_client.driver_to_string driver in
       let enforces = (Runtime_acp_client.profile_of_driver driver).enforces_native_none in
       check bool (name ^ " native-none enforcement")
         (not (Runtime_acp_client.equal_driver driver Runtime_acp_client.Muse_code))
         enforces;
       check bool (name ^ " execution agrees with its profile") enforces
         (Runtime_execution.supports_native_none (acp_execution_of_driver driver)))
    Runtime_acp_client.all_drivers;
  check bool "muse none runs at the read floor" true
    (Runtime_native_tools.degrade_on_admission
       ~posture:Runtime_native_tools.Native_none
       ~none_supported:
         (Runtime_execution.supports_native_none
            (acp_execution_of_driver Runtime_acp_client.Muse_code))
       ()
     = Runtime_native_tools.Native_read)
;;

let test_muse_refuses_unsupported_config_before_spawn () =
  let cwd = Filename.temp_dir "masc-muse-native-none-" "" in
  Fun.protect ~finally:(fun () -> Unix.rmdir cwd) (fun () ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let proc_mgr = Runtime_acp_client.foreground_process_mgr ~clock () in
        let config =
          { (Runtime_acp_client.default_config ~driver:Muse_code ~cwd) with
            cli_path = Filename.concat cwd "missing-executable"
          }
        in
        let error =
          testable
            (fun fmt e -> Format.pp_print_string fmt (Runtime_acp_client.error_to_string e))
            ( = )
        in
        let start ~config ~native_posture =
          Runtime_acp_client.start ~sw ~proc_mgr ~clock ~fs:(Eio.Stdenv.fs env) ~config
            ~native_posture () |> Result.map Runtime_acp_client.close
        in
        check
          (result unit error)
          "refuses native none before attempting to spawn the missing executable"
          (Error (Runtime_acp_client.Invalid_config
                    "ACP driver muse_code cannot enforce the native tool posture 'none'"))
          (start ~config ~native_posture:Runtime_native_tools.Native_none);
        check
          (result unit error)
          "rejects an explicit credential file before falling back to host sign-in"
          (Error (Runtime_acp_client.Invalid_config
                    "ACP driver muse_code requires host sign-in with the credential file binding unset"))
          (start ~config:{ config with oauth_source = Some (Filename.concat cwd "missing-credential") }
             ~native_posture:Runtime_native_tools.Native_read))))
;;

let test_muse_argv_and_environment () =
  let cfg = Runtime_acp_client.default_config ~driver:Runtime_acp_client.Muse_code ~cwd:"/tmp" in
  check (list string) "default argv trusts the workspace and turns every observer off"
    ([ "muse"; "acp"; "--trust-workspace" ] @ muse_observer_flags)
    (Runtime_acp_client.For_testing.build_argv cfg ~temp_gemini_dir:None);
  let effort_cfg = { cfg with args = [ "acp"; "-c"; "reasoning_effort=\"low\"" ] } in
  check (list string) "operator args replace the defaults and keep the required flags"
    ([ "muse"; "acp"; "-c"; "reasoning_effort=\"low\""; "--trust-workspace" ]
     @ muse_observer_flags)
    (Runtime_acp_client.For_testing.build_argv effort_cfg ~temp_gemini_dir:None);
  let env =
    Runtime_acp_client.For_testing.build_environment
      ~base_env:[| "PATH=/usr/bin"; "MUSE_NO_AUTO_UPDATE=0"; "META_API_KEY=key" |]
      ~driver:Runtime_acp_client.Muse_code
      ~extra_strip_env:[ "META_API_KEY" ]
  in
  check (option string) "update check stays off over an inherited value" (Some "1")
    (find_env "MUSE_NO_AUTO_UPDATE" env);
  check (option string) "operator strip-env drops the key" None (find_env "META_API_KEY" env);
  check (option string) "PATH is kept" (Some "/usr/bin") (find_env "PATH" env)
;;

let test_muse_permission_grammar () =
  let allowed_tool_names = [ "masc_probe_ping"; "keeper_skill" ] in
  let mcp_only =
    Runtime_acp_client.Allow_masc_mcp_only { mcp_server_name = "masc"; allowed_tool_names }
  in
  let read_and_mcp =
    Runtime_acp_client.Allow_read_and_masc_mcp { mcp_server_name = "masc"; allowed_tool_names }
  in
  let classify =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Runtime_acp_client.Muse_code
      ~mcp_server_name:"masc"
  in
  (* Shape recorded from muse acp 1.4.25: an MCP call is title = name =
     mcp__<server>__<tool> with kind other; a native read is read_file with
     kind read. *)
  let frame ~title ~kind =
    `Assoc
      [ "toolCallId", `String "recorded-1"
      ; "title", `String title
      ; "name", `String title
      ; "kind", `String kind
      ; "status", `String "pending"
      ]
  in
  let allowed policy wire = Runtime_acp_client.should_allow_tool_call ~policy (classify wire) in
  check bool "masc tool allowed under mcp-only" true
    (allowed mcp_only (frame ~title:"mcp__masc__masc_probe_ping" ~kind:"other"));
  check bool "masc tool allowed under read-and-mcp" true
    (allowed read_and_mcp (frame ~title:"mcp__masc__keeper_skill" ~kind:"other"));
  check bool "foreign MCP server denied" false
    (allowed read_and_mcp (frame ~title:"mcp__foreign-srv__masc_probe_ping" ~kind:"other"));
  check bool "native read denied under mcp-only" false
    (allowed mcp_only (frame ~title:"read_file" ~kind:"read"));
  check bool "native read allowed under read-and-mcp" true
    (allowed read_and_mcp (frame ~title:"read_file" ~kind:"read"));
  check bool "native write denied under read-and-mcp" false
    (allowed read_and_mcp (frame ~title:"write_file" ~kind:"edit"));
  check bool "native shell denied under read-and-mcp" false
    (allowed read_and_mcp (frame ~title:"shell" ~kind:"execute"));
  List.iter
    (fun title ->
       check bool ("another driver's grammar " ^ title ^ " is rejected") false
         (Runtime_acp_client.For_testing.should_allow_permission
            ~driver:Runtime_acp_client.Muse_code
            ~policy:mcp_only
            ~title
            ~kind:(Some Runtime_acp_client.Tool_other)))
    [ "mcp(masc/keeper_skill)"
    ; "mcp_masc.masc_probe_ping"
    ; "mcp_masc_masc_probe_ping"
    ; "masc_masc_probe_ping"
    ]
;;

let test_muse_toml_row_and_effort () =
  let source =
    {|
[providers.muse_test]
protocol = "acp"
driver = "muse_code"
command = "muse"
args = ["acp", "-c", "reasoning_effort=\"low\""]
is-non-interactive = true
timeout-s = 120.0

[models.m_muse]
api-name = "muse-ember-1.0"
max-context = 1007997

[muse_test.m_muse]

[runtime]
default = "muse_test.m_muse"
|}
  in
  let cfg =
    match Runtime_toml.parse_string source with
    | Ok cfg -> cfg
    | Error errs ->
      failf "muse_code row failed to parse: %s"
        (String.concat "; "
           (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs))
  in
  let runtimes, dropped = Runtime_instance.partition_bindings cfg cfg.bindings in
  check int "zero dropped" 0 (List.length dropped);
  (match runtimes with
   | [ ({ execution = Runtime_execution.Acp exec; _ } as runtime) ] ->
     check bool "muse driver" true
       (Runtime_acp_client.equal_driver Runtime_acp_client.Muse_code exec.driver);
     check (list string) "operator args are kept as written"
       [ "acp"; "-c"; "reasoning_effort=\"low\"" ] exec.args;
     check (option string) "model id" (Some "muse-ember-1.0")
       (Runtime_execution.model_id (Runtime_execution.Acp exec));
     check bool "quota is scoped per ACP driver" true
       (Runtime_quota_window.scope_equal
          (Runtime_instance.quota_scope_of_runtime runtime)
          (Runtime_quota_window.scope_of_acp_driver ~driver:"muse_code"))
   | _ -> fail "expected a single materialized muse_code runtime");
  let with_effort =
    {|
[providers.muse_eff]
protocol = "acp"
driver = "muse_code"
command = "muse"
is-non-interactive = true
effort = "low"
[models.m]
api-name = "m"
max-context = 1000
[muse_eff.m]
[runtime]
default = "muse_eff.m"
|}
  in
  match Runtime_toml.parse_string with_effort with
  | Error (err :: _) ->
    check string "error path identifies the effort key" "providers.muse_eff.effort" err.path
  | Error [] -> fail "expected a non-empty error list for muse_code effort"
  | Ok _ -> fail "muse_code has no effort option, so effort must be refused at parse time"
;;

let test_muse_binding_effort_admission () =
  let parse ~driver ~model_fields ~binding_model ~binding_fields =
    Runtime_toml.parse_string
      (Printf.sprintf
         {|[providers.p]
protocol = "acp"
driver = "%s"
command = "cli"
is-non-interactive = true
args = ["acp", "-c", "reasoning_effort=\"low\""]
[models.m]
api-name = "m"
max-context = 1000
%s
[p.%s]
%s
[runtime]
default = "p.%s"
|} driver model_fields binding_model binding_fields binding_model)
  in
  let rejects label model_fields binding_model binding_fields key =
    match parse ~driver:"muse_code" ~model_fields ~binding_model ~binding_fields with
    | Error [ e ] -> check string label key e.path
    | Error _ -> fail (label ^ ": expected one binding diagnostic")
    | Ok _ -> fail (label ^ ": unsupported session effort was accepted")
  in
  rejects "model effort" {|reasoning-effort = "high"|} "m" "" "p.m";
  rejects "binding effort" "" "m" {|effort = "none"|} "p.m";
  rejects "expanded model effort" {|efforts = ["low"]|} "m-low" "" "p.m-low";
  rejects "expanded binding effort" {|efforts = ["low"]|} "m" {|efforts = ["low"]|} "p.m-low";
  check bool "Muse accepts its process effort without a session override" true
    (Result.is_ok (parse ~driver:"muse_code" ~model_fields:"" ~binding_model:"m" ~binding_fields:""));
  check bool "a driver with session effort accepts the same model declaration" true
    (Result.is_ok (parse ~driver:"kimi_code" ~model_fields:{|reasoning-effort = "high"|}
       ~binding_model:"m" ~binding_fields:""))
;;

let test_muse_turn_effort_refused_before_session_rpc () =
  let cwd = Filename.temp_dir "muse-effort-rpc-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree cwd) (fun () ->
    let script = Filename.concat cwd "host.py" and trace = Filename.concat cwd "methods" in
    Out_channel.with_open_text script (fun oc -> output_string oc
      {|import json, sys
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    with open(sys.argv[1], "a") as trace:
        trace.write(method + "\n")
    if "id" in request:
        result = ({"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}
                  if method == "initialize" else {"sessionId": "muse-1", "configOptions": []})
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
|});
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let clock = Eio.Stdenv.clock env in
    let proc_mgr = Runtime_acp_client.foreground_process_mgr ~clock () in
    let config = { (Runtime_acp_client.default_config ~driver:Muse_code ~cwd) with
                   cli_path = "python3"; args = [script; trace] } in
    let unwrap = function
      | Ok value -> value
      | Error err -> fail (Runtime_acp_client.error_to_string err) in
    let client = Runtime_acp_client.start ~sw ~proc_mgr ~clock ~fs:(Eio.Stdenv.fs env)
        ~config ~native_posture:Runtime_native_tools.Native_read () |> unwrap in
    Fun.protect ~finally:(fun () -> Runtime_acp_client.close client) (fun () ->
      let session = Runtime_acp_client.new_session client ~cwd () |> unwrap in
      let methods () = In_channel.with_open_text trace In_channel.input_lines in
      let before = methods () in
      let effort = Llm_provider.Reasoning_effort.High in
      let refusal = match Runtime_acp_client.validate_session_effort ~driver:Muse_code (Some effort) with
        | Error detail -> Runtime_acp_client.Invalid_config detail
        | Ok () -> fail "Muse must reject the session effort" in
      let refused label = function
        | Error err -> check bool (label ^ " returned the configuration refusal") true (err = refusal)
        | Ok _ -> fail (label ^ " accepted an unsupported turn effort") in
      refused "new" (Runtime_acp_client.new_session client ~cwd ~effort ());
      refused "resume" (Runtime_acp_client.resume_session client ~session_id:session.session_id ~cwd ~effort ());
      refused "load" (Runtime_acp_client.load_session client ~session_id:session.session_id ~cwd ~effort ());
      refused "reuse" (Runtime_acp_client.reconfigure_session client session ~effort ());
      check (list string) "rejected efforts issued no session RPC" before (methods ())))
;;

let test_unknown_driver_rejected () =
  let bad =
    {|
[providers.bad_acp]
protocol = "acp"
driver = "nonexistent"
command = "foo"
is-non-interactive = true
[models.m]
api-name = "m"
max-context = 1000
[bad_acp.m]
[runtime]
default = "bad_acp.m"
|}
  in
  match Runtime_toml.parse_string bad with
  | Error _ -> ()
  | Ok _ -> fail "unknown ACP driver must be rejected at parse time"
;;

let test_typed_acp_effort_and_model_selection_toml () =
  let valid_toml =
    {|
[providers.agy_eff]
protocol = "acp"
driver = "antigravity"
command = "agy"
is-non-interactive = true
effort = "ultra"
[models.def]
api-name = "default"
max-context = 1000
[agy_eff.def]
[runtime]
default = "agy_eff.def"
|}
  in
  (match Runtime_toml.parse_string valid_toml with
   | Error errs ->
     failf "valid ACP effort/default model TOML failed: %s"
       (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs))
   | Ok cfg ->
     let runtimes, dropped = Runtime_instance.partition_bindings cfg cfg.bindings in
     check int "zero dropped" 0 (List.length dropped);
     match runtimes with
     | [ { execution = Runtime_execution.Acp exec; _ } ] ->
       check bool "default model parsed as Keep_cli_default" true
         (Runtime_acp_client.equal_model_selection
            Runtime_acp_client.keep_cli_default
            exec.model);
       check bool "case-insensitive trimmed default normalizes to Keep_cli_default" true
         (Runtime_acp_client.equal_model_selection
            Runtime_acp_client.keep_cli_default
            (Runtime_acp_client.model_selection_of_string "  DEFAULT "));
       check bool "ultra effort parsed as Reasoning_effort.Ultra" true
         (Option.equal Llm_provider.Reasoning_effort.equal
            (Some Llm_provider.Reasoning_effort.Ultra)
            exec.effort);
       check (option string) "Runtime_execution.model_id returns None for Keep_cli_default" None
         (Runtime_execution.model_id (Runtime_execution.Acp exec))
     | _ -> fail "expected single materialized ACP runtime");
  let invalid_effort =
    {|
[providers.bad_eff]
protocol = "acp"
driver = "antigravity"
command = "agy"
is-non-interactive = true
effort = "turbo"
[models.m]
api-name = "m"
max-context = 1000
[bad_eff.m]
[runtime]
default = "bad_eff.m"
|}
  in
  (match Runtime_toml.parse_string invalid_effort with
   | Error (err :: _) ->
     check string "error path identifies effort key" "providers.bad_eff.effort" err.path
   | Error [] -> fail "expected non-empty error list for invalid ACP effort"
   | Ok _ -> fail "unknown ACP effort must be rejected strictly at TOML parse time");
  (* Option A': driver-scoped effort alias SSOT — mistral_vibe accepts "off" -> None_,
     kimi_code rejects "off", and unknown values such as "auto" stay fail-closed. *)
  let vibe_off =
    {|
[providers.vibe_off]
protocol = "acp"
driver = "mistral_vibe"
command = "vibe-acp"
is-non-interactive = true
effort = "off"
[models.m]
api-name = "m"
max-context = 1000
[vibe_off.m]
[runtime]
default = "vibe_off.m"
|}
  in
  (match Runtime_toml.parse_string vibe_off with
   | Error errs ->
     failf "mistral_vibe effort=\"off\" must succeed, got: %s"
       (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs))
   | Ok cfg ->
     let runtimes, dropped = Runtime_instance.partition_bindings cfg cfg.bindings in
     check int "zero dropped for mistral_vibe effort=\"off\"" 0 (List.length dropped);
     (match runtimes with
      | [ { execution = Runtime_execution.Acp exec; _ } ] ->
        check bool "mistral_vibe effort=\"off\" normalizes to Some None_" true
          (Option.equal
             Llm_provider.Reasoning_effort.equal
             (Some Llm_provider.Reasoning_effort.None_)
             exec.effort)
      | _ -> fail "expected single materialized mistral_vibe runtime"));
  let kimi_off =
    {|
[providers.kimi_off]
protocol = "acp"
driver = "kimi_code"
command = "kimi"
is-non-interactive = true
effort = "off"
[models.m]
api-name = "m"
max-context = 1000
[kimi_off.m]
[runtime]
default = "kimi_off.m"
|}
  in
  (match Runtime_toml.parse_string kimi_off with
   | Error (err :: _) ->
     check string "kimi_code effort=\"off\" reports effort path" "providers.kimi_off.effort" err.path;
     check string "kimi_code effort error excludes mistral_vibe-only off alias"
       (Printf.sprintf "effort must be one of %s; got \"off\"" Llm_provider.Reasoning_effort.values_for_log)
       err.message
   | Error [] -> fail "expected error list for kimi_code effort=\"off\""
   | Ok _ -> fail "kimi_code must reject mistral_vibe-only effort=\"off\" alias");
  let vibe_auto =
    {|
[providers.vibe_auto]
protocol = "acp"
driver = "mistral_vibe"
command = "vibe-acp"
is-non-interactive = true
effort = "auto"
[models.m]
api-name = "m"
max-context = 1000
[vibe_auto.m]
[runtime]
default = "vibe_auto.m"
|}
  in
  (match Runtime_toml.parse_string vibe_auto with
   | Error (err :: _) ->
     check string "mistral_vibe effort=\"auto\" reports effort path" "providers.vibe_auto.effort" err.path;
     check string "mistral_vibe effort error advertises off alias"
       (Printf.sprintf "effort must be one of %s/off; got \"auto\"" Llm_provider.Reasoning_effort.values_for_log)
       err.message
   | Error [] -> fail "expected error list for mistral_vibe effort=\"auto\""
   | Ok _ -> fail "unknown effort=\"auto\" must remain fail-closed");
  (* Unified ACP effort precedence SSOT: turn > binding/model > provider *)
  let check_effort label expected actual =
    check bool label true
      (Option.equal Llm_provider.Reasoning_effort.equal expected actual)
  in
  let module E = Llm_provider.Reasoning_effort in
  check_effort "turn_effort wins over model_effort and provider_effort"
    (Some E.Max)
    (Runtime_acp_client.resolve_effective_effort
       ~turn_effort:E.Max ~model_effort:E.High ~provider_effort:E.Low ());
  check_effort "model_effort wins over provider_effort"
    (Some E.High)
    (Runtime_acp_client.resolve_effective_effort
       ~model_effort:E.High ~provider_effort:E.Low ());
  check_effort "provider_effort applies when turn and model unset"
    (Some E.Low)
    (Runtime_acp_client.resolve_effective_effort
       ~provider_effort:E.Low ());
  check_effort "all unset resolves to None"
    None
    (Runtime_acp_client.resolve_effective_effort ());
  (* End-to-end TOML binding > model > provider precedence check *)
  let layered_toml =
    {|
[providers.kimi_prov]
protocol = "acp"
driver = "kimi_code"
command = "kimi"
is-non-interactive = true
effort = "low"
[models.m_high]
api-name = "kimi-code/k3"
max-context = 100000
reasoning-effort = "high"
[kimi_prov.m_high]
effort = "max"
[runtime]
default = "kimi_prov.m_high"
|}
  in
  match Runtime_toml.parse_string layered_toml with
  | Error errs ->
    failf "layered ACP effort TOML failed: %s"
      (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errs))
  | Ok cfg ->
    let runtimes, dropped = Runtime_instance.partition_bindings cfg cfg.bindings in
    check int "zero dropped for layered ACP effort TOML" 0 (List.length dropped);
    (match runtimes with
     | [ ({ execution = Runtime_execution.Acp exec; _ } as rt) ] ->
       check_effort "provider default stays Low" (Some E.Low) exec.effort;
       check_effort "binding effort overrides model reasoning_effort" (Some E.Max) rt.model.reasoning_effort;
       check_effort "SSOT resolver picks binding/model over provider default"
         (Some E.Max)
         (Runtime_acp_client.resolve_effective_effort
            ?model_effort:rt.model.reasoning_effort
            ?provider_effort:exec.effort
            ())
     | _ -> fail "expected single materialized kimi_prov runtime")
;;

let test_build_argv_and_strict_permission_posture () =
  let tmp_skills = Filename.get_temp_dir_name () in
  let kimi_cfg =
    { (Runtime_acp_client.default_config ~driver:Kimi_code ~cwd:tmp_skills) with
      skills_dirs = [ tmp_skills ]
    }
  in
  let kimi_argv =
    Runtime_acp_client.For_testing.build_argv kimi_cfg ~temp_gemini_dir:None
  in
  check (list string) "kimi places --skills-dir before acp subcommand"
    [ "kimi"; "--skills-dir"; tmp_skills; "acp" ]
    kimi_argv;
  let agy_cfg =
    { (Runtime_acp_client.default_config ~driver:Antigravity ~cwd:tmp_skills) with
      dangerously_skip_permissions = true
    }
  in
  let agy_argv =
    Runtime_acp_client.For_testing.build_argv agy_cfg ~temp_gemini_dir:(Some "/tmp/g")
  in
  check (list string) "agy places --gemini-dir and skip flag after acp"
    [ "agy"; "acp"; "--gemini-dir"; "/tmp/g"; "--dangerously-skip-permissions" ]
    agy_argv;
  let allowed_tool_names = [ "masc_probe_ping"; "keeper_skill" ] in
  let mcp_only =
    Runtime_acp_client.Allow_masc_mcp_only
      { mcp_server_name = "masc"; allowed_tool_names }
  in
  let read_and_mcp =
    Runtime_acp_client.Allow_read_and_masc_mcp
      { mcp_server_name = "masc"; allowed_tool_names }
  in
  let allow = Runtime_acp_client.For_testing.should_allow_permission in
  (* Driver-scoped explicit-server positive MASC MCP identities *)
  List.iter
    (fun (driver, title, kind) ->
       check bool ("allows pinned MASC MCP tool " ^ title) true
         (allow ~driver ~policy:mcp_only ~title ~kind))
    [ Runtime_acp_client.Kimi_code, "mcp__masc__keeper_skill", None
    ; Runtime_acp_client.Kimi_code, "mcp__masc__masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Mistral_vibe, "mcp_masc.masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Mistral_vibe, "masc_masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Antigravity, "mcp_masc_masc_probe_ping", Some Runtime_acp_client.Tool_other
    ];
  (* Unqualified Tool_vendor_mcp fails closed without Single_pinned_server proof
     and succeeds ONLY when Single_pinned_server isolation is proven. *)
  List.iter
    (fun tool_name ->
       check bool ("unqualified Tool_vendor_mcp " ^ tool_name ^ " fails closed without isolation proof")
         false
         (allow ~driver:Antigravity ~policy:mcp_only ~title:tool_name ~kind:(Some Tool_vendor_mcp));
       let id =
         Runtime_acp_client.For_testing.classify_tool_call_json
           ~driver:Antigravity
           ~mcp_server_name:"masc"
           (`Assoc [ "title", `String tool_name; "kind", `String "mcp" ])
       in
       check bool ("unqualified Tool_vendor_mcp " ^ tool_name ^ " allowed under Single_pinned_server")
         true
         (Runtime_acp_client.should_allow_tool_call
            ~server_isolation:(Runtime_acp_client.Single_pinned_server "masc")
            ~policy:mcp_only
            id))
    [ "keeper_skill"; "masc_probe_ping" ];
  (* Dotted tool name under Antigravity Mcp_underscore_prefix must NOT be shadowed by Vibe Mcp_dot_prefix *)
  let dotted_policy =
    Runtime_acp_client.Allow_masc_mcp_only
      { mcp_server_name = "masc"; allowed_tool_names = [ "v1.status" ] }
  in
  check bool "Antigravity mcp_masc_v1.status is not shadowed by Mcp_dot_prefix" true
    (allow ~driver:Antigravity ~policy:dotted_policy ~title:"mcp_masc_v1.status" ~kind:(Some Tool_other));
  (* URLs and non-Kimi syntaxes are NEVER misparsed as MCP tools under Kimi_code *)
  check bool "URL title is rejected under Kimi_code" false
    (allow ~driver:Kimi_code ~policy:mcp_only ~title:"https://example.com/api" ~kind:(Some Tool_other));
  (* Cross-driver MCP grammar isolation: foreign driver syntax MUST fail closed
     on all three live-verified drivers (agy acp 1.5.14, kimi acp 2.7.2,
     vibe-acp 3.1.0). *)
  List.iter
    (fun (driver, title, kind) ->
       check bool ("rejects cross-driver MCP syntax " ^ title) false
         (allow ~driver ~policy:mcp_only ~title ~kind))
    [ Runtime_acp_client.Antigravity, "mcp_masc.masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Antigravity, "mcp__masc__keeper_skill", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Antigravity, "masc_masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Mistral_vibe, "mcp(masc/keeper_skill)", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Mistral_vibe, "mcp__masc__keeper_skill", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Kimi_code, "mcp(masc/keeper_skill)", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Kimi_code, "masc:masc_probe_ping", Some Runtime_acp_client.Tool_vendor_mcp
    ; Runtime_acp_client.Kimi_code, "masc/keeper_skill", None
    ; Runtime_acp_client.Kimi_code, "masc_probe_ping", Some Runtime_acp_client.Tool_vendor_mcp
    ; Runtime_acp_client.Kimi_code, "mcp_masc.masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Kimi_code, "mcp_masc_masc_probe_ping", Some Runtime_acp_client.Tool_other
    ; Runtime_acp_client.Kimi_code, "masc_masc_probe_ping", Some Runtime_acp_client.Tool_other
    ];
  (* Recorded kimi acp 2.7.2 wire frames: mcp__masc__masc_probe_ping (kind=other) allowed,
     foreign server mcp__foreign-srv__masc_probe_ping denied. *)
  let kimi_classify =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Kimi_code
      ~mcp_server_name:"masc"
  in
  let kimi_masc_tool_call =
    `Assoc
      [ "toolCallId", `String "0:call_kimi_probe_1"
      ; "title", `String "mcp__masc__masc_probe_ping"
      ; "kind", `String "other"
      ; "status", `String "pending"
      ]
  in
  let kimi_foreign_tool_call =
    `Assoc
      [ "toolCallId", `String "0:call_kimi_probe_0"
      ; "title", `String "mcp__foreign-srv__masc_probe_ping"
      ; "kind", `String "other"
      ; "status", `String "pending"
      ]
  in
  let kimi_perm_omitted_kind =
    `Assoc
      [ "toolCallId", `String "0:call_kimi_probe_1"
      ; "title", `String "mcp__masc__masc_probe_ping"
      ]
  in
  check bool "recorded kimi 2.7.2 mcp__masc__masc_probe_ping tool_call allowed" true
    (Runtime_acp_client.should_allow_tool_call ~policy:mcp_only (kimi_classify kimi_masc_tool_call));
  check bool "recorded kimi 2.7.2 permission with omitted kind allowed" true
    (Runtime_acp_client.should_allow_tool_call ~policy:mcp_only (kimi_classify kimi_perm_omitted_kind));
  check bool "recorded kimi 2.7.2 foreign server mcp__foreign-srv__masc_probe_ping denied" false
    (Runtime_acp_client.should_allow_tool_call ~policy:mcp_only (kimi_classify kimi_foreign_tool_call));
  (* Negative security posture checks under Allow_masc_mcp_only *)
  check bool "denies foreign MCP server even when kind=Tool_vendor_mcp" false
    (allow ~driver:Kimi_code ~policy:mcp_only ~title:"github__delete_repo" ~kind:(Some Tool_vendor_mcp));
  check bool "denies native execute tool whose title starts with masc_" false
    (allow ~driver:Mistral_vibe ~policy:mcp_only ~title:"masc_rm_rf" ~kind:(Some Tool_execute));
  check bool "denies native execute tool even if suffix matches tool name" false
    (allow ~driver:Mistral_vibe ~policy:mcp_only ~title:"masc_masc_probe_ping" ~kind:(Some Tool_execute));
  check bool "denies unpinned MASC-prefixed tool" false
    (allow ~driver:Kimi_code ~policy:mcp_only ~title:"mcp__masc__unpinned_tool" ~kind:(Some Tool_vendor_mcp));
  check bool "denies native read tool under Native_none" false
    (allow ~driver:Antigravity ~policy:mcp_only ~title:"read_file" ~kind:(Some Tool_read));
  (* Native_read posture & official ACP v1 tool_kind lattice *)
  check bool "allows native read tool under Allow_read_and_masc_mcp" true
    (allow ~driver:Antigravity ~policy:read_and_mcp ~title:"read_file" ~kind:(Some Tool_read));
  check bool "denies switch_mode under Allow_read_and_masc_mcp" false
    (allow ~driver:Antigravity ~policy:read_and_mcp ~title:"switch" ~kind:(Some Tool_switch_mode));
  check bool "denies Tool_unknown under Allow_read_and_masc_mcp" false
    (allow ~driver:Antigravity ~policy:read_and_mcp ~title:"future_op" ~kind:(Some (Tool_unknown "future_kind")));
  check bool "still denies foreign MCP server under Allow_read_and_masc_mcp" false
    (allow ~driver:Kimi_code ~policy:read_and_mcp ~title:"github__delete_repo" ~kind:(Some Tool_vendor_mcp));
  check bool "still denies masc_ execute under Allow_read_and_masc_mcp" false
    (allow ~driver:Mistral_vibe ~policy:read_and_mcp ~title:"masc_rm_rf" ~kind:(Some Tool_execute));
  (* Monotonic merge_tool_kind partial-order security join *)
  let merge = Runtime_acp_client.For_testing.merge_tool_kind in
  let check_kind label expected actual =
    check bool label true (Option.equal Runtime_acp_client.equal_tool_kind expected actual)
  in
  check_kind "Execute -> Read escalates to cross-branch conflict (denied everywhere)"
    (Some (Tool_unknown "conflict:execute->read"))
    (merge ~prior:(Some Tool_execute) ~incoming:(Some Tool_read));
  check_kind "Read -> Execute escalates to cross-branch conflict (never relaxes Read into Execute)"
    (Some (Tool_unknown "conflict:read->execute"))
    (merge ~prior:(Some Tool_read) ~incoming:(Some Tool_execute));
  check_kind "Read -> Other escalates to cross-branch conflict (never preserves Native_read allow)"
    (Some (Tool_unknown "conflict:read->other"))
    (merge ~prior:(Some Tool_read) ~incoming:(Some Tool_other));
  check_kind "Other -> Read escalates to cross-branch conflict (never preserves MCP allow)"
    (Some (Tool_unknown "conflict:other->read"))
    (merge ~prior:(Some Tool_other) ~incoming:(Some Tool_read));
  check_kind "Read -> Vendor_mcp escalates to cross-branch conflict"
    (Some (Tool_unknown "conflict:read->mcp"))
    (merge ~prior:(Some Tool_read) ~incoming:(Some Tool_vendor_mcp));
  check_kind "Vendor_mcp -> Other tightens away Implicit_vendor_mcp_kind"
    (Some Tool_other) (merge ~prior:(Some Tool_vendor_mcp) ~incoming:(Some Tool_other));
  check_kind "Read -> Search tightens away Managed_mcp_schema_read"
    (Some Tool_search) (merge ~prior:(Some Tool_read) ~incoming:(Some Tool_search));
  check_kind "Edit -> Execute stays Edit (no downgrade)"
    (Some Tool_edit) (merge ~prior:(Some Tool_edit) ~incoming:(Some Tool_execute));
  check_kind "Other -> Execute escalates to Execute"
    (Some Tool_execute) (merge ~prior:(Some Tool_other) ~incoming:(Some Tool_execute));
  check_kind "Other -> Edit escalates to Edit"
    (Some Tool_edit) (merge ~prior:(Some Tool_other) ~incoming:(Some Tool_edit));
  check_kind "Read -> Delete escalates to Delete"
    (Some Tool_delete) (merge ~prior:(Some Tool_read) ~incoming:(Some Tool_delete));
  check_kind "Read -> Unknown escalates to Unknown"
    (Some (Tool_unknown "x")) (merge ~prior:(Some Tool_read) ~incoming:(Some (Tool_unknown "x")))
;;

let http_post ~sw ~net ~endpoint ~authorization ?protocol_version body =
  let uri = Uri.of_string endpoint in
  let port = Uri.port uri |> Option.get in
  let path = Uri.path uri in
  let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  let proto_hdr =
    match protocol_version with
    | None -> []
    | Some v -> [ "MCP-Protocol-Version: " ^ v ]
  in
  let req =
    String.concat "\r\n"
      ([ Printf.sprintf "POST %s HTTP/1.1" path
       ; Printf.sprintf "Host: 127.0.0.1:%d" port
       ; "Authorization: " ^ authorization
       ; "Accept: application/json, text/event-stream"
       ; "Content-Type: application/json"
       ]
       @ proto_hdr
       @ [ Printf.sprintf "Content-Length: %d" (String.length body)
         ; "Connection: close"
         ; ""
         ; body
         ])
  in
  Eio.Flow.copy_string req flow;
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let status_line = Eio.Buf_read.line reader in
  let status =
    match String.split_on_char ' ' status_line with
    | _ :: code :: _ -> int_of_string code
    | _ -> failf "invalid HTTP status line: %S" status_line
  in
  let rec read_len acc =
    let line = Eio.Buf_read.line reader in
    if line = "" || line = "\r"
    then acc
    else (
      match String.index_opt line ':' with
      | Some idx ->
        let k = String.sub line 0 idx |> String.trim |> String.lowercase_ascii in
        if String.equal k "content-length"
        then
          read_len
            (String.sub line (idx + 1) (String.length line - idx - 1)
             |> String.trim
             |> int_of_string)
        else read_len acc
      | None -> read_len acc)
  in
  let len = read_len 0 in
  status, Eio.Buf_read.take len reader
;;

(* Regression for P0: Keeper_acp_runtime's MCP bridge must serve the full pinned
   MASC tool catalog during Acp.start / session/new BEFORE turn_slot is bound. *)
let test_mcp_bridge_advertises_pinned_tools_before_turn_slot () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pinned_tool_specs =
        [ `Assoc
            [ "name", `String "masc_probe_ping"
            ; "description", `String "Ping"
            ; "inputSchema", `Assoc [ "type", `String "object" ]
            ]
        ; `Assoc
            [ "name", `String "keeper_skill"
            ; "description", `String "Skill catalog"
            ; "inputSchema", `Assoc [ "type", `String "object" ]
            ]
        ]
      in
      let bridge =
        Keeper_acp_runtime.For_testing.start_mcp_bridge_for_specs ~sw ~env ~pinned_tool_specs
      in
      let { Runtime_official_client_mcp_http.url; headers } =
        Runtime_official_client_mcp_http.endpoint bridge
      in
      let authorization = List.assoc "Authorization" headers in
      let pv = "2025-11-25" in
      let init_status, _ =
        http_post
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~endpoint:url
          ~authorization
          {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}|}
      in
      check int "initialize status" 200 init_status;
      let notif_status, _ =
        http_post
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~endpoint:url
          ~authorization
          ~protocol_version:pv
          {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}
      in
      check int "notifications/initialized status" 202 notif_status;
      let list_status, list_body =
        http_post
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~endpoint:url
          ~authorization
          ~protocol_version:pv
          {|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}|}
      in
      check int "tools/list status" 200 list_status;
      let open Yojson.Safe.Util in
      let names =
        Yojson.Safe.from_string list_body
        |> member "result"
        |> member "tools"
        |> to_list
        |> List.map (fun t -> t |> member "name" |> to_string)
      in
      check (list string) "pinned MASC tools advertised before turn_slot is bound"
        [ "masc_probe_ping"; "keeper_skill" ]
        names))
;;

type fake_pool_entry =
  { id : int
  ; turn_mutex : Eio.Mutex.t
  ; mutable alive : bool
  ; mutable closed : bool
  }

let make_fake_entry id =
  { id; turn_mutex = Eio.Mutex.create (); alive = true; closed = false }
;;

let close_fake_entry (e : fake_pool_entry) =
  e.alive <- false;
  e.closed <- true
;;

(* Regression for P1: cancelling a fiber inside a pooled turn must evict the
   entry (whose Eio.Mutex.t is now poisoned) so the next turn acquires a fresh
   entry and succeeds, while a waiter blocked on the poisoned mutex gets a
   typed error and cancelling a waiter leaves an active holder untouched. *)
let test_cancelled_turn_evicts_entry_and_recovers () =
  let module Pool = Keeper_acp_runtime.For_testing.Pool in
  let key : Keeper_acp_runtime.For_testing.pool_key =
    { keeper_name = "alice"
    ; runtime_id = "antigravity_acp.gemini_4_neon_high"
    ; tool_surface_sha256 = "sha-v1"
    ; process_config_sha256 = "cfg-v1"
    ; cwd = "/tmp/alice"
    ; dangerously_skip_permissions = false
    }
  in
  Eio_main.run (fun _env ->
    let pool = Pool.create () in
    let entry_1 = make_fake_entry 1 in
    let installed =
      Pool.install_for_keeper
        pool
        ~key
        ~fresh:entry_1
        ~is_alive:(fun e -> e.alive)
        ~close:close_fake_entry
    in
    check int "initial entry installed" 1 installed.id;
    let holder_entered, resolve_holder_entered = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let holder_cancelled = ref false in
    let waiter_result = ref None in
    Eio.Switch.run (fun parent_sw ->
      let cancel_trigger, resolve_cancel_trigger = Eio.Promise.create () in
      Eio.Fiber.fork ~sw:parent_sw (fun () ->
        Eio.Promise.await holder_entered;
        (* Waiter blocks on entry_1.turn_mutex while holder is inside. *)
        let res =
          Keeper_acp_runtime.For_testing.run_serialized_turn
            ~mutex:entry_1.turn_mutex
            ~on_holder_exception:(fun () ->
              Pool.evict_if_same pool ~key ~target:entry_1 ~close:close_fake_entry)
            (fun () -> Ok "unexpected")
        in
        waiter_result := Some res);
      Eio.Fiber.fork ~sw:parent_sw (fun () ->
        Eio.Promise.await holder_entered;
        Eio.Fiber.yield ();
        Eio.Promise.resolve resolve_cancel_trigger ());
      try
        Eio.Switch.run (fun turn_sw ->
          Eio.Fiber.fork ~sw:turn_sw (fun () ->
            Eio.Promise.await cancel_trigger;
            Eio.Switch.fail turn_sw Exit);
          ignore
            (Keeper_acp_runtime.For_testing.run_serialized_turn
               ~mutex:entry_1.turn_mutex
               ~on_holder_exception:(fun () ->
                 Pool.evict_if_same pool ~key ~target:entry_1 ~close:close_fake_entry)
               (fun () ->
                 Eio.Promise.resolve resolve_holder_entered ();
                 Eio.Promise.await never;
                 Ok "unreachable")))
      with
      | Exit -> holder_cancelled := true);
    check bool "holder cancel propagated" true !holder_cancelled;
    check bool "cancelled holder entry closed" true entry_1.closed;
    check bool "cancelled holder entry evicted from pool" true
      (Option.is_none (Pool.find_opt pool key));
    let expected_closed_error =
      Keeper_acp_runtime.For_testing.acp_error_to_core_error Runtime_acp_client.Client_closed
      |> Agent_core.Error.to_string
    in
    (match !waiter_result with
     | Some (Error err) ->
       check string "waiter gets Client_closed error instead of Poisoned"
         expected_closed_error
         (Agent_core.Error.to_string err)
     | Some (Ok v) -> failf "waiter unexpectedly succeeded: %s" v
     | None -> fail "waiter did not complete");
    (* Next turn installs fresh entry_2 and succeeds cleanly. *)
    let entry_2 = make_fake_entry 2 in
    let next_installed =
      Pool.install_for_keeper
        pool
        ~key
        ~fresh:entry_2
        ~is_alive:(fun e -> e.alive)
        ~close:close_fake_entry
    in
    check int "fresh replacement installed" 2 next_installed.id;
    let recovered =
      Keeper_acp_runtime.For_testing.run_serialized_turn
        ~mutex:entry_2.turn_mutex
        ~on_holder_exception:(fun () ->
          Pool.evict_if_same pool ~key ~target:entry_2 ~close:close_fake_entry)
        (fun () -> Ok "recovered")
    in
    (match recovered with
     | Ok msg -> check string "next turn succeeds on fresh entry" "recovered" msg
     | Error err -> failf "next turn failed: %s" (Agent_core.Error.to_string err));
    (* Cancelling a waiter BEFORE acquiring turn_mutex must NOT evict the active holder. *)
    let holder2_entered, resolve_holder2_entered = Eio.Promise.create () in
    let release_holder2, resolve_release_holder2 = Eio.Promise.create () in
    let waiter2_cancelled = ref false in
    let holder2_result = ref None in
    Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        holder2_result :=
          Some
            (Keeper_acp_runtime.For_testing.run_serialized_turn
               ~mutex:entry_2.turn_mutex
               ~on_holder_exception:(fun () ->
                 Pool.evict_if_same pool ~key ~target:entry_2 ~close:close_fake_entry)
               (fun () ->
                 Eio.Promise.resolve resolve_holder2_entered ();
                 Eio.Promise.await release_holder2;
                 Ok "holder-ok")));
      Eio.Promise.await holder2_entered;
      (try
         Eio.Switch.run (fun waiter_sw ->
           Eio.Fiber.fork ~sw:waiter_sw (fun () ->
             Eio.Fiber.yield ();
             Eio.Switch.fail waiter_sw Exit);
           ignore
             (Keeper_acp_runtime.For_testing.run_serialized_turn
                ~mutex:entry_2.turn_mutex
                ~on_holder_exception:(fun () ->
                  Pool.evict_if_same pool ~key ~target:entry_2 ~close:close_fake_entry)
                (fun () -> Ok "never-acquired")))
       with
       | Exit -> waiter2_cancelled := true);
      Eio.Promise.resolve resolve_release_holder2 ());
    check bool "waiter cancel propagated" true !waiter2_cancelled;
    check bool "active holder entry NOT closed by waiter cancel" false entry_2.closed;
    check bool "active holder entry remains pooled" true
      (Option.is_some (Pool.find_opt pool key));
    (match !holder2_result with
     | Some (Ok msg) -> check string "holder completed cleanly" "holder-ok" msg
     | _ -> fail "expected active holder to complete cleanly"))
;;

(* Regression for P2: switching runtime_id, tool_surface_sha256, cwd, or
   dangerously_skip_permissions for a Keeper must evict and close its prior
   pooled entry while keeping other Keepers' entries untouched. *)
let test_pool_key_switch_evicts_superseded_keeper_entry () =
  let module Pool = Keeper_acp_runtime.For_testing.Pool in
  let pool = Pool.create () in
  let alice_base : Keeper_acp_runtime.For_testing.pool_key =
    { keeper_name = "alice"
    ; runtime_id = "antigravity_acp.gemini_4_neon_high"
    ; tool_surface_sha256 = "sha-1"
    ; process_config_sha256 = "cfg-1"
    ; cwd = "/tmp/alice-a"
    ; dangerously_skip_permissions = false
    }
  in
  let bob_key : Keeper_acp_runtime.For_testing.pool_key =
    { keeper_name = "bob"
    ; runtime_id = "kimi_acp.k3_1_pro"
    ; tool_surface_sha256 = "sha-bob"
    ; process_config_sha256 = "cfg-bob"
    ; cwd = "/tmp/bob"
    ; dangerously_skip_permissions = false
    }
  in
  let alice_1 = make_fake_entry 1 in
  let bob_1 = make_fake_entry 100 in
  ignore
    (Pool.install_for_keeper
       pool
       ~key:alice_base
       ~fresh:alice_1
       ~is_alive:(fun e -> e.alive)
       ~close:close_fake_entry);
  ignore
    (Pool.install_for_keeper
       pool
       ~key:bob_key
       ~fresh:bob_1
       ~is_alive:(fun e -> e.alive)
       ~close:close_fake_entry);
  check int "two keepers pooled" 2 (Pool.count pool);
  (* Switch runtime_id, tool_surface_sha256, cwd, and permission posture in turn. *)
  let switches =
    [ "runtime_id", { alice_base with runtime_id = "kimi_acp.k3_1_pro" }, make_fake_entry 2
    ; ( "tool_surface_sha256"
      , { alice_base with runtime_id = "kimi_acp.k3_1_pro"; tool_surface_sha256 = "sha-2" }
      , make_fake_entry 3 )
    ; ( "cwd"
      , { alice_base with
          runtime_id = "kimi_acp.k3_1_pro"
        ; tool_surface_sha256 = "sha-2"
        ; cwd = "/tmp/alice-b"
        }
      , make_fake_entry 4 )
    ; ( "dangerously_skip_permissions"
      , { alice_base with
          runtime_id = "kimi_acp.k3_1_pro"
        ; tool_surface_sha256 = "sha-2"
        ; cwd = "/tmp/alice-b"
        ; dangerously_skip_permissions = true
        }
      , make_fake_entry 5 )
    ; ( "process_config_sha256"
      , { alice_base with
          runtime_id = "kimi_acp.k3_1_pro"
        ; tool_surface_sha256 = "sha-2"
        ; process_config_sha256 = "cfg-2"
        ; cwd = "/tmp/alice-b"
        ; dangerously_skip_permissions = true
        }
      , make_fake_entry 6 )
    ]
  in
  let prev = ref alice_1 in
  let last_key = ref alice_base in
  List.iter
    (fun (label, next_key, next_entry) ->
       let installed =
         Pool.install_for_keeper
           pool
           ~key:next_key
           ~fresh:next_entry
           ~is_alive:(fun e -> e.alive)
           ~close:close_fake_entry
       in
       check int (label ^ " installed new entry") next_entry.id installed.id;
       check bool (label ^ " closed superseded entry") true !prev.closed;
       check bool (label ^ " removed old key") true
         (Option.is_none (Pool.find_opt pool !last_key));
       check int (label ^ " pool stays bounded at 1 per keeper") 2 (Pool.count pool);
       check bool (label ^ " bob untouched") false bob_1.closed;
       prev := next_entry;
       last_key := next_key)
    switches;
  (* Concurrent duplicate install for the same live key closes the loser. *)
  let duplicate_loser = make_fake_entry 6 in
  let winner =
    Pool.install_for_keeper
      pool
      ~key:!last_key
      ~fresh:duplicate_loser
      ~is_alive:(fun e -> e.alive)
      ~close:close_fake_entry
  in
  check int "duplicate keeps existing live winner" !prev.id winner.id;
  check bool "duplicate loser closed" true duplicate_loser.closed;
  (* Stale evict_if_same cannot evict the newer replacement. *)
  Pool.evict_if_same pool ~key:!last_key ~target:alice_1 ~close:close_fake_entry;
  check bool "stale evict_if_same did not remove current entry" true
    (Option.is_some (Pool.find_opt pool !last_key));
  (* evict_keeper removes only alice, keeping bob alive. *)
  Pool.evict_keeper pool ~keeper_name:"alice" ~close:close_fake_entry;
  check bool "evict_keeper closed alice" true !prev.closed;
  check int "only bob remains" 1 (Pool.count pool);
  check bool "bob still alive" false bob_1.closed;
  (* evict_idle evicts old idle entries while preserving busy or fresh entries. *)
  let carol_key = { bob_key with keeper_name = "carol" } in
  let carol_1 = make_fake_entry 200 in
  ignore
    (Pool.install_for_keeper
       pool
       ~key:carol_key
       ~fresh:carol_1
       ~is_alive:(fun e -> e.alive)
       ~close:close_fake_entry);
  Pool.evict_idle
    pool
    ~now:5000.0
    ~idle_ttl_s:1800.0
    ~last_used_at:(fun e -> if e.id = 100 then 1000.0 else 4500.0)
    ~is_busy:(fun e -> e.id = 100)
    ~close:close_fake_entry;
  check bool "busy old entry bob is NOT evicted by evict_idle" false bob_1.closed;
  check bool "fresh idle entry carol is NOT evicted by evict_idle" false carol_1.closed;
  Pool.evict_idle
    pool
    ~now:5000.0
    ~idle_ttl_s:1800.0
    ~last_used_at:(fun e -> if e.id = 100 then 1000.0 else 4500.0)
    ~is_busy:(fun _ -> false)
    ~close:close_fake_entry;
  check bool "idle old entry bob IS evicted by evict_idle" true bob_1.closed;
  check bool "fresh idle entry carol remains pooled" false carol_1.closed;
  (* evict_all drains all remaining entries. *)
  Pool.evict_all pool ~close:close_fake_entry;
  check bool "evict_all closed carol" true carol_1.closed;
  check int "pool empty after evict_all" 0 (Pool.count pool)
;;

let rec rm_rf path =
  match Unix.lstat path with
  | stat ->
    if stat.Unix.st_kind = Unix.S_DIR
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let read_file_text path =
  In_channel.with_open_text path In_channel.input_all
;;

let test_acp_80_pct_rollover_marker_and_overflow_classification () =
  let should = Keeper_acp_runtime.For_testing.should_rollover_context in
  check bool "below 80% threshold does not trigger rollover" false
    (should ~context_used:(Some 200_000) ~context_size:None ~max_context_tokens:262_144);
  check bool "at/above 80% threshold triggers rollover" true
    (should ~context_used:(Some 210_000) ~context_size:None ~max_context_tokens:262_144);
  check bool "smaller advertised context_size governs 80% rollover" true
    (should ~context_used:(Some 80_000) ~context_size:(Some 100_000) ~max_context_tokens:262_144);
  check bool "smaller operator max_context_tokens caps 80% rollover on larger provider window" true
    (should ~context_used:(Some 320_000) ~context_size:(Some 1_048_576) ~max_context_tokens:400_000);
  check bool "below 80% of operator max_context_tokens cap does not trigger rollover" false
    (should ~context_used:(Some 319_999) ~context_size:(Some 1_048_576) ~max_context_tokens:400_000);
  check int "effective_context_limit_tokens takes min of positive context_size and max_context_tokens"
    400_000
    (Keeper_acp_runtime.For_testing.effective_context_limit_tokens
       ~context_size:(Some 1_048_576) ~max_context_tokens:400_000);
  check int "effective_context_limit_tokens keeps smaller provider context_size"
    100_000
    (Keeper_acp_runtime.For_testing.effective_context_limit_tokens
       ~context_size:(Some 100_000) ~max_context_tokens:400_000);
  check int "effective_context_limit_tokens falls back to max_context_tokens when context_size is non-positive"
    400_000
    (Keeper_acp_runtime.For_testing.effective_context_limit_tokens
       ~context_size:(Some 0) ~max_context_tokens:400_000);
  check int "effective_context_limit_tokens falls back to context_size when max_context_tokens is non-positive"
    100_000
    (Keeper_acp_runtime.For_testing.effective_context_limit_tokens
       ~context_size:(Some 100_000) ~max_context_tokens:0);
  check int "effective_context_limit_tokens returns 0 when both limits are non-positive"
    0
    (Keeper_acp_runtime.For_testing.effective_context_limit_tokens
       ~context_size:(Some (-1)) ~max_context_tokens:0);
  check bool "missing context_used does not trigger rollover" false
    (should ~context_used:None ~context_size:(Some 100_000) ~max_context_tokens:262_144);
  (* Durable rollover marker roundtrip under <masc_root>/runtime/acp-rollover/
     (classified by Server_tool_blob_scope so Tool_blob_sweep.reclaim is never blocked). *)
  let base_path = Filename.temp_dir "acp-rollover-" "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () ->
    Keeper_acp_runtime.For_testing.record_rollover_marker
      ~base_path ~keeper_id:"k1" ~runtime_id:"vibe_acp.m1" ~session_id:"sess-1";
    check bool "exact rollover marker matches" true
      (Keeper_acp_runtime.For_testing.rollover_marker_matches
         ~base_path ~keeper_id:"k1" ~runtime_id:"vibe_acp.m1" ~session_id:"sess-1");
    check bool "different session_id does not match" false
      (Keeper_acp_runtime.For_testing.rollover_marker_matches
         ~base_path ~keeper_id:"k1" ~runtime_id:"vibe_acp.m1" ~session_id:"sess-2");
    check bool "different runtime_id does not match" false
      (Keeper_acp_runtime.For_testing.rollover_marker_matches
         ~base_path ~keeper_id:"k1" ~runtime_id:"agy.m1" ~session_id:"sess-1");
    (match
       Tool_blob_maintenance.unclassified_entries
         ~base_path
         Server_tool_blob_scope.scope
     with
     | Ok entries ->
       check (list string) "armed rollover marker leaves zero unclassified entries in blob scope"
         []
         (List.map Tool_blob_maintenance.unclassified_entry_to_string entries)
     | Error err ->
       failf "unclassified_entries failed: %s"
         (Tool_blob_maintenance.error_to_string err));
    Keeper_acp_runtime.For_testing.clear_rollover_marker ~base_path ~keeper_id:"k1";
    check bool "cleared marker no longer matches" false
      (Keeper_acp_runtime.For_testing.rollover_marker_matches
         ~base_path ~keeper_id:"k1" ~runtime_id:"vibe_acp.m1" ~session_id:"sess-1");
    (* evict_keeper_for_workspace also clears armed rollover marker on teardown *)
    Keeper_acp_runtime.For_testing.record_rollover_marker
      ~base_path ~keeper_id:"k1" ~runtime_id:"vibe_acp.m1" ~session_id:"sess-1";
    Keeper_acp_runtime.evict_keeper_for_workspace ~base_path ~keeper_name:"k1";
    check bool "evict_keeper_for_workspace clears armed rollover marker" false
      (Keeper_acp_runtime.For_testing.rollover_marker_matches
         ~base_path ~keeper_id:"k1" ~runtime_id:"vibe_acp.m1" ~session_id:"sess-1"));
  (* Atom-boundary-safe split_older_for_rollover: never splits Assistant(tool_use)+Tool(tool_result)
     and never counts/evicts existing compaction anchors or System/Pinned messages. *)
  let open Agent_core.Types in
  let conv_msg role content : message =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role; content; name = None; tool_call_id = None; metadata = []
    }
  in
  let existing_anchor_msg =
    { (conv_msg User [ Text "preserve existing anchor" ]) with
      origin = Agent_core.Llm_provider.Types.Outside_context
    ; metadata = Runtime_model_input_tail_window.compaction_anchor_metadata
    }
  in
  check bool "fixture message is recognized as compaction anchor" true
    (Runtime_model_input_tail_window.is_compaction_anchor existing_anchor_msg);
  (* 4 conversation atoms total:
     atom 0: User "u0"
     atom 1: Assistant(tool_use "call-1") + Tool(tool_result "call-1")
     atom 2: User "u2"
     atom 3: Assistant "a3"
     With 4 atoms, keep_recent = max 2 (4/4) = 2, evict_atoms = 2 -> atoms 0 and 1.
     Crucially atom 1's Assistant(tool_use) AND Tool(tool_result) must BOTH be evicted
     together (never split!), and existing_anchor_msg must NOT be evicted or counted. *)
  let tool_use_msg =
    conv_msg Assistant
      [ ToolUse { id = "call-1"; name = "masc_probe_ping"; input = `Assoc [] } ]
  in
  let tool_result_msg =
    { (conv_msg Tool
         [ ToolResult
             { tool_use_id = "call-1"
             ; content = "pong"
             ; outcome = Tool_succeeded
             ; json = None
             ; content_blocks = None
             }
         ])
      with
      tool_call_id = Some "call-1"
    }
  in
  let rollover_input =
    [ existing_anchor_msg
    ; conv_msg User [ Text "u0" ]
    ; tool_use_msg
    ; tool_result_msg
    ; conv_msg User [ Text "u2" ]
    ; conv_msg Assistant [ Text "a3" ]
    ]
  in
  let evicted = Keeper_acp_runtime.For_testing.split_older_for_rollover rollover_input in
  check bool "existing compaction anchor is never evicted by split_older_for_rollover" false
    (List.exists
       (fun (m : message) -> Runtime_model_input_tail_window.is_compaction_anchor m)
       evicted);
  let has_tool_use =
    List.exists
      (fun (m : message) ->
         List.exists (function ToolUse { id = "call-1"; _ } -> true | _ -> false) m.content)
      evicted
  in
  let has_tool_result =
    List.exists
      (fun (m : message) ->
         List.exists (function ToolResult { tool_use_id = "call-1"; _ } -> true | _ -> false) m.content)
      evicted
  in
  check bool "Assistant(tool_use) and Tool(tool_result) are never split across rollover boundary"
    true (has_tool_use = has_tool_result && has_tool_use);
  check int "evicted prefix contains exactly atom 0 (User) + atom 1 (Assistant+Tool) = 3 messages"
    3 (List.length evicted);
  let overflow_err =
    Runtime_acp_client.rpc_error
      ~method_name:"session/prompt"
      ~code:(-32000)
      ~message:"maximum context window reached"
      ~data:(Some (Yojson.Safe.from_string {|{"error":{"code":"context_length_exceeded","n_ctx":128000}}|}))
  in
  (match Keeper_acp_runtime.For_testing.acp_error_to_core_error overflow_err with
   | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow { limit = Some 128000; _ }) -> ()
   | other ->
     failf "expected Api ContextOverflow with limit=128000, got %s"
       (Agent_core.Error.to_string other));
  (match Keeper_acp_runtime.For_testing.recovery_failure_of_acp_error overflow_err with
   | Keeper_official_client_session_store.Input_rejected
       Keeper_official_client_session_store.Bootstrap_floor_exceeded -> ()
   | other ->
     failf "expected Input_rejected Bootstrap_floor_exceeded, got %s"
       (Keeper_official_client_session_store.recovery_failure_to_string other));
  let plain_err =
    Runtime_acp_client.rpc_error
      ~method_name:"session/prompt" ~code:(-32602) ~message:"invalid params" ~data:None
  in
  (match Keeper_acp_runtime.For_testing.recovery_failure_of_acp_error plain_err with
   | Keeper_official_client_session_store.Provider_rejected -> ()
   | other ->
     failf "expected Provider_rejected for ordinary RPC error, got %s"
       (Keeper_official_client_session_store.recovery_failure_to_string other))
;;

let test_vibe_310_config_options_and_permission_hardening () =
  let cfg_json =
    `Assoc
      [ ( "configOptions"
        , `List
            [ `Assoc
                [ "id", `String "model"
                ; "category", `String "model"
                ; "currentValue", `String "mistral-medium-3.5"
                ; ( "options"
                  , `List
                      [ `Assoc
                          [ "group", `String "Mistral"
                          ; ( "options"
                            , `List
                                [ `Assoc [ "value", `String "mistral-medium-3.5"; "name", `String "Mistral Medium 3.5" ]
                                ; `Assoc [ "value", `String "mistral-large-latest"; "name", `String "Mistral Large" ]
                                ] )
                          ]
                      ] )
                ]
            ; `Assoc
                [ "id", `String "thinking"
                ; "category", `String "thought_level"
                ; "currentValue", `String "off"
                ; ( "options"
                  , `List
                      [ `Assoc [ "value", `String "off"; "name", `String "Off" ]
                      ; `Assoc [ "value", `String "high"; "name", `String "High" ]
                      ] )
                ]
            ] )
      ]
  in
  let opts = Runtime_acp_client.For_testing.parse_config_options cfg_json in
  check int "parsed two configOptions" 2 (List.length opts);
  let model_opt = List.nth opts 0 in
  let effort_opt = List.nth opts 1 in
  check (list string) "grouped model available_values parsed"
    [ "mistral-medium-3.5"; "mistral-large-latest" ]
    model_opt.available_values;
  check (list string) "flat effort available_values parsed"
    [ "off"; "high" ]
    effort_opt.available_values;
  let resolve_model = Runtime_acp_client.For_testing.resolve_model_option_value in
  let resolve_effort = Runtime_acp_client.For_testing.resolve_effort_option_value in
  check (option string) "Keep_cli_default model selection is skipped" None
    (resolve_model
       ~driver:Mistral_vibe
       ~requested:Runtime_acp_client.keep_cli_default
       ~option:model_opt);
  check (option string) "retired devstral-2 is skipped when unsupported" None
    (resolve_model
       ~driver:Mistral_vibe
       ~requested:(Runtime_acp_client.model_selection_of_string "devstral-2")
       ~option:model_opt);
  check (option string) "already-current Vibe 3.1.0 model skips redundant RPC" None
    (resolve_model
       ~driver:Mistral_vibe
       ~requested:(Runtime_acp_client.model_selection_of_string "mistral-medium-3.5")
       ~option:model_opt);
  check (option string) "supported Vibe 3.1.0 model switch resolves" (Some "mistral-large-latest")
    (resolve_model
       ~driver:Mistral_vibe
       ~requested:(Runtime_acp_client.model_selection_of_string "mistral-large-latest")
       ~option:model_opt);
  let dup_none_opt = { effort_opt with available_values = [ "none"; "off" ]; current_value = "off" } in
  check (option string) "duplicate None_ spellings preserve current_value without redundant RPC" None
    (resolve_effort
       ~driver:Mistral_vibe
       ~requested:Llm_provider.Reasoning_effort.None_
       ~option:dup_none_opt);
  check (option string) "None_ effort skips redundant RPC when currentValue is already off" None
    (resolve_effort
       ~driver:Mistral_vibe
       ~requested:Llm_provider.Reasoning_effort.None_
       ~option:effort_opt);
  let effort_opt_high = { effort_opt with current_value = "high" } in
  check (option string) "None_ effort maps to off when switching from high" (Some "off")
    (resolve_effort
       ~driver:Mistral_vibe
       ~requested:Llm_provider.Reasoning_effort.None_
       ~option:effort_opt_high);
  check (option string) "Ultra effort clamps downward to high on Vibe [off; high]" (Some "high")
    (resolve_effort
       ~driver:Mistral_vibe
       ~requested:Llm_provider.Reasoning_effort.Ultra
       ~option:effort_opt);
  check (option string) "Medium effort does NOT silently upgrade to high or turn off on Vibe [off; high]" None
    (resolve_effort
       ~driver:Mistral_vibe
       ~requested:Llm_provider.Reasoning_effort.Medium
       ~option:effort_opt);
  let low_high_opt : Runtime_acp_client.config_option =
    { id = "thought_level"
    ; name = "Thought"
    ; category = Some "thought_level"
    ; current_value = "high"
    ; available_values = [ "low"; "high" ]
    }
  in
  check (option string) "Medium clamps downward to nearest positive <= requested (low)" (Some "low")
    (resolve_effort
       ~driver:Antigravity
       ~requested:Llm_provider.Reasoning_effort.Medium
       ~option:low_high_opt);
  check (option string) "None_ does NOT upgrade to low when off/none is absent" None
    (resolve_effort
       ~driver:Antigravity
       ~requested:Llm_provider.Reasoning_effort.None_
       ~option:low_high_opt);
  let med_high_opt = { low_high_opt with available_values = [ "medium"; "high" ] } in
  check (option string) "Low does NOT silently upgrade to medium" None
    (resolve_effort
       ~driver:Antigravity
       ~requested:Llm_provider.Reasoning_effort.Low
       ~option:med_high_opt);
  (* Permission hardening: no Allow_always fallback, no fetch under Native_read, positive kind allowlist *)
  let only_always_and_reject =
    [ `Assoc [ "optionId", `String "opt_always"; "kind", `String "allow_always" ]
    ; `Assoc [ "optionId", `String "opt_reject"; "kind", `String "reject_once" ]
    ]
  in
  check (option string) "allow:true NEVER falls back to allow_always" None
    (Runtime_acp_client.For_testing.choose_permission_option ~allow:true only_always_and_reject);
  check (option string) "allow:false chooses reject_once" (Some "opt_reject")
    (Runtime_acp_client.For_testing.choose_permission_option ~allow:false only_always_and_reject);
  let read_and_mcp =
    Runtime_acp_client.Allow_read_and_masc_mcp
      { mcp_server_name = "masc"; allowed_tool_names = [ "masc_probe_ping" ] }
  in
  let allow = Runtime_acp_client.For_testing.should_allow_permission in
  check bool "fetch is DENIED under Allow_read_and_masc_mcp (egress/SSRF boundary)" false
    (allow ~driver:Mistral_vibe ~policy:read_and_mcp ~title:"fetch_url" ~kind:(Some Tool_fetch));
  check bool "unknown native tool kind is DENIED even with masc prefix" false
    (allow ~driver:Kimi_code ~policy:read_and_mcp ~title:"mcp__masc__masc_probe_ping"
       ~kind:(Some (Tool_unknown "browser_eval")));
  (* Negative usage values are clamped to non-negative *)
  let neg_usage =
    `Assoc
      [ "usage", `Assoc [ "inputTokens", `Int (-50); "outputTokens", `Int (-10); "totalTokens", `Int (-60) ] ]
    |> Runtime_acp_client.For_testing.parse_prompt_usage
  in
  check int "negative inputTokens clamped to 0" 0 neg_usage.input_tokens;
  check int "negative outputTokens clamped to 0" 0 neg_usage.output_tokens
;;

let pid_alive pid = Sys.command (Printf.sprintf "kill -0 %d 2>/dev/null" pid) = 0

let test_mock_acp_child_pgid_reap_session_perm_and_pid_tagged_dir () =
  let tmp = Filename.temp_dir "acp-e2e-" "" in
  let grandchild_pid_file = Filename.concat tmp "grandchild.pid" in
  let parent_pid_file = Filename.concat tmp "parent.pid" in
  let gemini_dir_file = Filename.concat tmp "gemini_dir.txt" in
  let perm_log_file = Filename.concat tmp "perm_outcomes.txt" in
  let mock_script = Filename.concat tmp "mock_acp.py" in
  let script_body =
    Printf.sprintf
      {|#!/usr/bin/env python3
import json, os, subprocess, sys

gdir = ""
for i, a in enumerate(sys.argv):
    if a == "--gemini-dir" and i + 1 < len(sys.argv):
        gdir = sys.argv[i + 1]
with open(%S, "w") as f:
    f.write(gdir)
with open(%S, "w") as f:
    f.write(str(os.getppid()))

grandchild = subprocess.Popen(["sleep", "60"])
with open(%S, "w") as f:
    f.write(str(grandchild.pid))

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

perm_outcomes = {}
pending_prompt_id = None

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if "method" in msg:
        m = msg["method"]
        req_id = msg.get("id")
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": True}
            }})
        elif m == "session/new":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "sessionId": "sess-1",
                "configOptions": []
            }})
        elif m == "session/prompt":
            pending_prompt_id = req_id
            # Send valid permission request AND spoofed wrong-sessionId permission request
            send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission", "params": {
                "sessionId": "sess-1",
                "toolCall": {"title": "mcp(masc/masc_probe_ping)", "kind": "mcp"},
                "options": [
                    {"optionId": "allow_once_id", "kind": "allow_once"},
                    {"optionId": "reject_once_id", "kind": "reject_once"}
                ]
            }})
            send({"jsonrpc": "2.0", "id": 9002, "method": "session/request_permission", "params": {
                "sessionId": "sess-spoofed",
                "toolCall": {"title": "mcp(masc/masc_probe_ping)", "kind": "mcp"},
                "options": [
                    {"optionId": "allow_once_id", "kind": "allow_once"},
                    {"optionId": "reject_once_id", "kind": "reject_once"}
                ]
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-1",
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ok-from-mock"}}
            }})
    else:
        rid = msg.get("id")
        if rid in (9001, 9002):
            perm_outcomes[str(rid)] = msg.get("result", {}).get("outcome", {})
            if len(perm_outcomes) == 2 and pending_prompt_id is not None:
                with open(%S, "w") as f:
                    json.dump(perm_outcomes, f)
                send({"jsonrpc": "2.0", "id": pending_prompt_id, "result": {
                    "stopReason": "end_turn",
                    "usage": {"inputTokens": 100, "outputTokens": 20, "totalTokens": 120}
                }})
                pending_prompt_id = None
|}
      gemini_dir_file
      parent_pid_file
      grandchild_pid_file
      perm_log_file
  in
  Out_channel.with_open_text mock_script (fun oc -> output_string oc script_body);
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr =
        Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 ()
      in
      let cfg =
        { (Runtime_acp_client.default_config ~driver:Antigravity ~cwd:tmp) with
          cli_path = "python3"
        ; args = [ mock_script ]
        ; admission_timeout_s = 10.0
        }
      in
      Eio.Switch.run (fun sw ->
        let client =
          match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~config:cfg () with
          | Ok c -> c
          | Error err -> failf "mock ACP start failed: %s" (Runtime_acp_client.error_to_string err)
        in
        let gdir = String.trim (read_file_text gemini_dir_file) in
        let parent_pid = String.trim (read_file_text parent_pid_file) in
        let expected_prefix = Printf.sprintf "masc-agy-acp-%s-" parent_pid in
        check bool "PID-tagged --gemini-dir prefix (#239 interlock)" true
          (String.starts_with ~prefix:expected_prefix (Filename.basename gdir));
        check bool "--gemini-dir exists while client is alive" true (Sys.file_exists gdir);
        let session =
          match Runtime_acp_client.new_session client ~cwd:tmp () with
          | Ok s -> s
          | Error err -> failf "new_session failed: %s" (Runtime_acp_client.error_to_string err)
        in
        let policy =
          Runtime_acp_client.Allow_masc_mcp_only
            { mcp_server_name = "masc"; allowed_tool_names = [ "masc_probe_ping" ] }
        in
        let prompt_res =
          match
            Runtime_acp_client.prompt
              client
              ~session_id:session.session_id
              ~blocks:[ Runtime_acp_client.Text_block "hello" ]
              ~permission_policy:policy
              ()
          with
          | Ok r -> r
          | Error err -> failf "prompt failed: %s" (Runtime_acp_client.error_to_string err)
        in
        check string "prompt text received" "ok-from-mock" prompt_res.text;
        let open Yojson.Safe.Util in
        let perms = Yojson.Safe.from_file perm_log_file in
        check (option string) "matching sessionId permission allowed with allow_once"
          (Some "allow_once_id")
          (perms |> member "9001" |> member "optionId" |> to_string_option);
        check (option string) "mismatched sessionId permission denied with reject_once"
          (Some "reject_once_id")
          (perms |> member "9002" |> member "optionId" |> to_string_option);
        let gpid = int_of_string (String.trim (read_file_text grandchild_pid_file)) in
        check bool "grandchild alive before close" true (pid_alive gpid);
        Runtime_acp_client.close client;
        (* Wait briefly for OS reaping of grandchild process group *)
        let rec wait_dead attempts =
          if not (pid_alive gpid) || attempts <= 0
          then ()
          else (
            Eio.Time.sleep clock 0.05;
            wait_dead (attempts - 1))
        in
        wait_dead 40;
        check bool "PGID reaping killed grandchild on close" false (pid_alive gpid);
        check bool "PID-tagged --gemini-dir cleaned up on close" false (Sys.file_exists gdir))))
;;

let test_acp_overflow_shrink_handoff_and_vibe_operator_login () =
  (* 1. Shrink retry with force_fresh_retry=true (previous_settlement=None) loads
        compacted handoff anchor and compacts at most ONCE across shrink retries. *)
  check bool "force_fresh_retry alone enables prefer_handoff" true
    (Keeper_acp_runtime.For_testing.prefer_handoff_for_start
       ~planned_fresh_rollover:false ~force_fresh_retry:true);
  check bool "normal cold start does not prefer_handoff" false
    (Keeper_acp_runtime.For_testing.prefer_handoff_for_start
       ~planned_fresh_rollover:false ~force_fresh_retry:false);
  let base_path = Filename.temp_dir "acp-shrink-handoff-" "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let mk_msg role text : Agent_core.Types.message =
      { origin = Agent_core.Llm_provider.Types.Conversation
      ; role
      ; content = [ Agent_core.Types.Text text ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    in
    let initial_messages =
      [ mk_msg Agent_core.Types.User "turn-1 build auth middleware"
      ; mk_msg Agent_core.Types.Assistant "turn-1 done"
      ; mk_msg Agent_core.Types.User "turn-2 add rate limiter"
      ; mk_msg Agent_core.Types.Assistant "turn-2 done"
      ; mk_msg Agent_core.Types.User "turn-3 harden SQLite WAL"
      ; mk_msg Agent_core.Types.Assistant "turn-3 done"
      ; mk_msg Agent_core.Types.User "turn-4 current prompt"
      ; mk_msg Agent_core.Types.Assistant "turn-4 partial"
      ]
    in
    let already_compacted = ref false in
    for attempt = 1 to 3 do
      Keeper_acp_runtime.For_testing.compact_once_for_overflow
        ~already_compacted
        ~keepers_dir
        ~keeper_id:"k-shrink"
        ~starting_capacity_bytes:100_000
        ~effective_max_context_tokens:25_000
        ~previous_capacity:(100_000 / attempt)
        ~capacity:(50_000 / attempt)
        ~initial_messages
    done;
    let epochs =
      Masc.Keeper_compaction.list_epochs ~keepers_dir ~keeper_id:"k-shrink"
      |> Result.get_ok
    in
    check int "overflow shrink emits exactly 1 compaction epoch across 3 retries"
      1 (List.length epochs);
    let anchor = List.hd epochs in
    let hydrated_retry =
      Keeper_acp_runtime.For_testing.hydrate_start_messages
        ~keepers_dir ~keeper_id:"k-shrink" ~prefer_handoff:true initial_messages
    in
    let contains_sub ~needle haystack =
      let nlen = String.length needle in
      let hlen = String.length haystack in
      let rec loop i =
        if i + nlen > hlen then false
        else if String.sub haystack i nlen = needle then true
        else loop (i + 1)
      in
      nlen = 0 || loop 0
    in
    let has_anchor_msg msgs =
      List.exists
        (fun (m : Agent_core.Types.message) ->
           let text =
             Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m)
           in
           contains_sub ~needle:anchor.active_intent text
           && m.metadata <> [])
        msgs
    in
    check bool "prefer_handoff:true loads compacted anchor even with existing conversation messages"
      true (has_anchor_msg hydrated_retry);
    let hydrated_normal =
      Keeper_acp_runtime.For_testing.hydrate_start_messages
        ~keepers_dir ~keeper_id:"k-shrink" ~prefer_handoff:false initial_messages
    in
    check bool "prefer_handoff:false does not inject anchor over existing messages"
      false (has_anchor_msg hydrated_normal);

    (* 2. Mistral Vibe operator login prep & finish succeed with Receipt.Unselected
          (never failing on Client.publish because Vibe uses host OS keyring). *)
    let () =
      Eio_main.run (fun _env ->
        ignore
          (Runtime_account_access.publish_host_tool
             ~base_path
             ~config_dir:(Some (Filename.concat base_path "config"))
           : (unit, string * string list) result))
    in
    let runtime_root = Filename.concat base_path "runtime-root" in
    let home =
      match
        Runtime_setup_login_client.prepare
          ~browser:Runtime_setup_login_client.host_browser
          ~runtime_root
          ~account_id:"vibe-op-login-1"
          ~client:Runtime_setup_login_client.Mistral_vibe
          ~existing:None
      with
      | Ok h -> h
      | Error detail -> failf "Mistral_vibe prepare failed: %s" detail
    in
    let owner = Server_setup_account_login.Operator { actor = "admin" } in
    (match
       Server_setup_account_login.For_testing.initial_account_for_login
         owner
         Runtime_setup_login_client.Mistral_vibe
         None
         ~base_path
         ~integration_id:"vibe_acp"
         ~cli_path:"vibe-acp"
         home
     with
     | Ok Runtime_setup_login_receipt.Keyring_host -> ()
     | Ok (Published _ | Linked | Unselected) -> fail "expected Keyring_host for Mistral_vibe operator initial account"
     | Error err -> failf "Mistral_vibe operator initial account failed: %s" err);
    (match
       Server_setup_account_login.For_testing.finish_login
         owner
         ~client:Runtime_setup_login_client.Mistral_vibe
         ~base_path
         ~integration_id:"vibe_acp"
         ~cli_path:"vibe-acp"
         ~login_id:"vibe-op-login-1"
         home
     with
     | Ok Runtime_setup_login_receipt.Keyring_host -> ()
     | Ok (Published _ | Linked | Unselected) -> fail "expected Keyring_host for Mistral_vibe operator finish_login"
     | Error err -> failf "Mistral_vibe operator finish_login failed: %s" err))
;;

let test_typed_tool_call_classification_and_schema_boundary () =
  let tmp = Filename.temp_dir "acp-schema-boundary-" "" in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let canonical_tmp = Unix.realpath tmp in
    let schema_dir = Filename.concat canonical_tmp "antigravity-cli/mcp/masc" in
    let schema_subdir = Filename.concat schema_dir "nested" in
    let config_dir = Filename.concat canonical_tmp "config" in
    let outside_dir = Filename.concat canonical_tmp "outside" in
    Fs_compat.mkdir_p schema_subdir;
    Fs_compat.mkdir_p config_dir;
    Fs_compat.mkdir_p outside_dir;
    let valid_schema = Filename.concat schema_dir "masc_probe_ping.json" in
    let unpinned_schema = Filename.concat schema_dir "unpinned_tool.json" in
    let nested_schema = Filename.concat schema_subdir "masc_probe_ping.json" in
    let valid_instructions = Filename.concat schema_dir "instructions.md" in
    let invalid_txt = Filename.concat schema_dir "notes.txt" in
    let secret_cfg = Filename.concat config_dir "mcp_config.json" in
    let secret_token = Filename.concat canonical_tmp "antigravity-cli/antigravity-oauth-token" in
    let outside_json = Filename.concat outside_dir "secret.json" in
    let escaping_link = Filename.concat schema_dir "escape.json" in
    Out_channel.with_open_text valid_schema (fun oc -> output_string oc "{}");
    Out_channel.with_open_text unpinned_schema (fun oc -> output_string oc "{}");
    Out_channel.with_open_text nested_schema (fun oc -> output_string oc "{}");
    Out_channel.with_open_text valid_instructions (fun oc -> output_string oc "# docs");
    Out_channel.with_open_text invalid_txt (fun oc -> output_string oc "nope");
    Out_channel.with_open_text secret_cfg (fun oc -> output_string oc "{}");
    Out_channel.with_open_text secret_token (fun oc -> output_string oc "secret");
    Out_channel.with_open_text outside_json (fun oc -> output_string oc "{}");
    Unix.symlink outside_json escaping_link;
    let managed_schema_root = "masc", schema_dir in
    let policy =
      Runtime_acp_client.Allow_masc_mcp_only
        { mcp_server_name = "masc"
        ; allowed_tool_names = [ "masc_probe_ping"; "keeper_skill" ]
        }
    in
    let classify =
      Runtime_acp_client.For_testing.classify_tool_call_json
        ~driver:Antigravity
        ~managed_schema_root
        ~mcp_server_name:"masc"
    in
    let allowed json =
      Runtime_acp_client.should_allow_tool_call ~policy (classify json)
    in
    (* Antigravity 1.5.14 structured call_mcp_tool wire payload (kind="execute") *)
    let agy_mcp_call =
      `Assoc
        [ "toolCallId", `String "call_agy_1"
        ; "name", `String "call_mcp_tool"
        ; "kind", `String "execute"
        ; "title", `String "MCP Tool masc_probe_ping"
        ; ( "rawInput"
          , `Assoc
              [ "ServerName", `String "masc"
              ; "ToolName", `String "masc_probe_ping"
              ; "Arguments", `Assoc [ "nonce", `String "n1" ]
              ] )
        ]
    in
    (match classify agy_mcp_call with
     | Runtime_acp_client.Mcp_tool
         { server = Runtime_acp_client.Explicit_server "masc"
         ; tool_name = "masc_probe_ping"
         } -> ()
     | _ -> fail "expected Antigravity call_mcp_tool to classify as Explicit_server masc");
    check bool "allows Antigravity structured call_mcp_tool under Allow_masc_mcp_only" true
      (allowed agy_mcp_call);
    (* Foreign server / unpinned tool / missing rawInput all FAIL CLOSED *)
    check bool "denies call_mcp_tool with foreign ServerName" false
      (allowed
         (`Assoc
            [ "name", `String "call_mcp_tool"
            ; "kind", `String "execute"
            ; "title", `String "MCP Tool masc_probe_ping"
            ; ( "rawInput"
              , `Assoc [ "ServerName", `String "evil"; "ToolName", `String "masc_probe_ping" ] )
            ]));
    check bool "denies call_mcp_tool with unpinned ToolName" false
      (allowed
         (`Assoc
            [ "name", `String "call_mcp_tool"
            ; "kind", `String "execute"
            ; ( "rawInput"
              , `Assoc [ "ServerName", `String "masc"; "ToolName", `String "unpinned_tool" ] )
            ]));
    check bool "denies display-title-only MCP Tool without structured rawInput" false
      (allowed
         (`Assoc
            [ "name", `String "call_mcp_tool"
            ; "kind", `String "execute"
            ; "title", `String "MCP Tool masc_probe_ping"
            ]));
    (* Antigravity lazy MCP schema reads inside managed_schema_root *)
    let read_call ?(kind = "read") ?(locs = []) path_arg =
      `Assoc
        [ "name", `String "read_file"
        ; "kind", `String kind
        ; "title", `String ("File " ^ path_arg)
        ; "locations", `List (List.map (fun p -> `Assoc [ "path", `String p ]) locs)
        ; "rawInput", `Assoc [ "Path", `String path_arg ]
        ]
    in
    check bool "allows read_file of valid .json inside managed schema dir" true
      (allowed (read_call ~locs:[ valid_schema ] valid_schema));
    check bool "denies read_file of unpinned tool .json inside managed schema dir" false
      (allowed (read_call unpinned_schema));
    check bool "allows read_file of instructions.md inside managed schema dir" true
      (allowed (read_call valid_instructions));
    check bool "denies managed schema read when allowed_tool_names is empty" false
      (Runtime_acp_client.should_allow_tool_call
         ~policy:(Runtime_acp_client.Allow_masc_mcp_only { mcp_server_name = "masc"; allowed_tool_names = [] })
         (classify (read_call valid_schema)));
    check bool "denies read_file of non-.json file inside managed schema dir" false
      (allowed (read_call invalid_txt));
    check bool "denies read_file of config/mcp_config.json" false
      (allowed (read_call secret_cfg));
    check bool "denies read_file of antigravity-oauth-token" false
      (allowed (read_call secret_token));
    check bool "denies read_file traversal into config/mcp_config.json" false
      (allowed (read_call (Filename.concat schema_dir "../../../config/mcp_config.json")));
    check bool "denies read_file through escaping symlink inside schema dir" false
      (allowed (read_call escaping_link));
    check bool "denies mixed valid location + outside rawInput.Path" false
      (allowed (read_call ~locs:[ valid_schema ] outside_json));
    check bool "denies multi-location mixing pinned + unpinned schemas" false
      (allowed (read_call ~locs:[ valid_schema; unpinned_schema ] valid_schema));
    check bool "denies multi-key rawInput with secondary outside file_path" false
      (allowed
         (`Assoc
            [ "name", `String "read_file"
            ; "kind", `String "read"
            ; "locations", `List [ `Assoc [ "path", `String valid_schema ] ]
            ; ( "rawInput"
              , `Assoc [ "Path", `String valid_schema; "file_path", `String outside_json ] )
            ]));
    check bool "denies non-empty rawInput with unrecognized path key" false
      (allowed
         (`Assoc
            [ "name", `String "read_file"
            ; "kind", `String "read"
            ; "locations", `List [ `Assoc [ "path", `String valid_schema ] ]
            ; "rawInput", `Assoc [ "custom_key", `String outside_json ]
            ]));
    check bool "denies schema read in nested subdirectory under schema_dir" false
      (allowed (read_call nested_schema));
    check bool "denies edit kind targeting managed schema file" false
      (allowed (read_call ~kind:"edit" valid_schema));
    (* Foreign _meta.server_name without _meta.tool_name must NOT fall through to Implicit_mcp_kind *)
    check bool "denies foreign _meta.server_name even when kind=mcp and name matches pinned tool" false
      (allowed
         (`Assoc
            [ "name", `String "masc_probe_ping"
            ; "kind", `String "mcp"
            ; "_meta", `Assoc [ "server_name", `String "evil" ]
            ]));
    (* Mistral Vibe 3.1.0 structured _meta.tool_name: allowed on Mistral_vibe, denied cross-driver on Antigravity *)
    let vibe_meta_payload =
      `Assoc
        [ "toolCallId", `String "effect-1"
        ; "title", `String "mcp_masc.masc_probe_ping"
        ; "kind", `String "other"
        ; "_meta", `Assoc [ "tool_name", `String "mcp_masc.masc_probe_ping" ]
        ]
    in
    let vibe_classify =
      Runtime_acp_client.For_testing.classify_tool_call_json
        ~driver:Mistral_vibe
        ~mcp_server_name:"masc"
    in
    check bool "allows Vibe _meta.tool_name mcp_masc.masc_probe_ping under Mistral_vibe" true
      (Runtime_acp_client.should_allow_tool_call ~policy (vibe_classify vibe_meta_payload));
    check bool "denies Vibe mcp_masc.masc_probe_ping cross-driver under Antigravity" false
      (allowed vibe_meta_payload);
    (* Declarative acp_settings_json SSOT *)
    (match Runtime_antigravity_home.acp_settings_json ~mcp_server_name:"masc" ~gemini_dir:canonical_tmp () with
     | Error err -> failf "acp_settings_json failed: %s" (Runtime_antigravity_home.error_to_string err)
     | Ok json ->
       let open Yojson.Safe.Util in
       let allow_list = json |> member "permissions" |> member "allow" |> to_list |> List.map to_string in
       let deny_list = json |> member "permissions" |> member "deny" |> to_list |> List.map to_string in
       check bool "settings allow includes mcp(masc/*)" true (List.mem "mcp(masc/*)" allow_list);
       check bool "settings allow includes schema dir" true
         (List.mem ("read_file(" ^ schema_dir ^ ")") allow_list);
       check bool "settings deny includes config dir" true
         (List.mem ("read_file(" ^ config_dir ^ ")") deny_list);
       check bool "settings deny includes oauth token" true
         (List.mem ("read_file(" ^ secret_token ^ ")") deny_list);
       check bool "settings deny includes read_url(*)" true (List.mem "read_url(*)" deny_list);
       check bool "settings deny includes execute_url(*)" true (List.mem "execute_url(*)" deny_list));
    check bool "acp_settings_json rejects pattern syntax in gemini_dir" true
      (Result.is_error
         (Runtime_antigravity_home.acp_settings_json ~mcp_server_name:"masc" ~gemini_dir:"/tmp/bad*dir" ()));
    check bool "acp_settings_json rejects relative gemini_dir" true
      (Result.is_error
         (Runtime_antigravity_home.acp_settings_json ~mcp_server_name:"masc" ~gemini_dir:"relative/dir" ()));
    check bool "acp_settings_json rejects traversal mcp_server_name" true
      (Result.is_error
         (Runtime_antigravity_home.acp_settings_json ~mcp_server_name:"../evil" ~gemini_dir:canonical_tmp ()));
    (* Kimi & Vibe effort config_option discovery *)
    let vibe_thinking_opt : Runtime_acp_client.config_option =
      { id = "thinking"
      ; name = "Thinking"
      ; category = Some "thinking"
      ; current_value = "high"
      ; available_values = [ "off"; "high" ]
      }
    in
    check (option string) "Vibe category=thinking maps None_ -> off" (Some "off")
      (Runtime_acp_client.For_testing.resolve_effort_option_value
         ~driver:Mistral_vibe
         ~requested:Llm_provider.Reasoning_effort.None_
         ~option:vibe_thinking_opt);
    let kimi_profile = Runtime_acp_client.profile_of_driver Kimi_code in
    check (option string) "Kimi effort_config_id matches live wire id" (Some "thinking")
      kimi_profile.effort_config_id;
    let agy_profile = Runtime_acp_client.profile_of_driver Antigravity in
    check (option string) "Antigravity effort_config_id matches live wire id" (Some "thought_level")
      agy_profile.effort_config_id)
;;

let test_set_model_toolcall_correlation_and_idle_liveness () =
  let tmp = Filename.temp_dir "acp-proto-hardening-" "" in
  let log_file = Filename.concat tmp "mock_events.json" in
  let settings_copy = Filename.concat tmp "observed_settings.json" in
  let mock_script = Filename.concat tmp "mock_proto_acp.py" in
  let script_body =
    Printf.sprintf
      {|#!/usr/bin/env python3
import json, os, sys, time

gdir = ""
for i, a in enumerate(sys.argv):
    if a == "--gemini-dir" and i + 1 < len(sys.argv):
        gdir = sys.argv[i + 1]
if gdir:
    sp = os.path.join(gdir, "antigravity-cli", "settings.json")
    if os.path.exists(sp):
        with open(sp, "r") as f:
            data = f.read()
        with open(%S, "w") as out:
            out.write(data)

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

state = {"set_models": [], "set_config_options": [], "perm_outcomes": {}, "cancelled": 0}
def flush_state():
    tmp_path = %S + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(state, f)
    os.replace(tmp_path, %S)

pending_perm_prompt = None
expected_perms = set()
session_counter = 0

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if "method" in msg:
        m = msg["method"]
        req_id = msg.get("id")
        params = msg.get("params", {})
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": True,
                    "sessionCapabilities": {
                        "resume": {},
                        "close": False,
                        "additionalDirectories": {}
                    }
                }
            }})
        elif m == "session/new":
            session_counter += 1
            sid = "sess-proto" if session_counter == 1 else f"sess-proto-{session_counter}"
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "sessionId": sid,
                "models": {
                    "currentModelId": "gemini-4-neon-high",
                    "availableModels": [
                        {"modelId": "gemini-4-neon-high"},
                        {"modelId": "gemini-4-neon-medium"}
                    ]
                },
                "configOptions": [
                    {"id": "model", "name": "Model", "category": "model", "currentValue": "gemini-4-neon",
                     "options": [{"value": "gemini-4-neon"}]},
                    {"id": "thought_level", "name": "Thought", "category": "thought_level", "currentValue": "high",
                     "options": [{"value": "low"}, {"value": "medium"}, {"value": "high"}]}
                ]
            }})
        elif m == "session/set_model":
            mid = params.get("modelId")
            sid = params.get("sessionId")
            state["set_models"].append(mid)
            flush_state()
            # First session emits config_option_update synchronously; second session omits it
            # so the client must treat pre-set_model effort current_value as stale.
            if sid == "sess-proto":
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": sid,
                    "update": {
                        "sessionUpdate": "config_option_update",
                        "configOptions": [
                            {"id": "model", "name": "Model", "category": "model", "currentValue": "gemini-4-neon",
                             "options": [{"value": "gemini-4-neon"}]},
                            {"id": "thought_level", "name": "Thought", "category": "thought_level", "currentValue": "medium",
                             "options": [{"value": "low"}, {"value": "medium"}, {"value": "high"}]}
                        ]
                    }
                }})
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif m == "session/set_config_option":
            state["set_config_options"].append((params.get("configId"), params.get("value")))
            flush_state()
            send({"jsonrpc": "2.0", "id": req_id, "result": {"configOptions": []}})
        elif m == "session/cancel":
            state["cancelled"] += 1
            flush_state()
        elif m == "session/prompt":
            text = params["prompt"][0]["text"]
            sid = params["sessionId"]
            if text == "perm-correlation":
                pending_perm_prompt = req_id
                expected_perms = {"vibe-1", "unknown-1", "agy-1"}
                # 1. ToolCallId correlation: tool_call announces Antigravity MCP identity, request_permission sends ONLY toolCallId
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": sid,
                    "update": {
                        "sessionUpdate": "tool_call",
                        "toolCallId": "effect-vibe-1",
                        "title": "mcp_masc_masc_probe_ping",
                        "kind": "other",
                        "status": "in_progress",
                        "_meta": {"tool_name": "mcp_masc_masc_probe_ping"}
                    }
                }})
                send({"jsonrpc": "2.0", "id": "vibe-1", "method": "session/request_permission", "params": {
                    "sessionId": sid,
                    "toolCall": {"toolCallId": "effect-vibe-1"},
                    "options": [
                        {"optionId": "allow_once_vibe", "kind": "allow_once"},
                        {"optionId": "reject_once_vibe", "kind": "reject_once"}
                    ]
                }})
                # 2. Bare unknown toolCallId must be DENIED
                send({"jsonrpc": "2.0", "id": "unknown-1", "method": "session/request_permission", "params": {
                    "sessionId": sid,
                    "toolCall": {"toolCallId": "effect-never-announced"},
                    "options": [
                        {"optionId": "allow_once_u", "kind": "allow_once"},
                        {"optionId": "reject_once_u", "kind": "reject_once"}
                    ]
                }})
                # 3. Antigravity 1.5.14 call_mcp_tool with kind="execute" & string JSON-RPC id
                send({"jsonrpc": "2.0", "id": "agy-1", "method": "session/request_permission", "params": {
                    "sessionId": sid,
                    "toolCall": {
                        "toolCallId": "call_agy_1",
                        "name": "call_mcp_tool",
                        "kind": "execute",
                        "title": "MCP Tool masc_probe_ping",
                        "rawInput": {"ServerName": "masc", "ToolName": "masc_probe_ping"}
                    },
                    "options": [
                        {"optionId": "allow_once_agy", "kind": "allow_once"},
                        {"optionId": "reject_once_agy", "kind": "reject_once"}
                    ]
                }})
            elif text == "active-stream":
                # Emit 4 progress updates spaced 0.15s apart (0.60s total > 0.35s idle timeout)
                for idx in range(4):
                    time.sleep(0.15)
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {
                        "sessionId": sid,
                        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chunk-{idx} "}}
                    }})
                send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
            elif text == "external-work":
                # Stay silent for 0.45s while caller brackets MASC MCP tool work via with_external_activity
                time.sleep(0.45)
                send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
            elif text == "silent-hang":
                # Deliberately stay silent; caller must timeout and send session/cancel
                pass
    else:
        rid = str(msg.get("id"))
        if rid in expected_perms:
            state["perm_outcomes"][rid] = msg.get("result", {}).get("outcome", {})
            flush_state()
            if expected_perms.issubset(state["perm_outcomes"].keys()) and pending_perm_prompt is not None:
                send({"jsonrpc": "2.0", "id": pending_perm_prompt, "result": {"stopReason": "end_turn"}})
                pending_perm_prompt = None
|}
      settings_copy
      log_file
      log_file
  in
  Out_channel.with_open_text mock_script (fun oc -> output_string oc script_body);
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr =
        Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 ()
      in
      let mcp_server : Runtime_acp_client.mcp_http_server =
        { name = "masc"; url = "http://127.0.0.1:9999/mcp"; headers = [] }
      in
      let cfg =
        { (Runtime_acp_client.default_config ~driver:Antigravity ~cwd:tmp) with
          cli_path = "python3"
        ; args = [ mock_script ]
        ; admission_timeout_s = 10.0
        }
      in
      Eio.Switch.run (fun sw ->
        let client =
          match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~config:cfg ~mcp_server () with
          | Ok c -> c
          | Error err -> failf "mock ACP start failed: %s" (Runtime_acp_client.error_to_string err)
        in
        check bool "settings.json materialized in --gemini-dir" true (Sys.file_exists settings_copy);
        let caps = Runtime_acp_client.capabilities client in
        check bool "additionalDirectories capability parsed" true caps.additional_directories;
        check bool "explicit false close capability parsed strictly as false" false caps.close_session;
        let session =
          match
            Runtime_acp_client.new_session
              client
              ~cwd:tmp
              ~model:(Runtime_acp_client.model_selection_of_string "gemini-4-neon-medium")
              ~effort:Llm_provider.Reasoning_effort.Medium
              ()
          with
          | Ok s -> s
          | Error err -> failf "new_session failed: %s" (Runtime_acp_client.error_to_string err)
        in
        check (option string) "current_model_id updated by session/set_model"
          (Some "gemini-4-neon-medium")
          session.current_model_id;
        check (list string) "available_models parsed"
          [ "gemini-4-neon-high"; "gemini-4-neon-medium" ]
          session.available_models;
        let policy =
          Runtime_acp_client.Allow_masc_mcp_only
            { mcp_server_name = "masc"; allowed_tool_names = [ "masc_probe_ping" ] }
        in
        (* 1. Permission correlation (Vibe toolCallId + Antigravity call_mcp_tool + unknown deny) *)
        (match
           Runtime_acp_client.prompt
             client
             ~session_id:session.session_id
             ~blocks:[ Runtime_acp_client.Text_block "perm-correlation" ]
             ~timeout_s:(Some 5.0)
             ~permission_policy:policy
             ()
         with
         | Ok _ -> ()
         | Error err -> failf "perm-correlation failed: %s" (Runtime_acp_client.error_to_string err));
        let open Yojson.Safe.Util in
        let state = Yojson.Safe.from_file log_file in
        check (list string) "session/set_model sent for gemini-4-neon-medium"
          [ "gemini-4-neon-medium" ]
          (state |> member "set_models" |> to_list |> List.map to_string);
        check int "no redundant set_config_option after config_option_update synced effort"
          0
          (state |> member "set_config_options" |> to_list |> List.length);
        let perms = state |> member "perm_outcomes" in
        check (option string) "Vibe bare toolCallId correlated & allowed"
          (Some "allow_once_vibe")
          (perms |> member "vibe-1" |> member "optionId" |> to_string_option);
        check (option string) "unknown bare toolCallId denied"
          (Some "reject_once_u")
          (perms |> member "unknown-1" |> member "optionId" |> to_string_option);
        check (option string) "Antigravity call_mcp_tool (kind=execute) allowed"
          (Some "allow_once_agy")
          (perms |> member "agy-1" |> member "optionId" |> to_string_option);
        (* 2. Activity-based idle liveness: active stream exceeds single-window timeout and succeeds *)
        (match
           Runtime_acp_client.prompt
             client
             ~session_id:session.session_id
             ~blocks:[ Runtime_acp_client.Text_block "active-stream" ]
             ~timeout_s:(Some 0.35)
             ~permission_policy:policy
             ()
         with
         | Ok r ->
           check string "active stream completed all chunks" "chunk-0 chunk-1 chunk-2 chunk-3 " r.text
         | Error err ->
           failf "active stream should not timeout under idle liveness: %s"
             (Runtime_acp_client.error_to_string err));
        (* 2b. with_external_activity suspends idle watchdog while MASC runs a long MCP tool *)
        let ext_res = ref None in
        Eio.Fiber.both
          (fun () ->
             Runtime_acp_client.with_external_activity client (fun () ->
               Eio.Time.sleep clock 0.50))
          (fun () ->
             ext_res :=
               Some
                 (Runtime_acp_client.prompt
                    client
                    ~session_id:session.session_id
                    ~blocks:[ Runtime_acp_client.Text_block "external-work" ]
                    ~timeout_s:(Some 0.25)
                    ~permission_policy:policy
                    ()));
        (match !ext_res with
         | Some (Ok _) -> ()
         | Some (Error err) ->
           failf "with_external_activity should prevent idle timeout: %s"
             (Runtime_acp_client.error_to_string err)
         | None -> fail "external-work prompt did not complete");
        (* 3. True silent hang times out and emits session/cancel *)
        (match
           Runtime_acp_client.prompt
             client
             ~session_id:session.session_id
             ~blocks:[ Runtime_acp_client.Text_block "silent-hang" ]
             ~timeout_s:(Some 0.25)
             ~permission_policy:policy
             ()
         with
         | Error (Runtime_acp_client.Timeout { stage = "session/prompt"; _ }) -> ()
         | Ok _ -> fail "silent hang unexpectedly succeeded"
         | Error err ->
           failf "expected Timeout for silent hang, got %s"
             (Runtime_acp_client.error_to_string err));
        let rec wait_for_cancelled attempts =
          let count =
            try Yojson.Safe.from_file log_file |> member "cancelled" |> to_int with
            | Sys_error _ | Yojson.Json_error _ -> 0
          in
          if count >= 1 || attempts <= 0
          then count
          else (
            Eio.Time.sleep clock 0.025;
            wait_for_cancelled (attempts - 1))
        in
        check bool "session/cancel emitted on idle timeout" true (wait_for_cancelled 80 >= 1);
        (* 4. session/set_model WITHOUT preceding config_option_update must treat
              effort current_value as stale and apply explicit effort override. *)
        (match
           Runtime_acp_client.new_session
             client
             ~cwd:tmp
             ~model:(Runtime_acp_client.model_selection_of_string "gemini-4-neon-medium")
             ~effort:Llm_provider.Reasoning_effort.High
             ()
         with
         | Ok _ -> ()
         | Error err -> failf "second new_session failed: %s" (Runtime_acp_client.error_to_string err));
        let stale_state = Yojson.Safe.from_file log_file in
        let set_opts =
          stale_state
          |> member "set_config_options"
          |> to_list
          |> List.map (fun pair ->
               match to_list pair with
               | [ k; v ] -> to_string k, to_string v
               | _ -> "", "")
        in
        check (list (pair string string))
          "stale effort after set_model without config_option_update dispatches set_config_option"
          [ "thought_level", "high" ]
          set_opts;
        Runtime_acp_client.close client)))
;;

let test_keeper_typed_tool_call_effect_fencing () =
  let fence =
    Keeper_acp_runtime.For_testing.should_fence_tool_call_started
      ~mcp_server_name:"masc"
      ~allowed_tool_names:[ "masc_probe_ping"; "keeper_skill" ]
  in
  let pinned_agy_mcp =
    Runtime_acp_client.Mcp_tool
      { server = Runtime_acp_client.Explicit_server "masc"
      ; tool_name = "masc_probe_ping"
      }
  in
  let foreign_mcp =
    Runtime_acp_client.Mcp_tool
      { server = Runtime_acp_client.Explicit_server "evil"
      ; tool_name = "masc_probe_ping"
      }
  in
  let pinned_schema =
    Runtime_acp_client.Managed_mcp_schema_read
      { mcp_server_name = "masc"
      ; path = "/tmp/gdir/antigravity-cli/mcp/masc/masc_probe_ping.json"
      }
  in
  let unpinned_schema =
    Runtime_acp_client.Managed_mcp_schema_read
      { mcp_server_name = "masc"
      ; path = "/tmp/gdir/antigravity-cli/mcp/masc/unpinned.json"
      }
  in
  let native_read =
    Runtime_acp_client.Native_tool
      { name = Some "read_file"; kind = Some Tool_read; locations = [] }
  in
  let native_exec =
    Runtime_acp_client.Native_tool
      { name = Some "run_command"; kind = Some Tool_execute; locations = [] }
  in
  let pinned_implicit_mcp =
    Runtime_acp_client.Mcp_tool
      { server = Runtime_acp_client.Implicit_mcp_kind
      ; tool_name = "keeper_skill"
      }
  in
  let native_fetch =
    Runtime_acp_client.Native_tool
      { name = Some "fetch_url"; kind = Some Tool_fetch; locations = [] }
  in
  let native_switch =
    Runtime_acp_client.Native_tool
      { name = Some "switch_mode"; kind = Some Tool_switch_mode; locations = [] }
  in
  let native_unmodeled =
    Runtime_acp_client.Native_tool
      { name = Some "future_tool"; kind = Some (Tool_unknown "future"); locations = [] }
  in
  let native_unknown =
    Runtime_acp_client.Native_tool { name = Some "mystery_tool"; kind = None; locations = [] }
  in
  (* Pinned MASC MCP calls and managed schema reads NEVER falsely fence retry;
     Implicit_mcp_kind is accepted ONLY under Single_pinned_server isolation
     and fails closed (fences retry) under default Shared_or_multi_server. *)
  List.iter
    (fun posture ->
       check bool "pinned MASC MCP call does not falsely fence retry" false
         (fence ~native_posture:posture pinned_agy_mcp);
       check bool "pinned implicit-kind MASC MCP call stays unfenced under Single_pinned_server"
         false
         (fence
            ~server_isolation:(Runtime_acp_client.Single_pinned_server "masc")
            ~native_posture:posture
            pinned_implicit_mcp);
       check bool "pinned implicit-kind call fences when Single_pinned_server names a different server"
         true
         (fence
            ~server_isolation:(Runtime_acp_client.Single_pinned_server "other")
            ~native_posture:posture
            pinned_implicit_mcp);
       check bool "unqualified implicit-kind MCP call fences under default Shared_or_multi_server"
         true
         (fence ~native_posture:posture pinned_implicit_mcp);
       check bool "pinned managed MCP schema read does not falsely fence retry" false
         (fence ~native_posture:posture pinned_schema);
       check bool "foreign MCP call fences retry" true
         (fence ~native_posture:posture foreign_mcp);
       check bool "unpinned managed MCP schema read fences retry" true
         (fence ~native_posture:posture unpinned_schema))
    [ Runtime_native_tools.Native_none
    ; Runtime_native_tools.Native_read
    ; Runtime_native_tools.Native_full
    ];
  (* Native tools follow posture boundaries *)
  check bool "Native_none fences native read" true
    (fence ~native_posture:Runtime_native_tools.Native_none native_read);
  check bool "Native_read does not fence native read" false
    (fence ~native_posture:Runtime_native_tools.Native_read native_read);
  check bool "Native_read fences native execute" true
    (fence ~native_posture:Runtime_native_tools.Native_read native_exec);
  check bool "Native_read fences native fetch (egress boundary)" true
    (fence ~native_posture:Runtime_native_tools.Native_read native_fetch);
  check bool "Native_read fences native switch_mode" true
    (fence ~native_posture:Runtime_native_tools.Native_read native_switch);
  check bool "Native_read fences native Tool_unknown" true
    (fence ~native_posture:Runtime_native_tools.Native_read native_unmodeled);
  check bool "Native_read fences native tool with kind=None" true
    (fence ~native_posture:Runtime_native_tools.Native_read native_unknown);
  check bool "Native_full fences native read" true
    (fence ~native_posture:Runtime_native_tools.Native_full native_read)
;;

let test_acp_rpc_error_classification_pool_preservation_and_scopes () =
  let module Retry = Llm_provider.Retry in
  let rpc ?(code = -32000) ?data message =
    Runtime_acp_client.rpc_error ~method_name:"session/prompt" ~code ~message ~data
  in
  let refusal = function
    | Runtime_acp_client.Rpc_error { refusal; _ } -> refusal
    | _ -> fail "expected an RPC error"
  in
  let check_core label err pred =
    let core = Keeper_acp_runtime.For_testing.acp_error_to_core_error err in
    check bool (label ^ ": " ^ Agent_core.Error.to_string core) true (pred core)
  in
  let data_code value = `Assoc [ "code", `String value ] in
  let quota_err = rpc ~data:(data_code "exceeded_current_quota_error") "billing credits exhausted" in
  let quota_402_err = rpc ~code:402 "insufficient credits" in
  let resource_exhausted_quota_err =
    rpc
      ~data:
        (Yojson.Safe.from_string
           {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"reason":"QUOTA_EXCEEDED"}],"retry_after":300}}|})
      "RESOURCE_EXHAUSTED"
  in
  let resource_exhausted_transient_err = rpc ~data:(`Assoc [ "status", `String "RESOURCE_EXHAUSTED" ]) "temporary RPM cap" in
  let rate_err = rpc ~code:429 "rate limit exceeded" in
  let auth_err = rpc ~code:401 "invalid API key" in
  let authz_err = rpc ~code:403 "access denied" in
  let unavail_err = rpc ~code:503 "upstream overloaded" in
  let overflow_err = rpc ~data:(data_code "context_length_exceeded") "prompt exceeds model window" in
  let other_err = rpc "internal schema parse failure" in
  check_core "exceeded_current_quota_error -> HardQuota" quota_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.HardQuota _) -> true | _ -> false);
  check_core "402 -> HardQuota" quota_402_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.HardQuota _) -> true | _ -> false);
  check_core "RESOURCE_EXHAUSTED + QUOTA_EXCEEDED data -> HardQuota with retry_after"
    resource_exhausted_quota_err (function
    | Agent_core.Error.Provider
        (Agent_core.Llm_provider.Error.HardQuota { retry_after = Some 300.0; _ }) -> true
    | _ -> false);
  check_core "bare RESOURCE_EXHAUSTED -> RateLimit (Gemini SSOT parity)"
    resource_exhausted_transient_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.RateLimit _) -> true | _ -> false);
  check_core "429 -> RateLimit" rate_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.RateLimit _) -> true | _ -> false);
  check_core "401 -> AuthError" auth_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.AuthError _) -> true | _ -> false);
  check_core "403 -> AuthorizationError" authz_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.AuthorizationError _) -> true | _ -> false);
  check_core "503 -> ProviderUnavailable" unavail_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.ProviderUnavailable _) -> true | _ -> false);
  check_core "context_length_exceeded -> ContextOverflow" overflow_err (function
    | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _) -> true | _ -> false);
  check_core "other -> ProviderReportedError" other_err (function
    | Agent_core.Error.Provider (Agent_core.Llm_provider.Error.ProviderReportedError _) -> true | _ -> false);
  List.iter
    (fun prose ->
       let error = rpc ~code:(-32602) prose in
       check_core "invalid params stays a provider-reported error" error (function
         | Agent_core.Error.Provider (Llm_provider.Error.ProviderReportedError _) -> true
         | _ -> false);
       check bool "description does not change provider standing" true
         (Fusion_official_client.For_testing.acp_standing_of_error ~now:100.0 error
          |> Option.is_none);
       check bool "description does not change session recovery" true
         (Keeper_acp_runtime.For_testing.recovery_failure_of_acp_error error
          = Keeper_official_client_session_store.Provider_rejected))
    [ "invalid filter; the previous call returned context_length_exceeded"
    ; "HTTP 402 was a prior response; this request has an invalid filter"
    ; "reason=QUOTA_EXHAUSTED is an invalid filter value"
    ; {|invalid filter {"error":{"code":"context_length_exceeded"}}|}
    ];
  List.iter
    (fun vendor_code ->
       let error = rpc ~code:(-32602) ~data:(data_code vendor_code) "invalid parameter" in
       check_core ("an unscoped numeric code keeps the RPC refusal: " ^ vendor_code) error
         (function
           | Agent_core.Error.Provider (Llm_provider.Error.ProviderReportedError _) -> true
           | _ -> false))
    [ "1308"; "1261" ];
  (match refusal (rpc ~code:429 ~data:(data_code "1308") "request throttled") with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "RPC status 429 remains a rate limit without scoped quota evidence");
  (* Closed jsonrpc_code_of_int partitioning: negative JSON-RPC codes never overlap HTTP 400..599 *)
  check bool "-32700 -> Jsonrpc_parse_error" true
    (Runtime_acp_client.jsonrpc_code_of_int (-32700) = Runtime_acp_client.Jsonrpc_parse_error);
  check bool "-32602 -> Jsonrpc_invalid_params" true
    (Runtime_acp_client.jsonrpc_code_of_int (-32602) = Runtime_acp_client.Jsonrpc_invalid_params);
  check bool "-32000 -> Jsonrpc_server_error" true
    (Runtime_acp_client.jsonrpc_code_of_int (-32000) = Runtime_acp_client.Jsonrpc_server_error (-32000));
  check bool "429 -> Jsonrpc_http_status 429" true
    (Runtime_acp_client.jsonrpc_code_of_int 429 = Runtime_acp_client.Jsonrpc_http_status 429);
  check bool "1113 -> Jsonrpc_other_code 1113" true
    (Runtime_acp_client.jsonrpc_code_of_int 1113 = Runtime_acp_client.Jsonrpc_other_code 1113);
  (* Secret redaction & UTF-8-safe bounded truncation of error.data in error_to_string *)
  let secret_data =
    `Assoc
      [ "authorization", `String "Bearer secret-jwt-value-xyz"
      ; "api_key", `String "opaque-vendor-secret-999"
      ; "note", `String (String.concat "" (List.init 200 (fun _ -> "한")))
      ]
  in
  let rendered = Runtime_acp_client.error_to_string (rpc ~data:secret_data "failed") in
  let has_sub ~needle s =
    let n_len = String.length needle in
    let s_len = String.length s in
    let rec loop i =
      if i + n_len > s_len
      then false
      else if String.sub s i n_len = needle
      then true
      else loop (i + 1)
    in
    loop 0
  in
  check bool "error_to_string redacts JSON authorization key" false
    (has_sub ~needle:"secret-jwt-value-xyz" rendered);
  check bool "error_to_string redacts JSON api_key key" false
    (has_sub ~needle:"opaque-vendor-secret-999" rendered);
  check bool "error_to_string bounds long multi-byte data summary" true
    (String.length rendered <= 600);
  let stringified_secret_rendered =
    Runtime_acp_client.error_to_string
      (rpc ~data:(`String {|{"api_key":"opaque-stringified-secret-111","code":429}|}) "failed")
  in
  check bool "stringified JSON error.data redacts api_key" false
    (has_sub ~needle:"opaque-stringified-secret-111" stringified_secret_rendered);
  let malformed_json_secret_rendered =
    Runtime_acp_client.error_to_string
      (rpc ~data:(`String {|{"api_key":"sk-ant-truncated-secret-222"|}) "failed")
  in
  check bool "malformed JSON error.data does not leak raw secret" false
    (has_sub ~needle:"sk-ant-truncated-secret-222" malformed_json_secret_rendered);
  let tpm_429_code = rpc ~code:429 ~data:(data_code "request_too_large") "TPM exceeded" in
  (match refusal tpm_429_code with
   | Some (Retry.Signal_rate_limited _) -> ()
   | _ -> fail "RPC status 429 takes precedence over an overflow code in data");
  check bool "429 TPM preserves persistent ACP child" false
    (Keeper_acp_runtime.For_testing.should_evict_persistent_child_on_error tpm_429_code);
  (match refusal (rpc ~code:413 ~data:(data_code "context_length_exceeded") "too large") with
   | Some (Retry.Signal_request_body_too_large _) -> ()
   | _ -> fail "RPC status 413 denotes a request-body refusal");
  let retry_info_payload =
    {|{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"39s"}]}}|}
  in
  (match refusal (rpc ~data:(`String retry_info_payload) "failed") with
   | Some (Retry.Signal_rate_limited { retry_after = Some 39.0; _ }) -> ()
   | _ -> fail "complete JSON in string-valued data carries the provider's retry delay");
  check bool "a diagnostic prefix makes string-valued data plain text" true
    (refusal (rpc ~data:(`String ("prior response: " ^ retry_info_payload)) "failed")
     |> Option.is_none);
  let status = `Assoc [ "code", `Int 429 ] in
  let quota = `Assoc [ "error", data_code "insufficient_quota" ] in
  let retry_after = `Assoc [ "retryAfter", `Int 45 ] in
  List.iter (fun code ->
    List.iter (fun entries ->
      match refusal (rpc ~code ~data:(`List entries) "failed") with
      | Some (Retry.Signal_hard_quota { retry_after = Some 45.; _ }) -> ()
      | _ -> fail "structured quota and a separate delay must survive status-only array entries")
      [ [status; quota; retry_after]; [retry_after; quota; status] ])
    [429; -32603];
  let retry_info = `Assoc [ "@type", `String "type.googleapis.com/google.rpc.RetryInfo";
                             "retryDelay", `String "39s" ] in
  let resource_exhausted = `Assoc [ "error", `Assoc [ "code", `Int 429;
                                                      "status", `String "RESOURCE_EXHAUSTED" ] ] in
  List.iter (fun entries ->
    match refusal (rpc ~data:(`List entries) "failed") with
    | Some (Retry.Signal_rate_limited { retry_after = Some 39.; _ }) -> ()
    | _ -> fail "a separate Google RetryInfo record supplies the delay")
    [[resource_exhausted; retry_info]; [retry_info; resource_exhausted]];
  (match refusal (rpc ~code:401 ~data:(`List [status; quota; retry_after]) "failed") with
   | Some (Retry.Signal_auth_error _) -> ()
   | _ -> fail "the RPC HTTP status still owns authentication classification");
  check bool "a retry detail or diagnostic alone cannot establish a refusal" true
    (Option.is_none (refusal (rpc ~data:(`List [retry_info;
       `Assoc [ "message", `String "previous HTTP 429 insufficient_quota" ]]) "failed")));
  (* Pool preservation: quota / rate-limit RPC refusals must NOT evict healthy persistent child *)
  check bool "quota refusal preserves persistent ACP child" false
    (Keeper_acp_runtime.For_testing.should_evict_persistent_child_on_error quota_err);
  check bool "rate-limit refusal preserves persistent ACP child" false
    (Keeper_acp_runtime.For_testing.should_evict_persistent_child_on_error rate_err);
  check bool "auth failure evicts persistent ACP child" true
    (Keeper_acp_runtime.For_testing.should_evict_persistent_child_on_error auth_err);
  check bool "timeout evicts persistent ACP child" true
    (Keeper_acp_runtime.For_testing.should_evict_persistent_child_on_error
       (Runtime_acp_client.Timeout { stage = "session/prompt"; timeout_s = 120.0 }));
  (* Fusion official client standing classification for ACP & Antigravity *)
  let check_standing label obs pred =
    check bool label true (pred obs)
  in
  check_standing "ACP quota standing -> Hard_quota with resets_at from retry_after"
    (Fusion_official_client.For_testing.acp_standing_of_error ~now:100.0 resource_exhausted_quota_err)
    (function
      | Some (Runtime_candidate_standing.Hard_quota { resets_at = Some 400.0; _ }) -> true
      | _ -> false);
  check_standing "ACP rate standing -> Rate_limited"
    (Fusion_official_client.For_testing.acp_standing_of_error ~now:100.0 rate_err)
    (function Some (Runtime_candidate_standing.Rate_limited _) -> true | _ -> false);
  check_standing "ACP 401 standing -> Credential_refused"
    (Fusion_official_client.For_testing.acp_standing_of_error ~now:100.0 auth_err)
    (function Some (Runtime_candidate_standing.Credential_refused _) -> true | _ -> false);
  check_standing "ACP other standing -> None"
    (Fusion_official_client.For_testing.acp_standing_of_error ~now:100.0 other_err)
    Option.is_none;
  check_standing "Antigravity quota standing -> Hard_quota"
    (Fusion_official_client.For_testing.antigravity_standing_of_error ~now:100.0
       (Runtime_antigravity.Turn_failed "RESOURCE_EXHAUSTED: QUOTA_EXCEEDED"))
    (function Some (Runtime_candidate_standing.Hard_quota _) -> true | _ -> false);
  check_standing "Antigravity bare RESOURCE_EXHAUSTED -> Rate_limited"
    (Fusion_official_client.For_testing.antigravity_standing_of_error ~now:100.0
       (Runtime_antigravity.Turn_failed "RESOURCE_EXHAUSTED: slow down"))
    (function Some (Runtime_candidate_standing.Rate_limited _) -> true | _ -> false);
  check_standing "Antigravity 429 standing -> Rate_limited"
    (Fusion_official_client.For_testing.antigravity_standing_of_error ~now:100.0
       (Runtime_antigravity.Turn_failed "HTTP 429 rate limit exceeded"))
    (function Some (Runtime_candidate_standing.Rate_limited _) -> true | _ -> false);
  check_standing "Antigravity 401 standing -> Credential_refused"
    (Fusion_official_client.For_testing.antigravity_standing_of_error ~now:100.0
       (Runtime_antigravity.Turn_failed "HTTP 401 unauthorized"))
    (function Some (Runtime_candidate_standing.Credential_refused _) -> true | _ -> false);
  (* Per-driver ACP quota scopes via Runtime_quota_window.scope_of_acp_driver *)
  let source =
    {|
[providers.agy_scope]
protocol = "acp"
driver = "antigravity"
command = "agy"
args = ["acp"]
is-non-interactive = true

[providers.kimi_scope]
protocol = "acp"
driver = "kimi_code"
command = "kimi"
args = ["acp"]
is-non-interactive = true

[providers.vibe_scope]
protocol = "acp"
driver = "mistral_vibe"
command = "vibe-acp"
is-non-interactive = true

[models.m]
api-name = "m"
max-context = 100000

[agy_scope.m]
[kimi_scope.m]
[vibe_scope.m]

[runtime]
default = "agy_scope.m"
|}
  in
  let cfg = Result.get_ok (Runtime_toml.parse_string source) in
  let runtimes, _ = Runtime_instance.partition_bindings cfg cfg.bindings in
  let scope_of id =
    let rt = List.find (fun (r : Runtime_instance.t) -> String.equal r.id id) runtimes in
    Runtime_instance.quota_scope_of_runtime rt
  in
  check bool "agy uses acp_driver scope" true
    (Runtime_quota_window.scope_equal
       (scope_of "agy_scope.m")
       (Runtime_quota_window.scope_of_acp_driver ~driver:"antigravity"));
  check bool "kimi uses acp_driver scope" true
    (Runtime_quota_window.scope_equal
       (scope_of "kimi_scope.m")
       (Runtime_quota_window.scope_of_acp_driver ~driver:"kimi_code"));
  check bool "vibe uses acp_driver scope" true
    (Runtime_quota_window.scope_equal
       (scope_of "vibe_scope.m")
       (Runtime_quota_window.scope_of_acp_driver ~driver:"mistral_vibe"));
  check bool "kimi and vibe ACP scopes are distinct" false
    (Runtime_quota_window.scope_equal (scope_of "kimi_scope.m") (scope_of "vibe_scope.m"))
;;

let test_acp_v1_image_negotiation_and_validation () =
  let valid_png_b64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  in
  let image_blocks =
    [ Runtime_acp_client.Text_block "inspect"
    ; Runtime_acp_client.Image_block { mime_type = "image/png"; base64_data = valid_png_b64 }
    ]
  in
  let no_image_caps : Runtime_acp_client.agent_capabilities =
    { load_session = false
    ; resume_session = false
    ; close_session = false
    ; additional_directories = false
    ; image_prompt = false
    ; embedded_context = false
    ; mcp_http = false
    ; antigravity_system_prompt_append = false
    ; antigravity_tier = None
    }
  in
  let with_image_caps = { no_image_caps with image_prompt = true } in
  (* When server advertises image_prompt = false, Image_block is refused before RPC *)
  (match
     Runtime_acp_client.validate_prompt_blocks
       ~driver:Mistral_vibe ~capabilities:no_image_caps image_blocks
   with
   | Error (Runtime_acp_client.Invalid_config detail) ->
     check string "detail names exact image_input_unsupported reason"
       (Runtime_acp_client.image_input_unsupported_detail Mistral_vibe)
       detail
   | Ok () -> fail "image_prompt=false must reject Image_block"
   | Error err -> failf "unexpected error: %s" (Runtime_acp_client.error_to_string err));
  (* Text-only blocks still pass when image_prompt = false *)
  check bool "text-only passes when image_prompt=false" true
    (Result.is_ok
       (Runtime_acp_client.validate_prompt_blocks
          ~driver:Mistral_vibe ~capabilities:no_image_caps
          [ Runtime_acp_client.Text_block "hello" ]));
  (* Valid PNG passes when image_prompt = true *)
  check bool "valid PNG passes when image_prompt=true" true
    (Result.is_ok
       (Runtime_acp_client.validate_prompt_blocks
          ~driver:Kimi_code ~capabilities:with_image_caps image_blocks));
  (* Unsupported MIME and corrupt base64 fail closed before stdio JSON-RPC *)
  check bool "unsupported MIME rejected before RPC" true
    (Result.is_error
       (Runtime_acp_client.validate_prompt_blocks
          ~driver:Kimi_code ~capabilities:with_image_caps
          [ Runtime_acp_client.Image_block { mime_type = "image/svg+xml"; base64_data = valid_png_b64 } ]));
  check bool "invalid base64 rejected before RPC" true
    (Result.is_error
       (Runtime_acp_client.validate_prompt_blocks
          ~driver:Kimi_code ~capabilities:with_image_caps
          [ Runtime_acp_client.Image_block { mime_type = "image/png"; base64_data = "!!!not-base64!!!" } ]))
;;

let test_antigravity_acp_mcp_permission_and_call_mcp_tool () =
  let mcp_only =
    Runtime_acp_client.Allow_masc_mcp_only
      { mcp_server_name = "masc"
      ; allowed_tool_names = [ "keeper_memory_search"; "masc_probe_ping" ]
      }
  in
  let allow = Runtime_acp_client.For_testing.should_allow_permission ~driver:Antigravity in
  let classify =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Antigravity
      ~mcp_server_name:"masc"
  in
  let allowed_json json = Runtime_acp_client.should_allow_tool_call ~policy:mcp_only (classify json) in
  (* Live agy acp format: mcp(masc/<tool_name>) across None/mcp/other/execute kinds *)
  List.iter
    (fun kind ->
       check bool "allows agy mcp(masc/keeper_memory_search)" true
         (allow ~policy:mcp_only ~title:"mcp(masc/keeper_memory_search)" ~kind))
    [ None
    ; Some Runtime_acp_client.Tool_vendor_mcp
    ; Some Runtime_acp_client.Tool_other
    ; Some Runtime_acp_client.Tool_execute
    ];
  check bool "allows mcp(masc:keeper_memory_search)" true
    (allow ~policy:mcp_only ~title:"mcp(masc:keeper_memory_search)" ~kind:(Some Tool_other));
  check bool "allows mcp_masc_keeper_memory_search" true
    (allow ~policy:mcp_only ~title:"mcp_masc_keeper_memory_search" ~kind:(Some Tool_other));
  (* Security invariants: unpinned tools, foreign servers, edit/delete kinds, and masc_ execute remain denied *)
  check bool "denies unpinned mcp(masc/unpinned)" false
    (allow ~policy:mcp_only ~title:"mcp(masc/unpinned)" ~kind:(Some Tool_vendor_mcp));
  check bool "denies foreign mcp(github/keeper_memory_search)" false
    (allow ~policy:mcp_only ~title:"mcp(github/keeper_memory_search)" ~kind:(Some Tool_vendor_mcp));
  check bool "denies edit kind on mcp(masc/keeper_memory_search)" false
    (allow ~policy:mcp_only ~title:"mcp(masc/keeper_memory_search)" ~kind:(Some Tool_edit));
  check bool "denies native execute masc_masc_probe_ping" false
    (allow ~policy:mcp_only ~title:"masc_masc_probe_ping" ~kind:(Some Tool_execute));
  check bool "denies native execute mcp_masc_keeper_memory_search" false
    (allow ~policy:mcp_only ~title:"mcp_masc_keeper_memory_search" ~kind:(Some Tool_execute));
  (* Cross-driver check: call_mcp_tool wrapper is rejected under Kimi_code and Mistral_vibe *)
  let vibe_classify =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Mistral_vibe
      ~mcp_server_name:"masc"
  in
  let kimi_classify =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Kimi_code
      ~mcp_server_name:"masc"
  in
  let call_wrapper =
    `Assoc
      [ "_meta", `Assoc [ "tool_name", `String "call_mcp_tool" ]
      ; "rawInput", `Assoc [ "server_name", `String "masc"; "tool_name", `String "keeper_memory_search" ]
      ]
  in
  check bool "call_mcp_tool wrapper rejected under Mistral_vibe" false
    (Runtime_acp_client.should_allow_tool_call ~policy:mcp_only (vibe_classify call_wrapper));
  check bool "call_mcp_tool wrapper rejected under Kimi_code" false
    (Runtime_acp_client.should_allow_tool_call ~policy:mcp_only (kimi_classify call_wrapper));
  (* call_mcp_tool wrapper via _meta.tool_name with rawInput extracts exact server/tool identity *)
  let wrapped_allowed =
    `Assoc
      [ "_meta", `Assoc [ "tool_name", `String "call_mcp_tool" ]
      ; "rawInput", `Assoc [ "server_name", `String "masc"; "tool_name", `String "keeper_memory_search" ]
      ]
  in
  (match classify wrapped_allowed with
   | Runtime_acp_client.Mcp_tool
       { server = Runtime_acp_client.Explicit_server "masc"
       ; tool_name = "keeper_memory_search"
       } -> ()
   | _ -> fail "expected _meta.tool_name=call_mcp_tool to classify as Explicit_server masc");
  check bool "synthesized call_mcp_tool is allowed" true (allowed_json wrapped_allowed);
  let wrapped_alt_keys =
    `Assoc
      [ "_meta", `Assoc [ "tool_name", `String "call_mcp_tool" ]
      ; "kind", `String "execute"
      ; "rawInput", `Assoc [ "mcp_server", `String "masc"; "name", `String "keeper_memory_search" ]
      ]
  in
  check bool "call_mcp_tool with mcp_server/name keys is allowed" true (allowed_json wrapped_alt_keys);
  let wrapped_foreign =
    `Assoc
      [ "_meta", `Assoc [ "tool_name", `String "call_mcp_tool" ]
      ; "rawInput", `Assoc [ "server_name", `String "github"; "tool_name", `String "delete_repo" ]
      ]
  in
  check bool "foreign call_mcp_tool is denied" false (allowed_json wrapped_foreign);
  (* Whitespace-only _meta.tool_name falls through cleanly to title *)
  let blank_meta =
    `Assoc
      [ "_meta", `Assoc [ "tool_name", `String "   " ]
      ; "title", `String "mcp(masc/keeper_memory_search)"
      ]
  in
  (match classify blank_meta with
   | Runtime_acp_client.Mcp_tool
       { server = Runtime_acp_client.Explicit_server "masc"
       ; tool_name = "keeper_memory_search"
       } -> ()
   | _ -> fail "expected whitespace-only _meta.tool_name to fall through to mcp(masc/...) title");
  check bool "whitespace-only _meta.tool_name falls through to allowed mcp(masc/...)" true
    (allowed_json blank_meta);
  (* choose_permission_option ~allow:true selects Allow_once and never escalates to Allow_always *)
  check (option string) "prefers allow_once over allow_always" (Some "opt_once")
    (Runtime_acp_client.For_testing.choose_permission_option ~allow:true
       [ `Assoc [ "optionId", `String "opt_always"; "kind", `String "allow_always" ]
       ; `Assoc [ "optionId", `String "opt_once"; "kind", `String "allow_once" ]
       ]);
  check (option string) "refuses allow_always escalation when allow_once absent" None
    (Runtime_acp_client.For_testing.choose_permission_option ~allow:true
       [ `Assoc [ "optionId", `String "opt_always"; "kind", `String "allow_always" ]
       ; `Assoc [ "optionId", `String "opt_reject"; "kind", `String "reject_once" ]
       ])
;;

(* End-to-end mock ACP child covering Vibe 3.1.0's toolCallId-only
   session/request_permission wire shape (after session/update tool_call)
   and Antigravity's mcp(masc/<tool>) permission shape. *)
let test_vibe_310_tool_call_id_permission_cache_and_agy_wire () =
  let tmp = Filename.temp_dir "acp-vibe-perm-" "" in
  let mock_script = Filename.concat tmp "mock_vibe_perm.py" in
  let perm_log_file = Filename.concat tmp "perm_outcomes.json" in
  let script_body =
    Printf.sprintf
      {|import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

perm_outcomes = {}
pending_prompt_id = None
opts = [
    {"optionId": "allow_once_id", "kind": "allow_once"},
    {"optionId": "reject_once_id", "kind": "reject_once"}
]

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if "method" in msg:
        m = msg["method"]
        req_id = msg.get("id")
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": True}
            }})
        elif m == "session/new":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "sess-vibe"}})
        elif m == "session/prompt":
            pending_prompt_id = req_id
            # 1. Vibe 3.1.0 MCP tool_call with _meta.tool_name + human title, then tool_call_update without _meta,
            #    then toolCallId-only session/request_permission -> MUST allow_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-vibe-mcp-1",
                    "title": "Write keeper memory note",
                    "kind": "other",
                    "_meta": {"tool_name": "masc_keeper_memory_write", "effect_kind": "tool"}
                }
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "tc-vibe-mcp-1",
                    "title": "Awaiting approval"
                }
            }})
            send({"jsonrpc": "2.0", "id": 1001, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-vibe-mcp-1"},
                "options": opts
            }})
            # 2. Vibe 3.1.0 non-MCP bash tool (kind=execute) -> MUST reject_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-vibe-bash-2",
                    "title": "Run shell command",
                    "kind": "execute",
                    "_meta": {"tool_name": "file_system.bash", "effect_kind": "tool"}
                }
            }})
            send({"jsonrpc": "2.0", "id": 1002, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-vibe-bash-2"},
                "options": opts
            }})
            # 3. Unknown toolCallId -> MUST reject_once!
            send({"jsonrpc": "2.0", "id": 1003, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-unknown-3"},
                "options": opts
            }})
            # 4. Cross-driver Antigravity mcp(masc/keeper_memory_write) under Mistral_vibe -> MUST reject_once!
            send({"jsonrpc": "2.0", "id": 1004, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-agy-4", "title": "mcp(masc/keeper_memory_write)", "kind": "other"},
                "options": opts
            }})
            # 5. Antigravity unpinned mcp(masc/unpinned_tool) -> MUST reject_once!
            send({"jsonrpc": "2.0", "id": 1005, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-agy-5", "title": "mcp(masc/unpinned_tool)", "kind": "other"},
                "options": opts
            }})
            # 6. Adversarial spoofed display title vs cached authoritative _meta.tool_name="bash" (execute) -> MUST reject_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-spoof-6",
                    "title": "Run shell command",
                    "kind": "execute",
                    "_meta": {"tool_name": "bash"}
                }
            }})
            send({"jsonrpc": "2.0", "id": 1006, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-spoof-6", "title": "mcp(masc/keeper_memory_write)"},
                "options": opts
            }})
            # 7. Cached _meta.tool_name="masc_keeper_memory_write" wins over repeated human display title -> MUST allow_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-human-7",
                    "title": "Write keeper memory note",
                    "kind": "other",
                    "_meta": {"tool_name": "masc_keeper_memory_write"}
                }
            }})
            send({"jsonrpc": "2.0", "id": 1007, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-human-7", "title": "Write keeper memory note"},
                "options": opts
            }})
            # 8. tool_call_update attempting execute -> read kind downgrade under Allow_read_and_masc_mcp -> MUST reject_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-downgrade-8",
                    "title": "Execute command",
                    "kind": "execute",
                    "_meta": {"tool_name": "file_system.bash"}
                }
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "tc-downgrade-8",
                    "title": "read_file",
                    "kind": "read"
                }
            }})
            send({"jsonrpc": "2.0", "id": 1008, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-downgrade-8", "kind": "read"},
                "options": opts
            }})
            # 9. Sessionless session/update (no sessionId) MUST NOT populate cache -> MUST reject_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-sessionless-9",
                    "title": "Write memory",
                    "kind": "other",
                    "_meta": {"tool_name": "masc_keeper_memory_write"}
                }
            }})
            send({"jsonrpc": "2.0", "id": 1009, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-sessionless-9"},
                "options": opts
            }})
            # 10. Non-meta tool_call (title=bash, kind=execute) cannot be overwritten by spoofed mcp(...) title -> MUST reject_once!
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "tc-nonmeta-spoof-10",
                    "title": "bash",
                    "kind": "execute"
                }
            }})
            send({"jsonrpc": "2.0", "id": 1010, "method": "session/request_permission", "params": {
                "sessionId": "sess-vibe",
                "toolCall": {"toolCallId": "tc-nonmeta-spoof-10", "title": "mcp(masc/keeper_memory_write)"},
                "options": opts
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-vibe",
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "done"}}
            }})
    else:
        rid = msg.get("id")
        if rid in (1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010):
            perm_outcomes[str(rid)] = msg.get("result", {}).get("outcome", {})
            if len(perm_outcomes) == 10 and pending_prompt_id is not None:
                with open(%S, "w") as f:
                    json.dump(perm_outcomes, f)
                send({"jsonrpc": "2.0", "id": pending_prompt_id, "result": {
                    "stopReason": "end_turn",
                    "usage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}
                }})
                pending_prompt_id = None
|}
      perm_log_file
  in
  Out_channel.with_open_text mock_script (fun oc -> output_string oc script_body);
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr =
        Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 ()
      in
      let cfg =
        { (Runtime_acp_client.default_config ~driver:Mistral_vibe ~cwd:tmp) with
          cli_path = "python3"
        ; args = [ mock_script ]
        }
      in
      Eio.Switch.run (fun sw ->
        let client =
          match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~config:cfg () with
          | Ok c -> c
          | Error err -> failf "start failed: %s" (Runtime_acp_client.error_to_string err)
        in
        Fun.protect ~finally:(fun () -> Runtime_acp_client.close client) (fun () ->
          let sess =
            match Runtime_acp_client.new_session client ~cwd:tmp () with
            | Ok s -> s
            | Error err -> failf "new_session failed: %s" (Runtime_acp_client.error_to_string err)
          in
          let policy =
            Runtime_acp_client.Allow_read_and_masc_mcp
              { mcp_server_name = "masc"
              ; allowed_tool_names = [ "keeper_memory_write" ]
              }
          in
          let res =
            Runtime_acp_client.prompt
              client
              ~session_id:sess.session_id
              ~blocks:[ Runtime_acp_client.Text_block "save note" ]
              ~permission_policy:policy
              ()
          in
          (match res with
           | Ok r -> check string "prompt reply" "done" r.text
           | Error err -> failf "prompt failed: %s" (Runtime_acp_client.error_to_string err));
          let outcomes = Yojson.Safe.from_file perm_log_file in
          let option_of id =
            Yojson.Safe.Util.(outcomes |> member id |> member "optionId" |> to_string)
          in
          check string "Vibe toolCallId-only MASC MCP allowed via session/update cache"
            "allow_once_id" (option_of "1001");
          check string "Vibe non-MCP file_system.bash denied"
            "reject_once_id" (option_of "1002");
          check string "unknown toolCallId denied"
            "reject_once_id" (option_of "1003");
          check string "cross-driver agy mcp(masc/keeper_memory_write) rejected under Mistral_vibe"
            "reject_once_id" (option_of "1004");
          check string "agy acp unpinned mcp(masc/unpinned_tool) denied"
            "reject_once_id" (option_of "1005");
          check string "spoofed display title cannot override cached _meta.tool_name=bash"
            "reject_once_id" (option_of "1006");
          check string "cached _meta.tool_name wins over repeated human display title"
            "allow_once_id" (option_of "1007");
          check string "tool_call_update execute->read kind downgrade cannot bypass Allow_read_and_masc_mcp"
            "reject_once_id" (option_of "1008");
          check string "sessionless session/update is rejected from permission cache"
            "reject_once_id" (option_of "1009");
          check string "non-meta title=bash cannot be overwritten by spoofed mcp(...) title"
            "reject_once_id" (option_of "1010")))))
;;

let test_layer3_policy_mode_redaction_and_oauth_security () =
  let tmp = Filename.temp_dir ~perms:0o700 "masc-acp-l3-" "" in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let canonical_tmp = Unix.realpath tmp in
    let iso_cwd = Filename.concat canonical_tmp "iso-cwd" in
    let gemini_dir = Filename.concat canonical_tmp "gemini-dir" in
    Unix.mkdir iso_cwd 0o700;
    Unix.mkdir gemini_dir 0o700;
    (* 1. Antigravity policy with deny_read_roots + deny_writes_and_commands *)
    (match
       Runtime_antigravity_policy.acp_settings_json
         ~mcp_server_name:"masc"
         ~deny_read_roots:[ iso_cwd ]
         ~deny_writes_and_commands:true
         ~gemini_dir
         ()
     with
     | Error err ->
       failf "acp_settings_json failed: %s" (Runtime_antigravity_policy.error_to_string err)
     | Ok json ->
       let open Yojson.Safe.Util in
       let deny = json |> member "permissions" |> member "deny" |> to_list |> List.map to_string in
       check bool "denies iso_cwd reads" true (List.mem ("read_file(" ^ iso_cwd ^ ")") deny);
       check bool "denies write_file(*)" true (List.mem "write_file(*)" deny);
       check bool "denies command(*)" true (List.mem "command(*)" deny));
    (* Reject deny_read_root that shadows gemini_dir or uses dot segments *)
    check bool "rejects deny_read_root containing gemini_dir" true
      (Result.is_error
         (Runtime_antigravity_policy.acp_settings_json
            ~mcp_server_name:"masc"
            ~deny_read_roots:[ canonical_tmp ]
            ~deny_writes_and_commands:true
            ~gemini_dir
            ()));
    check bool "rejects deny_read_root with /. dot segment" true
      (Result.is_error
         (Runtime_antigravity_policy.acp_settings_json
            ~mcp_server_name:"masc"
            ~deny_read_roots:[ "/." ]
            ~deny_writes_and_commands:true
            ~gemini_dir
            ()));
    check bool "rejects deny_read_root with .. traversal segment" true
      (Result.is_error
         (Runtime_antigravity_policy.acp_settings_json
            ~mcp_server_name:"masc"
            ~deny_read_roots:[ "/tmp/sub/../.." ]
            ~deny_writes_and_commands:true
            ~gemini_dir
            ()));
    (* 2. Posture-bounded resolve_mode_for_posture prevents escalation *)
    check string "Antigravity Native_none clamps auto to default" "default"
      (Runtime_acp_client.resolve_mode_for_posture
         ~driver:Antigravity
         ~posture:Runtime_native_tools.Native_none
         ~configured_mode:(Some "auto"));
    check string "Kimi Native_none clamps yolo to default" "default"
      (Runtime_acp_client.resolve_mode_for_posture
         ~driver:Kimi_code
         ~posture:Runtime_native_tools.Native_none
         ~configured_mode:(Some "yolo"));
    check string "Kimi Native_read permits default" "default"
      (Runtime_acp_client.resolve_mode_for_posture
         ~driver:Kimi_code
         ~posture:Runtime_native_tools.Native_read
         ~configured_mode:(Some "default"));
    check string "Kimi Native_read clamps yolo to plan" "plan"
      (Runtime_acp_client.resolve_mode_for_posture
         ~driver:Kimi_code
         ~posture:Runtime_native_tools.Native_read
         ~configured_mode:(Some "yolo"));
    check string "Vibe Native_none clamps auto-approve to ask" "ask"
      (Runtime_acp_client.resolve_mode_for_posture
         ~driver:Mistral_vibe
         ~posture:Runtime_native_tools.Native_none
         ~configured_mode:(Some "auto-approve"));
    check string "Vibe Native_full accepts custom mode" "custom-full"
      (Runtime_acp_client.resolve_mode_for_posture
         ~driver:Mistral_vibe
         ~posture:Runtime_native_tools.Native_full
         ~configured_mode:(Some "custom-full"));
    (* 3. Kimi --skills-dir suppressed under Native_none *)
    let kimi_cfg =
      { (Runtime_acp_client.default_config ~driver:Kimi_code ~cwd:iso_cwd) with
        skills_dirs = [ iso_cwd ]
      }
    in
    let argv_none =
      Runtime_acp_client.For_testing.build_argv
        ~native_posture:Runtime_native_tools.Native_none
        kimi_cfg
        ~temp_gemini_dir:None
    in
    let argv_read =
      Runtime_acp_client.For_testing.build_argv
        ~native_posture:Runtime_native_tools.Native_read
        kimi_cfg
        ~temp_gemini_dir:None
    in
    check bool "Kimi suppresses --skills-dir under Native_none" false
      (List.mem "--skills-dir" argv_none);
    check bool "Kimi keeps --skills-dir under Native_read" true
      (List.mem "--skills-dir" argv_read);
    (* Antigravity clamps --dangerously-skip-permissions under Native_none & Native_read *)
    let agy_skip_cfg =
      { (Runtime_acp_client.default_config ~driver:Antigravity ~cwd:iso_cwd) with
        dangerously_skip_permissions = true
      }
    in
    check bool "Antigravity clamps skip-permissions under Native_none" false
      (List.mem "--dangerously-skip-permissions"
         (Runtime_acp_client.For_testing.build_argv
            ~native_posture:Runtime_native_tools.Native_none
            agy_skip_cfg
            ~temp_gemini_dir:None));
    check bool "Antigravity clamps skip-permissions under Native_read" false
      (List.mem "--dangerously-skip-permissions"
         (Runtime_acp_client.For_testing.build_argv
            ~native_posture:Runtime_native_tools.Native_read
            agy_skip_cfg
            ~temp_gemini_dir:None));
    check bool "Antigravity allows skip-permissions under Native_full" true
      (List.mem "--dangerously-skip-permissions"
         (Runtime_acp_client.For_testing.build_argv
            ~native_posture:Runtime_native_tools.Native_full
            agy_skip_cfg
            ~temp_gemini_dir:None));
    (* 4. UTF-8 safe suffix never splits multi-byte codepoints *)
    let korean = "AB한글CD" in
    check string "UTF-8 safe suffix advances past continuation bytes (max=4)" "CD"
      (Runtime_acp_client.For_testing.utf8_safe_suffix ~max_bytes:4 korean);
    check string "UTF-8 safe suffix preserves aligned codepoint (max=5)" "글CD"
      (Runtime_acp_client.For_testing.utf8_safe_suffix ~max_bytes:5 korean);
    (* 5. Stderr redaction scrubs both Secret_patterns and exact MCP tokens *)
    let raw_stderr =
      "err: Authorization: Bearer top-secret-bearer-token-987654 and bare top-secret-bearer-token-987654"
    in
    let redacted =
      Runtime_acp_client.For_testing.redact_stderr_text
        ~extra_secrets:[ "top-secret-bearer-token-987654" ]
        raw_stderr
    in
    let contains_sub ~needle s =
      let n = String.length needle in
      let h = String.length s in
      let rec scan i =
        if i + n > h then false
        else if String.sub s i n = needle then true
        else scan (i + 1)
      in
      n = 0 || scan 0
    in
    check bool "secret token scrubbed from stderr" false
      (contains_sub ~needle:"top-secret-bearer-token-987654" redacted);
    check bool "redaction marker present" true
      (contains_sub ~needle:"[REDACTED]" redacted);
    (* 6. CamelCase _meta usage_update parsing *)
    let usage_ev =
      `Assoc
        [ "sessionId", `String "s1"
        ; ( "update"
          , `Assoc
              [ "sessionUpdate", `String "usage_update"
              ; "used", `Int 9000
              ; "size", `Int 400000
              ; ( "_meta"
                , `Assoc
                    [ "inputTokens", `Int 4000
                    ; "outputTokens", `Int 500
                    ; "cachedReadTokens", `Int 3000
                    ; "cachedWriteTokens", `Int 250
                    ; "thoughtTokens", `Int 120
                    ; "totalTokens", `Int 7870
                    ] )
              ] )
        ]
      |> Runtime_acp_client.For_testing.parse_session_update ~driver:Antigravity
    in
    (match usage_ev with
     | Some
         (Runtime_acp_client.Usage_updated
            { used = Some 9000
            ; size = Some 400000
            ; prompt_tokens = Some 4000
            ; completion_tokens = Some 500
            ; cached_tokens = Some 3000
            ; cached_write_tokens = Some 250
            ; thought_tokens = Some 120
            ; total_tokens = Some 7870
            }) -> ()
     | _ -> fail "expected camelCase _meta Usage_updated fields");
    (* 7. Explicit oauth_source fails closed when missing, world-readable, or symlink *)
    let world_oauth = Filename.concat canonical_tmp "world-oauth.json" in
    Out_channel.with_open_text world_oauth (fun oc -> output_string oc "{}");
    Unix.chmod world_oauth 0o644;
    let symlink_oauth = Filename.concat canonical_tmp "link-oauth.json" in
    Unix.symlink world_oauth symlink_oauth;
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr = Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 () in
      let check_oauth_rejected label path =
        Eio.Switch.run (fun sw ->
          let cfg =
            { (Runtime_acp_client.default_config ~driver:Antigravity ~cwd:iso_cwd) with
              cli_path = "true"
            ; args = []
            ; oauth_source = Some path
            }
          in
          match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~fs:(Eio.Stdenv.fs env) ~config:cfg () with
          | Error (Runtime_acp_client.Invalid_config _) -> ()
          | Error err ->
            failf "%s expected Invalid_config, got %s" label (Runtime_acp_client.error_to_string err)
          | Ok client ->
            Runtime_acp_client.close client;
            failf "%s unexpectedly succeeded" label)
      in
      check_oauth_rejected "missing oauth_source" (Filename.concat canonical_tmp "missing-oauth");
      check_oauth_rejected "0644 oauth_source" world_oauth;
      check_oauth_rejected "symlink oauth_source" symlink_oauth))
;;

let test_layer3_mock_session_lifecycle_load_reconfigure_close_and_mode_fail_closed () =
  let tmp = Filename.temp_dir ~perms:0o700 "masc-acp-l3-mock-" "" in
  let canonical_tmp = Unix.realpath tmp in
  let mock_script = Filename.concat canonical_tmp "mock_acp_l3.py" in
  let log_file = Filename.concat canonical_tmp "state.json" in
  let settings_copy = Filename.concat canonical_tmp "settings_copy.json" in
  let script_body =
    Printf.sprintf
      {|import json, os, shutil, sys, time

gdir = None
argv = sys.argv[1:]
for i, a in enumerate(argv):
    if a == "--gemini-dir" and i + 1 < len(argv):
        gdir = argv[i + 1]
if gdir:
    sp = os.path.join(gdir, "antigravity-cli", "settings.json")
    if os.path.exists(sp):
        shutil.copyfile(sp, %S)

sys.stderr.write("diagnostic leak http://127.0.0.1:9999/mcp/cap-l3-token987 bearer-secret-l3-xyz987654321 done\n")
sys.stderr.flush()

state = {"set_modes": [], "set_models": [], "set_opts": [], "closed": [], "cwd": os.getcwd()}
def flush_state():
    with open(%S, "w") as f:
        json.dump(state, f)

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    m = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}
    if m == "initialize":
        flush_state()
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": True,
                "sessionCapabilities": {"resume": {}, "close": {}, "additionalDirectories": {}},
                "_meta": {"antigravity": {"systemPrompt": {"append": True}}}
            }
        }})
    elif m == "session/new":
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "sessionId": "sess-l3-1",
            "modes": {
                "currentModeId": "default",
                "availableModes": [{"id": "default"}, {"id": "auto"}]
            },
            "models": {
                "currentModelId": "model-a",
                "availableModels": [{"modelId": "model-a"}, {"modelId": "model-b"}]
            },
            "configOptions": [
                {"id": "thought_level", "name": "Thought", "category": "thought_level",
                 "currentValue": "medium", "options": [{"value": "low"}, {"value": "medium"}, {"value": "high"}]}
            ]
        }})
    elif m == "session/load":
        sid = params.get("sessionId")
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": sid,
            "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "replayed user turn"}}
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": sid,
            "update": {"sessionUpdate": "usage_update", "used": 12345, "size": 200000}
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": sid,
            "update": {"sessionUpdate": "current_mode_update", "currentModeId": "default"}
        }})
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif m == "session/set_mode":
        state["set_modes"].append(params.get("modeId"))
        flush_state()
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif m == "session/set_model":
        state["set_models"].append(params.get("modelId"))
        flush_state()
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif m == "session/set_config_option":
        state["set_opts"].append((params.get("configId"), params.get("value")))
        flush_state()
        send({"jsonrpc": "2.0", "id": req_id, "result": {"configOptions": []}})
    elif m == "session/close":
        state["closed"].append(params.get("sessionId"))
        flush_state()
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif m == "session/prompt":
        sid = params.get("sessionId")
        # Send one update WITHOUT sessionId (must be dropped) and one WITH matching sessionId
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "UNATTRIBUTED-"}}
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": sid,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ATTRIBUTED"}}
        }})
        send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
|}
      settings_copy
      log_file
  in
  Out_channel.with_open_text mock_script (fun oc -> output_string oc script_body);
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let iso_path_ref = ref "" in
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr = Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 () in
      Eio.Switch.run (fun sw ->
        let iso_cwd =
          match Runtime_acp_client.create_isolated_workspace ~sw ~prefix:"l3" () with
          | Ok d -> d
          | Error err -> failf "create_isolated_workspace failed: %s" (Runtime_acp_client.error_to_string err)
        in
        iso_path_ref := iso_cwd;
        let iso_stat = Unix.lstat iso_cwd in
        check int "isolated workspace is 0700" 0o700 (iso_stat.Unix.st_perm land 0o7777);
        let oauth_file = Filename.concat canonical_tmp "private-oauth.json" in
        Out_channel.with_open_text oauth_file (fun oc -> output_string oc "{\"access_token\":\"test\"}");
        Unix.chmod oauth_file 0o600;
        let mcp_server : Runtime_acp_client.mcp_http_server =
          { name = "masc"
          ; url = "http://127.0.0.1:9999/mcp/cap-l3-token987"
          ; headers = [ "Authorization", "Bearer bearer-secret-l3-xyz987654321" ]
          }
        in
        let cfg =
          { (Runtime_acp_client.default_config ~driver:Antigravity ~cwd:iso_cwd) with
            cli_path = "python3"
          ; args = [ mock_script ]
          ; oauth_source = Some oauth_file
          }
        in
        let client =
          match
            Runtime_acp_client.start
              ~sw
              ~proc_mgr
              ~clock
              ~fs:(Eio.Stdenv.fs env)
              ~config:cfg
              ~mcp_server
              ~native_posture:Runtime_native_tools.Native_none
              ()
          with
          | Ok c -> c
          | Error err -> failf "start failed: %s" (Runtime_acp_client.error_to_string err)
        in
        (* Verify settings.json denied iso_cwd reads + writes + commands *)
        let settings_json = Yojson.Safe.from_file settings_copy in
        let open Yojson.Safe.Util in
        let deny =
          settings_json |> member "permissions" |> member "deny" |> to_list |> List.map to_string
        in
        check bool "Native_none settings deny iso_cwd read" true
          (List.mem ("read_file(" ^ iso_cwd ^ ")") deny);
        check bool "Native_none settings deny write_file(*)" true (List.mem "write_file(*)" deny);
        check bool "Native_none settings deny command(*)" true (List.mem "command(*)" deny);
        (* Verify unsupported mode fails closed *)
        (match
           Runtime_acp_client.new_session client ~cwd:iso_cwd ~mode:"bogus-mode" ()
         with
         | Error (Runtime_acp_client.Protocol_error { stage = "session/set_mode"; _ }) -> ()
         | Error err ->
           failf "expected Protocol_error for unsupported mode, got %s"
             (Runtime_acp_client.error_to_string err)
         | Ok _ -> fail "unsupported mode should have failed closed");
        (* Open valid session *)
        let info =
          match
            Runtime_acp_client.new_session
              client
              ~cwd:iso_cwd
              ~mode:"default"
              ~model:(Runtime_acp_client.model_selection_of_string "model-a")
              ~effort:Llm_provider.Reasoning_effort.Medium
              ()
          with
          | Ok s -> s
          | Error err -> failf "new_session failed: %s" (Runtime_acp_client.error_to_string err)
        in
        (* Reconfigure with identical options sends 0 RPCs *)
        let info2 =
          match
            Runtime_acp_client.reconfigure_session
              client
              info
              ~mode:"default"
              ~model:(Runtime_acp_client.model_selection_of_string "model-a")
              ~effort:Llm_provider.Reasoning_effort.Medium
              ()
          with
          | Ok s -> s
          | Error err -> failf "noop reconfigure failed: %s" (Runtime_acp_client.error_to_string err)
        in
        let state_after_noop = Yojson.Safe.from_file log_file in
        check int "noop reconfigure sent 0 set_opts" 0
          (List.length (state_after_noop |> member "set_opts" |> to_list));
        check string "child started in isolated cwd via ~fs" iso_cwd
          (state_after_noop |> member "cwd" |> to_string);
        (* Reconfigure effort delta updates config_options in place even when server returns [] *)
        let info3 =
          match
            Runtime_acp_client.reconfigure_session
              client
              info2
              ~mode:"default"
              ~model:(Runtime_acp_client.model_selection_of_string "model-a")
              ~effort:Llm_provider.Reasoning_effort.High
              ()
          with
          | Ok s -> s
          | Error err -> failf "effort reconfigure failed: %s" (Runtime_acp_client.error_to_string err)
        in
        check int "config_options preserved when server returns []" 1
          (List.length info3.config_options);
        check string "effort current_value updated in place" "high"
          (List.hd info3.config_options).current_value;
        (* load_session returning {} captures replayed usage/mode, reuses cached catalog,
           and clears cached current_value so effort=High still dispatches set_config_option *)
        let loaded =
          match
            Runtime_acp_client.load_session
              client
              ~session_id:"sess-l3-loaded"
              ~cwd:iso_cwd
              ~mode:"default"
              ~model:(Runtime_acp_client.model_selection_of_string "model-b")
              ~effort:Llm_provider.Reasoning_effort.High
              ()
          with
          | Ok s -> s
          | Error err -> failf "load_session failed: %s" (Runtime_acp_client.error_to_string err)
        in
        check (option int) "replayed_context_used captured" (Some 12345) loaded.replayed_context_used;
        check (option int) "replayed_context_size captured" (Some 200000) loaded.replayed_context_size;
        check (option string) "replayed mode captured" (Some "default") loaded.current_mode_id;
        check (option string) "cached availableModels enabled set_model on {} load" (Some "model-b")
          loaded.current_model_id;
        let state_after_load = Yojson.Safe.from_file log_file in
        check int "load_session returning {} still applied effort set_config_option" 2
          (List.length (state_after_load |> member "set_opts" |> to_list));
        (* Unattributed session/update (missing sessionId) is dropped *)
        (match
           Runtime_acp_client.prompt
             client
             ~session_id:loaded.session_id
             ~blocks:[ Runtime_acp_client.Text_block "check-attribution" ]
             ()
         with
         | Error err -> failf "prompt failed: %s" (Runtime_acp_client.error_to_string err)
         | Ok res ->
           check string "only session-attributed update delivered" "ATTRIBUTED" res.text);
        (* close_session sends session/close *)
        (match Runtime_acp_client.close_session ~timeout_s:2.0 client ~session_id:loaded.session_id with
         | Ok () -> ()
         | Error err -> failf "close_session failed: %s" (Runtime_acp_client.error_to_string err));
        let final_state = Yojson.Safe.from_file log_file in
        let closed_ids = final_state |> member "closed" |> to_list |> List.map to_string in
        check (list string) "session/close recorded" [ "sess-l3-loaded" ] closed_ids;
        (* Wait briefly for async stderr drain daemon so assertion is never vacuous *)
        let rec await_stderr attempts =
          let s = Runtime_acp_client.stderr_tail client in
          if String.trim s <> "" || attempts <= 0
          then s
          else (
            Eio.Time.sleep clock 0.01;
            await_stderr (attempts - 1))
        in
        let tail = await_stderr 50 in
        let rec has_sub ~needle s i =
          if i + String.length needle > String.length s
          then false
          else if String.sub s i (String.length needle) = needle
          then true
          else has_sub ~needle s (i + 1)
        in
        check bool "diagnostic stderr prefix captured" true
          (has_sub ~needle:"diagnostic leak" tail 0);
        check bool "redaction marker emitted in stderr_tail" true
          (has_sub ~needle:"[REDACTED]" tail 0);
        check bool "bearer secret redacted from stderr_tail" false
          (has_sub ~needle:"bearer-secret-l3-xyz987654321" tail 0);
        check bool "MCP capability URL redacted from stderr_tail" false
          (has_sub ~needle:"cap-l3-token987" tail 0);
        Runtime_acp_client.close client));
    (* Isolated workspace cleaned up after switch exits *)
    check bool "isolated workspace removed on switch release" false
      (Sys.file_exists !iso_path_ref))
;;

let test_layer4_classify_prompt_error_usage_context_and_process_config_hash () =
  let overflow_err =
    Runtime_acp_client.rpc_error
      ~method_name:"session/prompt"
      ~code:(-32603)
      ~message:"maximum context length reached"
      ~data:(Some (`Assoc [ "code", `String "context_length_exceeded" ]))
  in
  (* 1. Gate continuation overflow -> Vendor_session_full + non-retryable ProviderReportedError *)
  (match
     Keeper_acp_runtime.For_testing.classify_prompt_error
       ~is_gate_continuation:true
       ~activity_observed:false
       overflow_err
   with
   | ( Keeper_official_client_session_store.Vendor_session_full
         Keeper_official_client_session_store.No_activity_observed
     , Agent_core.Error.Provider (Llm_provider.Error.ProviderReportedError _) ) -> ()
   | _ -> fail "expected Gate continuation overflow without activity to map to Vendor_session_full(No_activity_observed)");
  (match
     Keeper_acp_runtime.For_testing.classify_prompt_error
       ~is_gate_continuation:true
       ~activity_observed:true
       overflow_err
   with
   | ( Keeper_official_client_session_store.Vendor_session_full
         Keeper_official_client_session_store.Activity_observed
     , Agent_core.Error.Provider (Llm_provider.Error.ProviderReportedError _) ) -> ()
   | _ -> fail "expected Gate continuation overflow with activity to map to Vendor_session_full(Activity_observed)");
  (* 2. Post-activity non-gate overflow -> Effect_fenced + non-retryable ProviderReportedError *)
  (match
     Keeper_acp_runtime.For_testing.classify_prompt_error
       ~is_gate_continuation:false
       ~activity_observed:true
       overflow_err
   with
   | ( Keeper_official_client_session_store.Input_rejected
         Keeper_official_client_session_store.Effect_fenced
     , Agent_core.Error.Provider (Llm_provider.Error.ProviderReportedError _) ) -> ()
   | _ -> fail "expected post-activity overflow to map to Effect_fenced + ProviderReportedError");
  (* 3. Clean pre-activity non-gate overflow -> Bootstrap_floor_exceeded + ContextOverflow *)
  (match
     Keeper_acp_runtime.For_testing.classify_prompt_error
       ~is_gate_continuation:false
       ~activity_observed:false
       overflow_err
   with
   | ( Keeper_official_client_session_store.Input_rejected
         Keeper_official_client_session_store.Bootstrap_floor_exceeded
     , Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _) ) -> ()
   | _ -> fail "expected clean pre-activity overflow to enter shrink ladder with ContextOverflow");
  (* 4. usage_is_nonzero & effective_context_used *)
  let zero_api_usage =
    Keeper_acp_runtime.For_testing.api_usage_of_acp_usage
      ~driver:Antigravity
      Runtime_acp_client.empty_usage
  in
  check bool "zero usage is not nonzero" false
    (Keeper_acp_runtime.For_testing.usage_is_nonzero zero_api_usage);
  let agy_usage_no_ctx : Runtime_acp_client.usage =
    { Runtime_acp_client.empty_usage with
      input_tokens = 12000
    ; cached_read_tokens = 38000
    ; output_tokens = 400
    }
  in
  check bool "nonzero usage detected" true
    (Keeper_acp_runtime.For_testing.usage_is_nonzero
       (Keeper_acp_runtime.For_testing.api_usage_of_acp_usage
          ~driver:Antigravity
          agy_usage_no_ctx));
  check (option int) "effective_context_used falls back to normalized inclusive input_tokens"
    (Some 50000)
    (Keeper_acp_runtime.For_testing.effective_context_used
       ~driver:Antigravity
       agy_usage_no_ctx);
  check (option int) "effective_context_used prefers explicit positive context_used"
    (Some 77777)
    (Keeper_acp_runtime.For_testing.effective_context_used
       ~driver:Antigravity
       { agy_usage_no_ctx with context_used = Some 77777 });
  check (option int) "effective_context_used returns None when all counts are 0" None
    (Keeper_acp_runtime.For_testing.effective_context_used
       ~driver:Antigravity
       Runtime_acp_client.empty_usage);
  (* 5. process_config_sha256 tracks spawn-time config but stays stable on model/effort/mode *)
  let base_cfg : Runtime_execution.acp_client =
    { driver = Runtime_acp_client.Antigravity
    ; cli_path = "/usr/local/bin/agy"
    ; args = [ "acp" ]
    ; strip_env = []
    ; skills_dirs = []
    ; model = Runtime_acp_client.model_selection_of_string "gemini-4-neon-medium"
    ; effort = Some Llm_provider.Reasoning_effort.Medium
    ; mode = Some "default"
    ; oauth_source = Some "/tmp/oauth-a"
    ; timeout_s = 120.0
    }
  in
  let h_base =
    Keeper_acp_runtime.For_testing.process_config_sha256
      ~native_posture:Runtime_native_tools.Native_none
      ~skills_dirs:[]
      base_cfg
  in
  let h_same_proc_diff_model =
    Keeper_acp_runtime.For_testing.process_config_sha256
      ~native_posture:Runtime_native_tools.Native_none
      ~skills_dirs:[]
      { base_cfg with
        model = Runtime_acp_client.model_selection_of_string "claude-opus-5-5-high"
      ; effort = Some Llm_provider.Reasoning_effort.High
      ; mode = Some "auto"
      }
  in
  let h_diff_oauth =
    Keeper_acp_runtime.For_testing.process_config_sha256
      ~native_posture:Runtime_native_tools.Native_none
      ~skills_dirs:[]
      { base_cfg with oauth_source = Some "/tmp/oauth-b" }
  in
  let h_diff_posture =
    Keeper_acp_runtime.For_testing.process_config_sha256
      ~native_posture:Runtime_native_tools.Native_read
      ~skills_dirs:[]
      base_cfg
  in
  check string "process_config_sha256 ignores warm-reconfigurable model/effort/mode"
    h_base h_same_proc_diff_model;
  check bool "process_config_sha256 changes on oauth_source change" true
    (not (String.equal h_base h_diff_oauth));
  check bool "process_config_sha256 changes on native_posture change" true
    (not (String.equal h_base h_diff_posture));
  (* 6. hydrate_start_messages ~prefer_handoff:true preserves appended before_turn nudges *)
  let tmp = Filename.temp_dir ~perms:0o700 "masc-acp-l4-nudge-" "" in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let keepers_dir = Unix.realpath tmp in
    ignore
      (Keeper_canonical_turn_store.commit_turn
         ~keepers_dir
         ~keeper_id:"k-nudge"
         ~turn_id:(Ids.Turn_id.of_string "turn-1")
         ~runtime_kind:Keeper_canonical_turn_store.Acp_cli
         ~runtime_id:"rt-1"
         ~user_input:"hello"
         ~tool_calls_json:(`List [])
         ~assistant_output:"world"
         ~usage_json:(`Assoc [])
         ~created_at:100.0
         ());
    let nudge_msg : Agent_core.Types.message =
      { role = Agent_core.Types.User
      ; origin = Agent_core.Llm_provider.Types.Conversation
      ; content = [ Agent_core.Types.Text "before-turn-nudge" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    in
    let sys_carrier_msg : Agent_core.Types.message =
      { role = Agent_core.Types.System
      ; origin = Agent_core.Llm_provider.Types.Conversation
      ; content = [ Agent_core.Types.Text "world-state-carrier" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    in
    let hydrated =
      Keeper_acp_runtime.For_testing.hydrate_start_messages
        ~appended_nudges:[ sys_carrier_msg; nudge_msg ]
        ~keepers_dir
        ~keeper_id:"k-nudge"
        ~prefer_handoff:true
        [ sys_carrier_msg ]
    in
    let has_nudge =
      List.exists
        (fun (m : Agent_core.Types.message) ->
           match m.content with
           | [ Agent_core.Types.Text "before-turn-nudge" ] -> true
           | _ -> false)
        hydrated
    in
    let sys_carrier_count =
      List.length
        (List.filter
           (fun (m : Agent_core.Types.message) ->
              match m.content with
              | [ Agent_core.Types.Text "world-state-carrier" ] -> true
              | _ -> false)
           hydrated)
    in
    check bool "prefer_handoff preserves before_turn nudges" true has_nudge;
    check int "prefer_handoff never duplicates system carrier from appended_nudges" 1 sys_carrier_count)
;;

let test_layer4_stream_projection_sse_framing_native_tools_and_zero_usage () =
  let events_rev = ref [] in
  let native_actions_rev = ref [] in
  let native_completions_rev = ref [] in
  let usage_reports_rev = ref [] in
  let on_acp_event, on_tool_started, on_tool_finished, finish, observed_tool_calls =
    Keeper_acp_runtime.For_testing.project_stream_for_testing
      ~on_native_action:(fun ~official_turn ~identity ~tool_name ->
        native_actions_rev := (official_turn, identity, tool_name) :: !native_actions_rev)
      ~on_native_tool_completion:(fun ~block_index ~tool_call_id completion ->
        native_completions_rev :=
          (block_index, tool_call_id, completion) :: !native_completions_rev)
      ~on_usage_report:(fun report -> usage_reports_rev := report :: !usage_reports_rev)
      ~on_event:(fun ev -> events_rev := ev :: !events_rev)
      ~driver:Runtime_acp_client.Antigravity
      ~model:"gemini-4-neon-medium"
      ~session_id:"sess-stream"
      ~turn_count:3
      ~native_posture:Runtime_native_tools.Native_read
      ~allowed_tool_names:[ "masc_probe_ping" ]
      ()
  in
  (* Zero-token Usage_updated must NOT emit on_usage_report *)
  on_acp_event
    (Runtime_acp_client.Usage_updated
       { used = Some 0
       ; size = Some 400000
       ; prompt_tokens = Some 0
       ; completion_tokens = Some 0
       ; cached_tokens = Some 0
       ; cached_write_tokens = Some 0
       ; thought_tokens = Some 0
       ; total_tokens = Some 0
       });
  check int "zero usage suppressed" 0 (List.length !usage_reports_rev);
  (* Nonzero Usage_updated emits report *)
  on_acp_event
    (Runtime_acp_client.Usage_updated
       { used = Some 1500
       ; size = Some 400000
       ; prompt_tokens = Some 1000
       ; completion_tokens = Some 200
       ; cached_tokens = Some 300
       ; cached_write_tokens = None
       ; thought_tokens = None
       ; total_tokens = Some 1500
       });
  check int "nonzero usage reported" 1 (List.length !usage_reports_rev);
  (* Thought -> Text -> MCP tool -> Native tool -> Finish *)
  on_acp_event (Runtime_acp_client.Thought_delta "thinking...");
  on_acp_event (Runtime_acp_client.Text_delta "hello ");
  check bool "on_tool_started accepted before finish" true
    (on_tool_started
       ~call_id:"mcp-call-1"
       ~tool_name:"masc_probe_ping"
       ~arguments:(`Assoc [ "nonce", `String "n1" ]));
  on_tool_finished ~call_id:"mcp-call-1";
  on_acp_event
    (Runtime_acp_client.Tool_call_started
       { tool_call_id = "nat-call-1"
       ; title = "Read file"
       ; kind = Some Runtime_acp_client.Tool_read
       ; status = Runtime_acp_client.Tool_in_progress
       ; raw_input = Some (`Assoc [ "path", `String "/tmp/a" ])
       ; identity =
           Runtime_acp_client.Native_tool
             { name = Some "read_file"
             ; kind = Some Runtime_acp_client.Tool_read
             ; locations = [ "/tmp/a" ]
             }
       });
  on_acp_event
    (Runtime_acp_client.Tool_call_updated
       { tool_call_id = "nat-call-1"
       ; title = None
       ; kind = None
       ; status = Some Runtime_acp_client.Tool_completed
       ; raw_input = None
       ; raw_output = None
       ; identity = None
       });
  let final_api_usage : Agent_core.Types.api_usage =
    { input_tokens = 1500
    ; output_tokens = 200
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 300
    ; cost_usd = None
    }
  in
  finish ~stop_reason:Agent_core.Types.EndTurn ~usage:(Some final_api_usage);
  (* Late MCP tool start after finish is rejected cleanly *)
  check bool "on_tool_started rejected after finish" false
    (on_tool_started
       ~call_id:"mcp-call-late"
       ~tool_name:"masc_probe_ping"
       ~arguments:(`Assoc []));
  (* Idempotent second finish emits nothing *)
  let count_after_first_finish = List.length !events_rev in
  finish ~stop_reason:Agent_core.Types.EndTurn ~usage:None;
  check int "finish is idempotent" count_after_first_finish (List.length !events_rev);
  let events = List.rev !events_rev in
  (match List.hd events with
   | Agent_core.Types.MessageStart { model = "gemini-4-neon-medium"; _ } -> ()
   | _ -> fail "expected MessageStart as first SSE event");
  let has_input_snapshot =
    List.exists
      (function
        | Agent_core.Types.ContentBlockDelta { delta = Agent_core.Types.InputJsonSnapshot _; _ } ->
          true
        | _ -> false)
      events
  in
  check bool "MCP tool emits InputJsonSnapshot" true has_input_snapshot;
  (match List.rev events with
   | Agent_core.Types.MessageStop
     :: Agent_core.Types.MessageDelta
          { stop_reason = Some EndTurn
          ; usage = Some { input_tokens = Some 1500; output_tokens = Some 200; _ }
          }
     :: _ -> ()
   | _ -> fail "expected MessageDelta(delta_usage) + MessageStop at end of stream");
  check int "native action observed" 1 (List.length !native_actions_rev);
  check int "native completion observed" 1 (List.length !native_completions_rev);
  (match !native_completions_rev with
   | [ (_, Some "nat-call-1", { Runtime_native_tools.outcome = Completion_reported; exit_code = None }) ] ->
     ()
   | _ -> fail "expected Completion_reported for nat-call-1");
  let open Yojson.Safe.Util in
  check int "observed_tool_calls records both MCP and native tools" 2
    (List.length (observed_tool_calls () |> to_list))
;;

let test_tool_call_update_escalation_re_evaluates_effect_fence () =
  (* 1. End-to-end mock ACP server: tool_call_update kind escalation produces
        merged kind + re-classified identity on Tool_call_updated, while
        pinned MASC MCP status-only updates preserve their MASC MCP identity. *)
  let tmp = Filename.temp_dir ~perms:0o700 "acp-update-fence-" "" in
  let mock_script = Filename.concat tmp "mock_update_fence.py" in
  let script_body =
    {|#!/usr/bin/env python3
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"promptCapabilities": {"image": False}}
        }})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "sess-upd"}})
    elif method == "session/prompt":
        # A. Native read starts harmlessly, then escalates to execute on tool_call_update
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-esc",
                "title": "read_file",
                "kind": "read",
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-esc",
                "kind": "execute",
                "status": "in_progress"
            }
        }})
        # B. Pinned Kimi MCP call enriched with rawInput, repeated identical rawInput, then status-only completion
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-mcp",
                "title": "mcp__masc__masc_probe_ping",
                "kind": "other",
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-mcp",
                "title": "mcp__masc__masc_probe_ping",
                "kind": "other",
                "status": "in_progress",
                "rawInput": {"a": 1, "nonce": "n1"}
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-mcp",
                "status": "completed",
                "rawInput": {"nonce": "n1", "a": 1},
                "rawOutput": "pong"
            }
        }})
        # C. Conflicting rawInput mutation on same toolCallId MUST escalate to conflict:identity
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-raw-esc",
                "title": "mcp__masc__masc_probe_ping",
                "kind": "other",
                "rawInput": {"nonce": "safe"},
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-raw-esc",
                "rawInput": {"nonce": "tampered"},
                "status": "in_progress"
            }
        }})
        # D. Conflicting MCP identifier title mutation (no structured name/_meta) MUST escalate to conflict:identity
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-title-esc",
                "title": "mcp__masc__masc_probe_ping",
                "kind": "other",
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-title-esc",
                "title": "mcp__evil__rm_rf",
                "status": "in_progress"
            }
        }})
        # E. Live-recorded kimi acp 2.7.2 native Read progress title ("Read" -> "Reading hello.txt") MUST NOT false-conflict
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-kimi-read",
                "title": "Read",
                "kind": "read",
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-kimi-read",
                "title": "Reading hello.txt",
                "kind": "read",
                "rawInput": {"path": "hello.txt"},
                "status": "in_progress"
            }
        }})
        # F. Antigravity mcp(...) wrapper with kind="execute" title mutation MUST escalate to conflict:identity
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-exec-wrap-esc",
                "title": "mcp(masc/masc_probe_ping)",
                "kind": "execute",
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-exec-wrap-esc",
                "title": "mcp(evil/rm_rf)",
                "kind": "execute",
                "status": "in_progress"
            }
        }})
        # G. Late structured name injection differing from identifier-like prior title MUST escalate to conflict:identity
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-name-inject",
                "title": "read_file",
                "kind": "other",
                "status": "pending"
            }
        }})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "sess-upd",
            "update": {
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-name-inject",
                "name": "mcp__masc__masc_probe_ping",
                "status": "in_progress"
            }
        }})
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
|}
  in
  Out_channel.with_open_text mock_script (fun oc -> output_string oc script_body);
  let updates_rev = ref [] in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr =
        Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 ()
      in
      let cfg =
        { (Runtime_acp_client.default_config ~driver:Kimi_code ~cwd:tmp) with
          cli_path = "python3"
        ; args = [ mock_script ]
        }
      in
      Eio.Switch.run (fun sw ->
        let client =
          match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~config:cfg () with
          | Ok c -> c
          | Error err -> failf "start failed: %s" (Runtime_acp_client.error_to_string err)
        in
        Fun.protect ~finally:(fun () -> Runtime_acp_client.close client) (fun () ->
          let sess =
            match Runtime_acp_client.new_session client ~cwd:tmp () with
            | Ok s -> s
            | Error err -> failf "new_session failed: %s" (Runtime_acp_client.error_to_string err)
          in
          let policy =
            Runtime_acp_client.Allow_read_and_masc_mcp
              { mcp_server_name = "masc"
              ; allowed_tool_names = [ "masc_probe_ping" ]
              }
          in
          match
            Runtime_acp_client.prompt
              client
              ~session_id:sess.session_id
              ~blocks:[ Runtime_acp_client.Text_block "check update fence" ]
              ~permission_policy:policy
              ~on_event:(function
                | Runtime_acp_client.Tool_call_updated { tool_call_id; kind; identity; _ } ->
                  updates_rev := (tool_call_id, kind, identity) :: !updates_rev
                | _ -> ())
              ()
          with
          | Ok _ -> ()
          | Error err -> failf "prompt failed: %s" (Runtime_acp_client.error_to_string err)))));
  let updates = List.rev !updates_rev in
  check int "eight Tool_call_updated events observed" 8 (List.length updates);
  (match updates with
   | [ ("tc-esc", esc_kind, esc_id)
     ; ("tc-mcp", mcp_enrich_kind, mcp_enrich_id)
     ; ("tc-mcp", mcp_kind, mcp_id)
     ; ("tc-raw-esc", raw_esc_kind, raw_esc_id)
     ; ("tc-title-esc", title_esc_kind, title_esc_id)
     ; ("tc-kimi-read", kimi_read_kind, kimi_read_id)
     ; ("tc-exec-wrap-esc", exec_wrap_kind, exec_wrap_id)
     ; ("tc-name-inject", name_inject_kind, name_inject_id)
     ] ->
     check bool "escalated update carries conflict:read->execute kind" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some (Runtime_acp_client.Tool_unknown "conflict:read->execute"))
          esc_kind);
     (match esc_id with
      | Some (Runtime_acp_client.Native_tool { kind = Some (Runtime_acp_client.Tool_unknown "conflict:read->execute"); _ }) ->
        ()
      | _ -> fail "expected Native_tool with conflict:read->execute on escalated Tool_call_updated");
     check bool "pinned MCP rawInput enrichment preserves Tool_other kind" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some Runtime_acp_client.Tool_other)
          mcp_enrich_kind);
     (match mcp_enrich_id with
      | Some
          (Runtime_acp_client.Mcp_tool
             { server = Runtime_acp_client.Explicit_server "masc"
             ; tool_name = "masc_probe_ping"
             }) -> ()
      | _ -> fail "expected pinned MASC MCP identity preserved on rawInput enrichment");
     check bool "pinned MCP key-reordered identical rawInput preserves Tool_other kind" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some Runtime_acp_client.Tool_other)
          mcp_kind);
     (match mcp_id with
      | Some
          (Runtime_acp_client.Mcp_tool
             { server = Runtime_acp_client.Explicit_server "masc"
             ; tool_name = "masc_probe_ping"
             }) -> ()
      | _ -> fail "expected pinned MASC MCP identity preserved on key-reordered rawInput Tool_call_updated");
     check bool "conflicting rawInput mutation escalates to conflict:identity" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some (Runtime_acp_client.Tool_unknown "conflict:identity"))
          raw_esc_kind);
     (match raw_esc_id with
      | Some (Runtime_acp_client.Native_tool { kind = Some (Runtime_acp_client.Tool_unknown "conflict:identity"); _ }) ->
        ()
      | _ -> fail "expected conflicting rawInput update to escalate to Native_tool conflict:identity");
     check bool "conflicting title mutation escalates to conflict:identity" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some (Runtime_acp_client.Tool_unknown "conflict:identity"))
          title_esc_kind);
     (match title_esc_id with
      | Some (Runtime_acp_client.Native_tool { kind = Some (Runtime_acp_client.Tool_unknown "conflict:identity"); _ }) ->
        ()
      | _ -> fail "expected conflicting title update to escalate to Native_tool conflict:identity");
     check bool "live kimi Read -> Reading hello.txt progress title keeps Tool_read" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some Runtime_acp_client.Tool_read)
          kimi_read_kind);
     (match kimi_read_id with
      | Some (Runtime_acp_client.Native_tool { kind = Some Runtime_acp_client.Tool_read; _ }) -> ()
      | _ -> fail "expected live kimi Read progress title to preserve Native_tool Tool_read");
     check bool "mcp(...) kind=execute title mutation escalates to conflict:identity" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some (Runtime_acp_client.Tool_unknown "conflict:identity"))
          exec_wrap_kind);
     (match exec_wrap_id with
      | Some (Runtime_acp_client.Native_tool { kind = Some (Runtime_acp_client.Tool_unknown "conflict:identity"); _ }) ->
        ()
      | _ -> fail "expected mcp(...) execute title mutation to escalate to Native_tool conflict:identity");
     check bool "late structured name injection after identifier title escalates to conflict:identity" true
       (Option.equal
          Runtime_acp_client.equal_tool_kind
          (Some (Runtime_acp_client.Tool_unknown "conflict:identity"))
          name_inject_kind);
     (match name_inject_id with
      | Some (Runtime_acp_client.Native_tool { kind = Some (Runtime_acp_client.Tool_unknown "conflict:identity"); _ }) ->
        ()
      | _ -> fail "expected late structured name injection to escalate to Native_tool conflict:identity")
   | _ -> fail "unexpected Tool_call_updated sequence");
  (* 2. Keeper stream projection re-evaluates effect fence on Tool_call_updated *)
  let read_fenced = ref 0 in
  let on_acp_read, _, _, _, _ =
    Keeper_acp_runtime.For_testing.project_stream_for_testing
      ~on_effect_attempted:(fun () -> incr read_fenced)
      ~driver:Kimi_code
      ~model:"kimi-code/k3"
      ~session_id:"sess-read-fence"
      ~turn_count:1
      ~native_posture:Runtime_native_tools.Native_read
      ~allowed_tool_names:[ "masc_probe_ping" ]
      ()
  in
  on_acp_read
    (Runtime_acp_client.Tool_call_started
       { tool_call_id = "tc-esc"
       ; title = "read_file"
       ; kind = Some Runtime_acp_client.Tool_read
       ; status = Runtime_acp_client.Tool_pending
       ; raw_input = None
       ; identity =
           Runtime_acp_client.Native_tool
             { name = Some "read_file"
             ; kind = Some Runtime_acp_client.Tool_read
             ; locations = []
             }
       });
  check int "Native_read Tool_read start does not fence" 0 !read_fenced;
  on_acp_read
    (Runtime_acp_client.Tool_call_updated
       { tool_call_id = "tc-esc"
       ; title = None
       ; kind = Some (Runtime_acp_client.Tool_unknown "conflict:read->execute")
       ; status = Some Runtime_acp_client.Tool_in_progress
       ; raw_input = None
       ; raw_output = None
       ; identity =
           Some
             (Runtime_acp_client.Native_tool
                { name = Some "read_file"
                ; kind = Some (Runtime_acp_client.Tool_unknown "conflict:read->execute")
                ; locations = []
                })
       });
  check int "Tool_call_updated kind escalation fences same-turn retry" 1 !read_fenced;
  (* 3. Under Native_none: correlated pinned MASC MCP & managed schema read stay
        unfenced, while schema-read escalating to Native_tool trips the fence
        AND records native-tool observation/completion, and uncorrelated
        identity=None updates fail closed. *)
  let none_fenced = ref 0 in
  let escalated_native_actions = ref 0 in
  let escalated_native_completions = ref 0 in
  let on_acp_none, _, _, _, observed_none_tools =
    Keeper_acp_runtime.For_testing.project_stream_for_testing
      ~on_effect_attempted:(fun () -> incr none_fenced)
      ~on_native_action:(fun ~official_turn:_ ~identity:_ ~tool_name:_ -> incr escalated_native_actions)
      ~on_native_tool_completion:(fun ~block_index:_ ~tool_call_id:_ _ -> incr escalated_native_completions)
      ~driver:Antigravity
      ~model:"gemini-4-neon-medium"
      ~session_id:"sess-none-fence"
      ~turn_count:1
      ~native_posture:Runtime_native_tools.Native_none
      ~allowed_tool_names:[ "masc_probe_ping" ]
      ()
  in
  let pinned_mcp_id =
    Runtime_acp_client.Mcp_tool
      { server = Runtime_acp_client.Explicit_server "masc"
      ; tool_name = "masc_probe_ping"
      }
  in
  on_acp_none
    (Runtime_acp_client.Tool_call_started
       { tool_call_id = "tc-mcp"
       ; title = "mcp_masc_masc_probe_ping"
       ; kind = Some Runtime_acp_client.Tool_other
       ; status = Runtime_acp_client.Tool_pending
       ; raw_input = None
       ; identity = pinned_mcp_id
       });
  on_acp_none
    (Runtime_acp_client.Tool_call_updated
       { tool_call_id = "tc-mcp"
       ; title = None
       ; kind = Some Runtime_acp_client.Tool_other
       ; status = Some Runtime_acp_client.Tool_completed
       ; raw_input = None
       ; raw_output = None
       ; identity = Some pinned_mcp_id
       });
  on_acp_none
    (Runtime_acp_client.Tool_call_started
       { tool_call_id = "tc-schema"
       ; title = "read_file"
       ; kind = Some Runtime_acp_client.Tool_read
       ; status = Runtime_acp_client.Tool_pending
       ; raw_input = None
       ; identity =
           Runtime_acp_client.Managed_mcp_schema_read
             { mcp_server_name = "masc"
             ; path = "/tmp/gdir/antigravity-cli/mcp/masc/masc_probe_ping.json"
             }
       });
  check int "correlated pinned MCP and managed schema read stay unfenced" 0 !none_fenced;
  check int "no native action recorded before escalation" 0 !escalated_native_actions;
  on_acp_none
    (Runtime_acp_client.Tool_call_updated
       { tool_call_id = "tc-schema"
       ; title = None
       ; kind = Some Runtime_acp_client.Tool_read
       ; status = Some Runtime_acp_client.Tool_completed
       ; raw_input = Some (`Assoc [ "path", `String "/etc/passwd" ])
       ; raw_output = None
       ; identity =
           Some
             (Runtime_acp_client.Native_tool
                { name = Some "read_file"
                ; kind = Some Runtime_acp_client.Tool_read
                ; locations = [ "/tmp/gdir/antigravity-cli/mcp/masc/masc_probe_ping.json"; "/etc/passwd" ]
                })
       });
  check int "schema read downgraded to Native_tool on Tool_call_updated trips fence" 1 !none_fenced;
  check int "escalated Native_tool records native action" 1 !escalated_native_actions;
  check int "escalated Native_tool completion closes native block" 1 !escalated_native_completions;
  (match Yojson.Safe.Util.to_list (observed_none_tools ()) with
   | [ entry ] ->
     let open Yojson.Safe.Util in
     check string "escalated Native_tool audit preserves merged raw_input arguments"
       "/etc/passwd" (entry |> member "arguments" |> member "path" |> to_string)
   | entries -> failf "expected 1 observed escalated native tool, got %d" (List.length entries));
  (* Late duplicate update for an already-closed Native_tool must not reopen a duplicate native action *)
  on_acp_none
    (Runtime_acp_client.Tool_call_updated
       { tool_call_id = "tc-schema"
       ; title = None
       ; kind = Some Runtime_acp_client.Tool_read
       ; status = Some Runtime_acp_client.Tool_completed
       ; raw_input = Some (`Assoc [ "path", `String "/etc/passwd" ])
       ; raw_output = None
       ; identity =
           Some
             (Runtime_acp_client.Native_tool
                { name = Some "read_file"
                ; kind = Some Runtime_acp_client.Tool_read
                ; locations = [ "/tmp/gdir/antigravity-cli/mcp/masc/masc_probe_ping.json"; "/etc/passwd" ]
                })
       });
  check int "late duplicate update does not record duplicate native action" 1 !escalated_native_actions;
  (* Uncorrelated status-only Tool_call_updated (identity = None) fails closed on effect fence *)
  let fenced_before_uncorrelated = !none_fenced in
  on_acp_none
    (Runtime_acp_client.Tool_call_updated
       { tool_call_id = "tc-unannounced"
       ; title = None
       ; kind = None
       ; status = Some Runtime_acp_client.Tool_completed
       ; raw_input = None
       ; raw_output = None
       ; identity = None
       });
  check int "uncorrelated identity=None Tool_call_updated fails closed on effect fence"
    (fenced_before_uncorrelated + 1) !none_fenced
;;

let test_implicit_mcp_kind_multi_server_isolation () =
  (* 1. Pure should_allow_tool_call fails closed by default on Implicit_mcp_kind.
        Use [keeper_skill] (NOT starting with "masc_") so Mistral_vibe does NOT
        match Server_underscore_prefix and genuinely reaches Implicit_mcp_kind. *)
  let policy =
    Runtime_acp_client.Allow_masc_mcp_only
      { mcp_server_name = "masc"
      ; allowed_tool_names = [ "masc_probe_ping"; "keeper_skill" ]
      }
  in
  let read_and_mcp =
    Runtime_acp_client.Allow_read_and_masc_mcp
      { mcp_server_name = "masc"
      ; allowed_tool_names = [ "masc_probe_ping"; "keeper_skill" ]
      }
  in
  let implicit_id =
    Runtime_acp_client.Mcp_tool
      { server = Runtime_acp_client.Implicit_mcp_kind
      ; tool_name = "keeper_skill"
      }
  in
  check bool "Implicit_mcp_kind denied by default (Shared_or_multi_server)" false
    (Runtime_acp_client.should_allow_tool_call ~policy implicit_id);
  check bool "Implicit_mcp_kind denied under Allow_read_and_masc_mcp by default" false
    (Runtime_acp_client.should_allow_tool_call ~policy:read_and_mcp implicit_id);
  check bool "Implicit_mcp_kind allowed under matching Single_pinned_server when pinned" true
    (Runtime_acp_client.should_allow_tool_call
       ~server_isolation:(Runtime_acp_client.Single_pinned_server "masc")
       ~policy
       implicit_id);
  check bool "Implicit_mcp_kind denied when Single_pinned_server names a different server" false
    (Runtime_acp_client.should_allow_tool_call
       ~server_isolation:(Runtime_acp_client.Single_pinned_server "other")
       ~policy
       implicit_id);
  (* Verify Mistral_vibe omits Implicit_vendor_mcp_kind so bare "keeper_skill" + kind="mcp"
     classifies directly as Native_tool (never hidden from native audit) and is denied. *)
  let vibe_bare_mcp_id =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Mistral_vibe
      ~mcp_server_name:"masc"
      (`Assoc [ "title", `String "keeper_skill"; "kind", `String "mcp" ])
  in
  (match vibe_bare_mcp_id with
   | Runtime_acp_client.Native_tool
       { name = Some "keeper_skill"; kind = Some Runtime_acp_client.Tool_vendor_mcp; _ } -> ()
   | _ -> fail "expected Mistral_vibe bare keeper_skill + kind=mcp to classify as Native_tool");
  check bool "unqualified Tool_vendor_mcp denied on Mistral_vibe (Shared_or_multi_server)" false
    (Runtime_acp_client.For_testing.should_allow_permission
       ~driver:Mistral_vibe
       ~policy
       ~title:"keeper_skill"
       ~kind:(Some Tool_vendor_mcp));
  check bool "unqualified Tool_vendor_mcp fails closed on Antigravity without live Single_pinned_server proof"
    false
    (Runtime_acp_client.For_testing.should_allow_permission
       ~driver:Antigravity
       ~policy
       ~title:"keeper_skill"
       ~kind:(Some Tool_vendor_mcp));
  let agy_implicit_id =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Antigravity
      ~mcp_server_name:"masc"
      (`Assoc [ "title", `String "keeper_skill"; "kind", `String "mcp" ])
  in
  check bool "unqualified Tool_vendor_mcp allowed on Antigravity when matching Single_pinned_server is proven"
    true
    (Runtime_acp_client.should_allow_tool_call
       ~server_isolation:(Runtime_acp_client.Single_pinned_server "masc")
       ~policy
       agy_implicit_id);
  (* 2. Cross-driver prefix paired with kind="mcp" (Tool_vendor_mcp) is rejected
        BEFORE Implicit_vendor_mcp_kind, classifying as Native_tool rather than
        Implicit_mcp_kind. *)
  let agy_cross_driver_id =
    Runtime_acp_client.For_testing.classify_tool_call_json
      ~driver:Antigravity
      ~mcp_server_name:"masc"
      (`Assoc
         [ "title", `String "mcp__masc__masc_probe_ping"
         ; "kind", `String "mcp"
         ])
  in
  (match agy_cross_driver_id with
   | Runtime_acp_client.Native_tool { kind = Some Runtime_acp_client.Tool_vendor_mcp; _ } -> ()
   | _ -> fail "cross-driver mcp__ prefix with kind=mcp must not fall through to Implicit_mcp_kind");
  check bool "cross-driver mcp__ prefix with kind=mcp denied even under Single_pinned_server" false
    (Runtime_acp_client.should_allow_tool_call
       ~server_isolation:(Runtime_acp_client.Single_pinned_server "masc")
       ~policy
       agy_cross_driver_id);
  (* 3. End-to-end live client isolation SSOT across three real client configurations:
        - Mistral_vibe (Session_new_http_mcp) -> Shared_or_multi_server: rejects 2001 (keeper_skill kind=mcp), allows 2002 (mcp_masc.masc_probe_ping)
        - Antigravity WITHOUT ~mcp_server -> Shared_or_multi_server: rejects 2001 and 2002
        - Antigravity WITH ~mcp_server (isolated --gemini-dir/config/mcp_config.json) -> Single_pinned_server: allows 2001, rejects cross-driver 2002 *)
  let tmp = Filename.temp_dir ~perms:0o700 "acp-implicit-iso-" "" in
  let perm_log = Filename.concat tmp "perms.json" in
  let mock_script = Filename.concat tmp "mock_iso.py" in
  let script_body =
    Printf.sprintf
      {|#!/usr/bin/env python3
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

outcomes = {}
pending_prompt = None
opts = [
    {"optionId": "allow_once_id", "name": "Allow once", "kind": "allow_once"},
    {"optionId": "reject_once_id", "name": "Reject once", "kind": "reject_once"},
]

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"promptCapabilities": {"image": False}}
        }})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "sess-iso"}})
    elif method == "session/prompt":
        pending_prompt = mid
        # 2001: unqualified kind="mcp" (tool name does NOT start with "masc_") -> genuinely reaches Implicit_mcp_kind!
        send({"jsonrpc": "2.0", "id": 2001, "method": "session/request_permission", "params": {
            "sessionId": "sess-iso",
            "toolCall": {"toolCallId": "tc-imp", "title": "keeper_skill", "kind": "mcp"},
            "options": opts
        }})
        # 2002: explicit server-qualified mcp_masc.masc_probe_ping -> allowed on Mistral_vibe, cross-driver rejected on Antigravity
        send({"jsonrpc": "2.0", "id": 2002, "method": "session/request_permission", "params": {
            "sessionId": "sess-iso",
            "toolCall": {"toolCallId": "tc-exp", "title": "mcp_masc.masc_probe_ping", "kind": "other"},
            "options": opts
        }})
    else:
        if mid in (2001, 2002):
            outcomes[str(mid)] = msg.get("result", {}).get("outcome", {})
            if len(outcomes) == 2 and pending_prompt is not None:
                with open(%S, "w") as f:
                    json.dump(outcomes, f)
                send({"jsonrpc": "2.0", "id": pending_prompt, "result": {"stopReason": "end_turn"}})
                pending_prompt = None
|}
      perm_log
  in
  Out_channel.with_open_text mock_script (fun oc -> output_string oc script_body);
  let run_case ~driver ?mcp_server ~expected_iso ~expect_2001 ~expect_2002 ~label () =
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let proc_mgr =
        Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 ()
      in
      let cfg =
        { (Runtime_acp_client.default_config ~driver ~cwd:tmp) with
          cli_path = "python3"
        ; args = [ mock_script ]
        }
      in
      Eio.Switch.run (fun sw ->
        let client =
          match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~config:cfg ?mcp_server () with
          | Ok c -> c
          | Error err -> failf "%s start failed: %s" label (Runtime_acp_client.error_to_string err)
        in
        Fun.protect ~finally:(fun () -> Runtime_acp_client.close client) (fun () ->
          check bool (label ^ " live client mcp_server_isolation") true
            (Runtime_acp_client.equal_mcp_server_isolation
               expected_iso
               (Runtime_acp_client.mcp_server_isolation client));
          let sess =
            match Runtime_acp_client.new_session client ~cwd:tmp () with
            | Ok s -> s
            | Error err -> failf "%s new_session failed: %s" label (Runtime_acp_client.error_to_string err)
          in
          (match
             Runtime_acp_client.prompt
               client
               ~session_id:sess.session_id
               ~blocks:[ Runtime_acp_client.Text_block "iso check" ]
               ~permission_policy:policy
               ()
           with
           | Ok _ -> ()
           | Error err -> failf "%s prompt failed: %s" label (Runtime_acp_client.error_to_string err));
          let outcomes = Yojson.Safe.from_file perm_log in
          let option_of id =
            Yojson.Safe.Util.(outcomes |> member id |> member "optionId" |> to_string)
          in
          check string (label ^ " unqualified keeper_skill kind=mcp") expect_2001 (option_of "2001");
          check string (label ^ " mcp_masc.masc_probe_ping") expect_2002 (option_of "2002"))))
  in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    run_case
      ~driver:Mistral_vibe
      ~expected_iso:Runtime_acp_client.Shared_or_multi_server
      ~expect_2001:"reject_once_id"
      ~expect_2002:"allow_once_id"
      ~label:"Mistral_vibe"
      ();
    run_case
      ~driver:Antigravity
      ~expected_iso:Runtime_acp_client.Shared_or_multi_server
      ~expect_2001:"reject_once_id"
      ~expect_2002:"reject_once_id"
      ~label:"Antigravity without ~mcp_server"
      ();
    let masc_srv : Runtime_acp_client.mcp_http_server =
      { name = "masc"; url = "http://127.0.0.1:1/mcp"; headers = [] }
    in
    run_case
      ~driver:Antigravity
      ~mcp_server:masc_srv
      ~expected_iso:(Runtime_acp_client.Single_pinned_server "masc")
      ~expect_2001:"allow_once_id"
      ~expect_2002:"reject_once_id"
      ~label:"Antigravity with isolated ~mcp_server"
      ())
;;

let () =
  run "runtime_acp_client"
    [ ( "profiles"
      , [ test_case "closed driver profiles" `Quick test_driver_profiles
        ; test_case "muse profile and native-none support" `Quick
            test_muse_profile_and_native_none
        ; test_case "muse rejects unsupported config before spawn" `Quick
            test_muse_refuses_unsupported_config_before_spawn
        ; test_case "Muse turn effort is refused before session RPC" `Quick
            test_muse_turn_effort_refused_before_session_rpc
        ] )
    ; "environment", [ test_case "env strip and override" `Quick test_build_environment ]
    ; ( "argv_and_posture"
      , [ test_case "muse argv and environment" `Quick test_muse_argv_and_environment
        ; test_case "muse MCP grammar and permission policy" `Quick
            test_muse_permission_grammar
        ; test_case "kimi --skills-dir order & strict permission posture" `Quick
            test_build_argv_and_strict_permission_posture
        ; test_case "agy acp mcp(masc/...) and call_mcp_tool permission posture" `Quick
            test_antigravity_acp_mcp_permission_and_call_mcp_tool
        ; test_case "Vibe 3.1.0 toolCallId permission cache & agy wire" `Quick
            test_vibe_310_tool_call_id_permission_cache_and_agy_wire
        ] )
    ; ( "quota_and_vision"
      , [ test_case "ACP RPC quota/429/401/403/5xx classification, pool preservation & scopes" `Quick
            test_acp_rpc_error_classification_pool_preservation_and_scopes
        ; test_case "ACP v1 image negotiation & pre-RPC validation" `Quick
            test_acp_v1_image_negotiation_and_validation
        ] )
    ; ( "mcp_bridge"
      , [ test_case "pinned tools advertised before turn_slot is bound" `Quick
            test_mcp_bridge_advertises_pinned_tools_before_turn_slot
        ] )
    ; ( "pool_lifecycle"
      , [ test_case "cancelled turn evicts poisoned entry & recovers" `Quick
            test_cancelled_turn_evicts_entry_and_recovers
        ; test_case "key switch, evict_idle & evict_all lifecycle" `Quick
            test_pool_key_switch_evicts_superseded_keeper_entry
        ; test_case "mock ACP child PGID reap, sessionId perm check & PID-tagged gemini dir" `Quick
            test_mock_acp_child_pgid_reap_session_perm_and_pid_tagged_dir
        ] )
    ; ( "rollover_and_vibe310"
      , [ test_case "80% hysteresis rollover, durable marker & ContextOverflow classification" `Quick
            test_acp_80_pct_rollover_marker_and_overflow_classification
        ; test_case "Vibe 3.1.0 configOptions clamping & permission hardening" `Quick
            test_vibe_310_config_options_and_permission_hardening
        ; test_case "ACP overflow shrink handoff single-epoch & Vibe operator login prep/finish" `Quick
            test_acp_overflow_shrink_handoff_and_vibe_operator_login
        ] )
    ; ( "protocol_hardening"
      , [ test_case "typed tool_call_identity, schema boundary & acp_settings_json" `Quick
            test_typed_tool_call_classification_and_schema_boundary
        ; test_case "session/set_model, toolCallId permission correlation & activity idle liveness" `Quick
            test_set_model_toolcall_correlation_and_idle_liveness
        ; test_case "typed Tool_call_started effect fencing across postures" `Quick
            test_keeper_typed_tool_call_effect_fencing
        ; test_case "Layer 3 policy denies, posture mode clamp, UTF-8/secret stderr & fail-closed oauth"
            `Quick test_layer3_policy_mode_redaction_and_oauth_security
        ; test_case "Layer 3 isolated workspace, mode fail-closed, reconfigure, load replay & close_session"
            `Quick test_layer3_mock_session_lifecycle_load_reconfigure_close_and_mode_fail_closed
        ; test_case "Layer 4 prompt overflow classification, zero-usage, config hash & nudge hydration"
            `Quick test_layer4_classify_prompt_error_usage_context_and_process_config_hash
        ; test_case "Layer 4 SSE framing, InputJsonSnapshot, native tool callbacks & zero-usage suppression"
            `Quick test_layer4_stream_projection_sse_framing_native_tools_and_zero_usage
        ; test_case "Tool_call_updated monotonic escalation re-evaluates effect fence"
            `Quick test_tool_call_update_escalation_re_evaluates_effect_fence
        ; test_case "Implicit_mcp_kind multi-MCP server isolation & cross-driver kind=mcp fail-closed"
            `Quick test_implicit_mcp_kind_multi_server_isolation
        ] )
    ; ( "wire"
      , [ test_case "session update & usage parsing" `Quick test_parse_wire_updates_and_usage
        ; test_case "driver-aware usage normalization (vibe + agy live payloads)" `Quick
            test_driver_aware_usage_normalization
        ; test_case "exhaustive stop_reason mapping" `Quick test_stop_reason_mapping
        ] )
    ; "compaction", [ test_case "structural monotonic drop detection" `Quick test_compaction_detection ]
    ; ( "toml"
      , [ test_case "all three drivers materialize" `Quick test_toml_materialization_all_three_drivers
        ; test_case "muse_code row materializes and refuses effort" `Quick
            test_muse_toml_row_and_effort
        ; test_case "Muse model and binding effort admission" `Quick test_muse_binding_effort_admission
        ; test_case "unknown driver rejected" `Quick test_unknown_driver_rejected
        ; test_case "typed ACP effort and default model_selection TOML boundary" `Quick
            test_typed_acp_effort_and_model_selection_toml
        ] )
    ]
;;
