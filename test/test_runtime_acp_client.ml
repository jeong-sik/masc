open Alcotest
open Masc

let test_driver_profiles () =
  check int "three ACP drivers" 3 (List.length Runtime_acp_client.all_drivers);
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
    |> Runtime_acp_client.For_testing.parse_session_update
  in
  check bool "text delta parsed" true (text_ev = Some (Runtime_acp_client.Text_delta "hello"));
  let thought_ev =
    `Assoc
      [ "sessionUpdate", `String "agent_thought_chunk"
      ; "content", `Assoc [ "type", `String "text"; "text", `String "pondering" ]
      ]
    |> Runtime_acp_client.For_testing.parse_session_update
  in
  check bool "thought delta parsed" true
    (thought_ev = Some (Runtime_acp_client.Thought_delta "pondering"));
  let usage_ev =
    `Assoc
      [ "sessionUpdate", `String "usage_update"
      ; "used", `Int 11651
      ; "size", `Int 1048576
      ]
    |> Runtime_acp_client.For_testing.parse_session_update
  in
  (match usage_ev with
   | Some (Runtime_acp_client.Usage_updated { used = Some 11651; size = Some 1048576; _ }) -> ()
   | _ -> fail "expected Usage_updated with used=11651 size=1048576");
  let mode_ev =
    `Assoc
      [ "sessionUpdate", `String "current_mode_update"
      ; "currentModeId", `String "auto-approve"
      ]
    |> Runtime_acp_client.For_testing.parse_session_update
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
  (* Positive MASC MCP identities *)
  List.iter
    (fun (title, kind) ->
       check bool ("allows pinned MASC MCP tool " ^ title) true
         (allow ~policy:mcp_only ~title ~kind))
    [ "mcp__masc__keeper_skill", None
    ; "mcp_masc.masc_probe_ping", Some "other"
    ; "masc:masc_probe_ping", Some "mcp"
    ; "masc_masc_probe_ping", Some "other"
    ; "masc/keeper_skill", None
    ; "keeper_skill", Some "mcp"
    ];
  (* Negative security posture checks under Allow_masc_mcp_only *)
  check bool "denies foreign MCP server even when kind=mcp" false
    (allow ~policy:mcp_only ~title:"github__delete_repo" ~kind:(Some "mcp"));
  check bool "denies native execute tool whose title starts with masc_" false
    (allow ~policy:mcp_only ~title:"masc_rm_rf" ~kind:(Some "execute"));
  check bool "denies native execute tool even if suffix matches tool name" false
    (allow ~policy:mcp_only ~title:"masc_masc_probe_ping" ~kind:(Some "execute"));
  check bool "denies unpinned MASC-prefixed tool" false
    (allow ~policy:mcp_only ~title:"mcp__masc__unpinned_tool" ~kind:(Some "mcp"));
  check bool "denies native read tool under Native_none" false
    (allow ~policy:mcp_only ~title:"read_file" ~kind:(Some "read"));
  (* Native_read posture *)
  check bool "allows native read tool under Allow_read_and_masc_mcp" true
    (allow ~policy:read_and_mcp ~title:"read_file" ~kind:(Some "read"));
  check bool "still denies foreign MCP server under Allow_read_and_masc_mcp" false
    (allow ~policy:read_and_mcp ~title:"github__delete_repo" ~kind:(Some "mcp"));
  check bool "still denies masc_ execute under Allow_read_and_masc_mcp" false
    (allow ~policy:read_and_mcp ~title:"masc_rm_rf" ~kind:(Some "execute"))
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
    ; cwd = "/tmp/alice-a"
    ; dangerously_skip_permissions = false
    }
  in
  let bob_key : Keeper_acp_runtime.For_testing.pool_key =
    { keeper_name = "bob"
    ; runtime_id = "kimi_acp.k3_1_pro"
    ; tool_surface_sha256 = "sha-bob"
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
      origin = Agent_core.Llm_provider.Types.Agent_instruction
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
  (* Typed context-overflow RPC classification *)
  let overflow_err =
    Runtime_acp_client.Rpc_error
      { method_name = "session/prompt"
      ; code = -32000
      ; message = "Prompt is too long: maximum context length exceeded"
      }
  in
  check bool "overflow RPC detected" true
    (Runtime_acp_client.is_context_overflow_rpc_error
       ~method_name:"session/prompt"
       ~code:(-32000)
       ~message:"Prompt is too long: maximum context length exceeded");
  (match Keeper_acp_runtime.For_testing.acp_error_to_core_error overflow_err with
   | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _) -> ()
   | other -> failf "expected Api ContextOverflow, got %s" (Agent_core.Error.to_string other));
  (match Keeper_acp_runtime.For_testing.recovery_failure_of_acp_error overflow_err with
   | Keeper_official_client_session_store.Input_rejected
       Keeper_official_client_session_store.Bootstrap_floor_exceeded -> ()
   | other ->
     failf "expected Input_rejected Bootstrap_floor_exceeded, got %s"
       (Keeper_official_client_session_store.recovery_failure_to_string other));
  let plain_err =
    Runtime_acp_client.Rpc_error
      { method_name = "session/prompt"; code = -32602; message = "invalid params" }
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
  let resolve = Runtime_acp_client.For_testing.resolve_option_value in
  check (option string) "default model sentinel is skipped" None
    (resolve ~driver:Mistral_vibe ~config_id:"model" ~requested:"default" ~option:model_opt);
  check (option string) "retired devstral-2 is skipped when unsupported" None
    (resolve ~driver:Mistral_vibe ~config_id:"model" ~requested:"devstral-2" ~option:model_opt);
  check (option string) "already-current Vibe 3.1.0 model skips redundant RPC" None
    (resolve ~driver:Mistral_vibe ~config_id:"model" ~requested:"mistral-medium-3.5" ~option:model_opt);
  check (option string) "supported Vibe 3.1.0 model switch resolves" (Some "mistral-large-latest")
    (resolve ~driver:Mistral_vibe ~config_id:"model" ~requested:"mistral-large-latest" ~option:model_opt);
  check (option string) "none effort skips redundant RPC when currentValue is already off" None
    (resolve ~driver:Mistral_vibe ~config_id:"thinking" ~requested:"none" ~option:effort_opt);
  let effort_opt_high = { effort_opt with current_value = "high" } in
  check (option string) "none effort maps to off when switching from high" (Some "off")
    (resolve ~driver:Mistral_vibe ~config_id:"thinking" ~requested:"none" ~option:effort_opt_high);
  check (option string) "medium effort clamps to high on Vibe [off; high]" (Some "high")
    (resolve ~driver:Mistral_vibe ~config_id:"thinking" ~requested:"medium" ~option:effort_opt);
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
    (allow ~policy:read_and_mcp ~title:"fetch_url" ~kind:(Some "fetch"));
  check bool "unknown native tool kind is DENIED even with masc prefix" false
    (allow ~policy:read_and_mcp ~title:"mcp__masc__masc_probe_ping" ~kind:(Some "browser_eval"));
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
                "toolCall": {"title": "mcp__masc__masc_probe_ping", "kind": "mcp"},
                "options": [
                    {"optionId": "allow_once_id", "kind": "allow_once"},
                    {"optionId": "reject_once_id", "kind": "reject_once"}
                ]
            }})
            send({"jsonrpc": "2.0", "id": 9002, "method": "session/request_permission", "params": {
                "sessionId": "sess-spoofed",
                "toolCall": {"title": "mcp__masc__masc_probe_ping", "kind": "mcp"},
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
     | Ok Runtime_setup_login_receipt.Unselected -> ()
     | Ok (Published _ | Linked) -> fail "expected Unselected for Mistral_vibe operator initial account"
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
     | Ok Runtime_setup_login_receipt.Unselected -> ()
     | Ok (Published _ | Linked) -> fail "expected Unselected for Mistral_vibe operator finish_login"
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
    (* Mistral Vibe 3.1.0 structured _meta.tool_name *)
    check bool "allows Vibe _meta.tool_name mcp_masc.masc_probe_ping" true
      (allowed
         (`Assoc
            [ "toolCallId", `String "effect-1"
            ; "title", `String "mcp_masc.masc_probe_ping"
            ; "kind", `String "other"
            ; "_meta", `Assoc [ "tool_name", `String "mcp_masc.masc_probe_ping" ]
            ]));
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
    check (option string) "Vibe category=thinking maps none -> off" (Some "off")
      (Runtime_acp_client.For_testing.resolve_option_value
         ~driver:Mistral_vibe
         ~config_id:"thinking"
         ~requested:"none"
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
                # 1. Vibe 3.1.0 style: tool_call announces identity, request_permission sends ONLY toolCallId
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": sid,
                    "update": {
                        "sessionUpdate": "tool_call",
                        "toolCallId": "effect-vibe-1",
                        "title": "mcp_masc.masc_probe_ping",
                        "kind": "other",
                        "status": "in_progress",
                        "_meta": {"tool_name": "mcp_masc.masc_probe_ping"}
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
              ~model:"gemini-4-neon-medium"
              ~effort:"medium"
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
             ~model:"gemini-4-neon-medium"
             ~effort:"high"
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

let () =
  run "runtime_acp_client"
    [ "profiles", [ test_case "closed driver profiles" `Quick test_driver_profiles ]
    ; "environment", [ test_case "env strip and override" `Quick test_build_environment ]
    ; ( "argv_and_posture"
      , [ test_case "kimi --skills-dir order & strict permission posture" `Quick
            test_build_argv_and_strict_permission_posture
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
        ; test_case "unknown driver rejected" `Quick test_unknown_driver_rejected
        ] )
    ]
;;
