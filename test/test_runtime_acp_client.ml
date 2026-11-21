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
api-name = "devstral-2"
max-context = 400000

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
  check bool "bob still alive" false bob_1.closed
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
        ; test_case "key switch evicts superseded keeper entry only" `Quick
            test_pool_key_switch_evicts_superseded_keeper_entry
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
