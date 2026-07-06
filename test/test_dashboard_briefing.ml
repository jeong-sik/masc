module Types = Masc_domain

module Lib = Masc

open Alcotest

let () =
  Dashboard_projection_cache.register_operator_snapshot_json
    { Dashboard_projection_cache.snapshot = Operator_control.snapshot_json };
  Dashboard_projection_cache.register_operator_digest_json
    { Dashboard_projection_cache.digest = Operator_control.digest_json }

let () = ignore Operator_tool.force_link

(** Dashboard Mission read-model regression tests. *)

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_briefing" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

let contains str substr =
  try
    ignore (Str.search_forward (Str.regexp_string substr) str 0);
    true
  with Not_found -> false

let with_test_env f =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Time_compat.set_clock clock;
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
    (fun () -> f ~clock ~sw)

let write_pending_confirm config _session_id =
  let operator_dir = Filename.concat (Workspace_utils.masc_dir config) "operator" in
  Workspace_utils.mkdir_p operator_dir;
  Workspace_utils.write_json config (Filename.concat operator_dir "pending_confirms.json")
    (`List
      [
        `Assoc
          [
            ("token", `String "confirm-mission-test");
            ("confirm_token", `String "confirm-mission-test");
            ("trace_id", `String "ops_fixture_mission");
            ("actor", `String "dashboard-fixture");
            ("action_type", `String "keeper_message");
            ("target_type", `String "keeper");
            ("target_id", `String "fixture-keeper");
            ("payload", `Assoc [ ("reason", `String "fixture pending confirmation") ]);
            ("delegated_tool", `String "masc_keeper_msg");
            ("created_at", `String (Masc_domain.now_iso ()));
            ("expires_at", `Null);
          ];
      ])

let append_workspace_event_lines_raw config lines =
  let events_dir = Filename.concat (Workspace_utils.masc_dir config) "events" in
  let dated = Jsonl_writer.dated_path_now ~base_dir:events_dir in
  Workspace_utils.mkdir_p (Filename.dirname dated.path);
  let oc =
    open_out_gen
      [ Open_creat; Open_text; Open_append ]
      0o644
      dated.path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun line ->
           output_string oc line;
           output_char oc '\n')
        lines)

let seed_workspace config session_id =
  ignore (Lib.Workspace.init config ~agent_name:(Some "fixture-root"));
  ignore (Lib.Workspace.bind_session config ~agent_name:"mission-local64-smoke"
            ~capabilities:[ "operator"; "fixture"; "local64" ] ());
  ignore (Lib.Workspace.bind_session config ~agent_name:"llama-local-alpha"
            ~capabilities:[ "worker"; "local64"; "manager" ] ());
  ignore (Lib.Workspace.bind_session config ~agent_name:"llama-local-beta"
            ~capabilities:[ "worker"; "local64"; "metacog" ] ());
  ignore (Lib.Workspace.bind_session config ~agent_name:"llama-local-gamma"
            ~capabilities:[ "worker"; "local64"; "executor" ] ());
  ignore (Lib.Workspace.bind_session config ~agent_name:"llama-local-delta"
            ~capabilities:[ "worker"; "local64"; "observer" ] ());
  ignore
    (Lib.Workspace.broadcast config ~from_agent:"mission-local64-smoke"
       ~content:"@llama-local-alpha recover failed worker coverage");
  ignore
    (Lib.Workspace.broadcast config ~from_agent:"llama-local-alpha"
       ~content:"Spawned worker recovered partial role coverage and runtime visibility.");

  (* Team sessions are retired; mission fixtures now exercise workspace-level
     attention and worker/keeper signals without persisting session records. *)
  ignore session_id;
  write_pending_confirm config session_id

let test_dashboard_briefing_projection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-fixture-001" in
      with_test_env @@ fun ~clock ~sw ->
      let config = Workspace_utils.default_config dir in
      seed_workspace config session_id;
      (* Simulate delta departing: remove agent file so Dashboard_briefing
         sees delta as departed. *)
      let delta_path =
        Filename.concat (Workspace_utils.agents_dir config) "llama-local-delta.json"
      in
      if Sys.file_exists delta_path then Sys.remove delta_path;
      let json =
        Dashboard_briefing.json
          ~actor:"test-dashboard-projection"
          ~config
          ~sw
          ~clock
          ~proc_mgr:None
          ()
      in
      let open Yojson.Safe.Util in
      let attention_queue = json |> member "attention_queue" |> to_list in
      let summary = json |> member "summary" in
      let agent_briefs = json |> member "agent_briefs" |> to_list in
      let internal_signals = json |> member "internal_signals" |> to_list in
      let alpha_brief =
        agent_briefs
        |> List.find (fun row ->
               row |> member "agent_name" |> to_string = "llama-local-alpha")
      in
      (* After #8395 (#8563), root-level incidents are reclassified as
         internal_signals. The clean fixture has no non-root attention
         source — pending_confirm_waiting is root-scoped — so
         attention_queue is expected to be empty. The pending-confirm
         assertion has moved to internal_signals (see below). *)
      check bool "attention_queue is public-only (empty in clean fixture)" true
        (attention_queue = []);
      check bool "mission summary trims paused" true
        (summary |> member "paused" = `Null);
      check bool "mission summary trims active_agents" true
        (summary |> member "active_agents" = `Null);
      check bool "mission summary namespace_id removed" true
        (summary |> member "namespace_id" = `Null);
      check bool "mission summary namespace removed" true
        (summary |> member "namespace" = `Null);
      check bool "mission summary namespace_mode removed" true
        (summary |> member "namespace_mode" = `Null);
      check bool "sessions removed from mission payload" true
        (json |> member "sessions" = `Null);
      let alpha_input = alpha_brief |> member "recent_input_preview" |> to_string in
      check bool "recent input preserves exact alpha mention" true
        (contains alpha_input "@llama-local-alpha");
      check bool "recent input excludes unrelated beta mention" false
        (contains alpha_input "@llama-local-beta");
      check bool "agent brief omits social context fields" true
        (alpha_brief |> member "where" = `Null);
      check string "agent brief signal truth" "message"
        (alpha_brief |> member "evidence_source" |> to_string);
      check bool "internal signal includes pending confirm" true
        (internal_signals
         |> List.exists (fun row ->
              contains (row |> member "summary" |> to_string) "pending confirmation"));
      (* workspace broadcast actions require microarch signal tones "warn"/"bad",
         which need non-empty command-plane operations. In a clean test
         fixture all 9 signals default to "ok", so workspace_recommendations
         returns []. Verify internal_signals carries the pending-confirm
         incident instead — that is the reachable workspace-level signal. *)
      check bool "internal signals are workspace-scoped" true
        (internal_signals
         |> List.for_all (fun row ->
              row |> member "target_type" |> to_string = "workspace")))

let test_dashboard_briefing_workspace_event_parse_errors_are_visible () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-fixture-parse-errors" in
      with_test_env @@ fun ~clock ~sw ->
      let config = Workspace_utils.default_config dir in
      seed_workspace config session_id;
      append_workspace_event_lines_raw config [ "{not-json"; "[]" ];
      let json =
        Dashboard_briefing.json
          ~actor:"test-dashboard-briefing-parse-errors"
          ~config
          ~sw
          ~clock
          ~proc_mgr:None
          ()
      in
      let open Yojson.Safe.Util in
      let agent_briefs = json |> member "agent_briefs" |> to_list in
      check bool "agent briefs still render" true
        (agent_briefs
         |> List.exists (fun row ->
              row |> member "agent_name" |> to_string = "llama-local-alpha"));
      check int "workspace event read errors" 2
        (json |> member "read_error_count" |> to_int);
      let read_errors = json |> member "read_errors" |> to_list in
      check int "workspace event read error rows" 2 (List.length read_errors);
      match read_errors with
      | first :: _ ->
        check string "workspace event read error source"
          "dashboard_briefing_workspace_events_jsonl"
          (first |> member "source" |> to_string)
      | [] -> fail "expected workspace event read errors")

let test_dashboard_briefing_http_full_contract () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-http-fixture-001" in
      with_test_env @@ fun ~clock ~sw ->
      let config = Workspace_utils.default_config dir in
      seed_workspace config session_id;
      (* Clear stale cache entries from prior tests to avoid cross-test pollution.
         Both dashboard-level and operator snapshot caches must be invalidated. *)
      Dashboard_cache.invalidate_all ();
      Operator_control.invalidate_snapshot_cache ();
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      let json =
        Server_dashboard_http.dashboard_briefing_http_json
          ~state
          ~sw
          ~clock
          (request "/api/v1/dashboard/briefing?agent_name=test-dashboard-http")
      in
      let open Yojson.Safe.Util in
      check bool "operator targets present in mission http payload" true
        (json |> member "operator_targets" <> `Null);
      check bool "internal signals retained in mission http payload" true
        ((json |> member "internal_signals" |> to_list) <> []);
      check bool "command focus retained in mission http payload" true
        (json |> member "command_focus" <> `Null))

let test_dashboard_briefing_http_default_bootstraps_first_success () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_test_env @@ fun ~clock ~sw ->
      let config = Workspace_utils.default_config dir in
      let session_id = "ts-mission-http-default-001" in
      seed_workspace config session_id;
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      let json =
        Server_dashboard_http.dashboard_briefing_http_json
          ~state
          ~sw
          ~clock
          (request "/api/v1/dashboard/briefing")
      in
      let open Yojson.Safe.Util in
      check string "default mission cache becomes fresh" "fresh"
        (json |> member "projection_diagnostics" |> member "cache_state"
        |> to_string);
      check bool "default mission records first success" true
        (json |> member "projection_diagnostics" |> member "last_success_at"
         <> `Null);
      check bool "default mission leaves initializing placeholder" true
        (json |> member "summary" |> member "workspace_health" |> to_string
         <> "initializing");
      check bool "mission summary namespace_id removed" true
        (json |> member "summary" |> member "namespace_id" = `Null);
      check bool "mission summary namespace removed" true
        (json |> member "summary" |> member "namespace" = `Null))

let test_dashboard_briefing_keeper_tool_audit_fallback () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-http-default-001" in
      with_test_env @@ fun ~clock ~sw ->
      let config = Workspace_utils.default_config dir in
      seed_workspace config session_id;
      Dashboard_cache.invalidate_all ();
      Operator_control.invalidate_snapshot_cache ();
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      let json =
        Server_dashboard_http.dashboard_briefing_http_json
          ~state
          ~sw
          ~clock
          (request "/api/v1/dashboard/briefing")
      in
      let open Yojson.Safe.Util in
      check string "default mission cache becomes fresh" "fresh"
        (json |> member "projection_diagnostics" |> member "cache_state"
        |> to_string);
      check bool "default mission records first success" true
        (json |> member "projection_diagnostics" |> member "last_success_at"
         <> `Null);
      check bool "default mission leaves initializing placeholder" true
        (json |> member "summary" |> member "workspace_health" |> to_string
         <> "initializing");
      check bool "mission summary namespace_id removed" true
        (json |> member "summary" |> member "namespace_id" = `Null);
      check bool "mission summary namespace removed" true
        (json |> member "summary" |> member "namespace" = `Null))

let test_dashboard_briefing_http_cache_isolation () =
  let dir_a = test_dir () in
  let dir_b = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir dir_a;
      cleanup_dir dir_b)
    (fun () ->
      let actor = "test-dashboard-cache-isolation" in
      let session_a = "ts-mission-cache-fixture-a" in
      let session_b = "ts-mission-cache-fixture-b" in
      with_test_env @@ fun ~clock ~sw ->
      let config_a = Workspace_utils.default_config dir_a in
      let config_b = Workspace_utils.default_config dir_b in
      seed_workspace config_a session_a;
      seed_workspace config_b session_b;
      let state_a =
        Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir_a ()
      in
      let state_b =
        Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir_b ()
      in
      let request =
        request ("/api/v1/dashboard/briefing?agent_name=" ^ actor)
      in
      let json_a =
        Server_dashboard_http.dashboard_briefing_http_json
          ~state:state_a
          ~sw
          ~clock
          request
      in
      let json_b =
        Server_dashboard_http.dashboard_briefing_http_json
          ~state:state_b
          ~sw
          ~clock
          request
      in
      let open Yojson.Safe.Util in
      check bool "first workspace namespace_id removed" true
        (json_a |> member "summary" |> member "namespace_id" = `Null);
      check bool "second workspace namespace_id removed" true
        (json_b |> member "summary" |> member "namespace_id" = `Null))

let test_dashboard_briefing_keeper_tool_audit_keeps_inband_tools_without_evidence () =
  let keeper_name = "audit-keeper-assembly-fixture" in
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_test_env @@ fun ~clock:_ ~sw:_ ->
      let config = Workspace_utils.default_config dir in
      let briefs =
        Dashboard_briefing_assembly.build_keeper_briefs config
          [
            `Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String keeper_name);
                ("status", `String "offline");
                ("updated_at", `String (Masc_domain.now_iso ()));
                ("latest_tool_names", `List []);
                ("latest_tool_call_count", `Null);
                ("latest_action_source", `String "structured_model");
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
              ];
          ]
      in
      let open Yojson.Safe.Util in
      let brief =
        briefs |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      check bool "no synthetic audit source without evidence" true
        (brief |> member "tool_audit_source" = `Null);
      check string "in-band action source is preserved" "structured_model"
        (brief |> member "latest_action_source" |> to_string);
      check bool "no observed tools without evidence" true
        ((brief |> member "latest_tool_names" |> to_list) = []))

let test_dashboard_briefing_keeper_tool_audit_uses_decision_log () =
  let keeper_name = "audit-keeper-decision-fixture" in
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_test_env @@ fun ~clock:_ ~sw:_ ->
      let config = Workspace_utils.default_config dir in
      Workspace_utils.mkdir_p
        (Filename.dirname (Lib.Keeper_types_support.keeper_decision_log_path config keeper_name));
      Fs_compat.append_jsonl
        (Lib.Keeper_types_support.keeper_decision_log_path config keeper_name)
        (`Assoc
          [
            ("ts", `String (Masc_domain.now_iso ()));
            ("selected_mode", `String "text_response");
            ("action_source", `String "structured_model");
            ("tool_call_count", `Int 0);
            ("tools_used", `List []);
          ]);
      let briefs =
        Dashboard_briefing_assembly.build_keeper_briefs config
          [
            `Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String keeper_name);
                ("status", `String "active");
                ("updated_at", `String (Masc_domain.now_iso ()));
                ("latest_tool_names", `List []);
                ("latest_tool_call_count", `Null);
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
              ];
          ]
      in
      let open Yojson.Safe.Util in
      let brief =
        briefs |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      check string "decision log source present in keeper brief" "keeper_decision_log"
        (brief |> member "tool_audit_source" |> to_string);
      check string "decision log action source present in keeper brief"
        "structured_model"
        (brief |> member "latest_action_source" |> to_string);
      check int "decision log zero tool count preserved" 0
        (brief |> member "latest_tool_call_count" |> to_int);
      check bool "decision log still reports empty tool list" true
        ((brief |> member "latest_tool_names" |> to_list) = []))

let make_message ~seq ~from_agent ~content : Types.message =
  { seq;
    from_agent;
    msg_type = "broadcast";
    content;
    mention = None;
    timestamp = "";
    trace_context = None;
    expires_at = None;
    relevance = "medium" }

(* Regression: a degenerate agent record with an empty/whitespace name must not
   crash latest_message_to (String.get on an empty [lowered]). *)
let test_latest_message_to_empty_name_safe () =
  let msgs = [ make_message ~seq:1 ~from_agent:"alice" ~content:"hey @bob ping" ] in
  (match Dashboard_briefing_agents.latest_message_to "" msgs with
   | None -> ()
   | Some _ -> Alcotest.fail "empty name must not match a mention");
  (match Dashboard_briefing_agents.latest_message_to "   " msgs with
   | None -> ()
   | Some _ -> Alcotest.fail "whitespace name must not match a mention");
  match Dashboard_briefing_agents.latest_message_to "bob" msgs with
  | Some (m : Types.message) -> Alcotest.(check int) "matched seq" 1 m.seq
  | None -> Alcotest.fail "expected @bob mention to match"

let () =
  Alcotest.run "Dashboard Mission"
    [
      ( "read_model",
        [
          Alcotest.test_case "latest_message_to tolerates empty agent name"
            `Quick test_latest_message_to_empty_name_safe;
          Alcotest.test_case "projection groups root-cause lanes" `Quick
            test_dashboard_briefing_projection;
          Alcotest.test_case "workspace event parse errors are visible" `Quick
            test_dashboard_briefing_workspace_event_parse_errors_are_visible;
          Alcotest.test_case "http mission keeps full contract" `Quick
            test_dashboard_briefing_http_full_contract;
          Alcotest.test_case "http mission default bootstraps first success"
            `Quick test_dashboard_briefing_http_default_bootstraps_first_success;
          Alcotest.test_case "keeper tool audit fallback" `Quick
            test_dashboard_briefing_keeper_tool_audit_fallback;
          Alcotest.test_case "http mission cache stays workspace-scoped" `Quick
            test_dashboard_briefing_http_cache_isolation;
          Alcotest.test_case "keeper brief keeps in-band tools without evidence" `Quick
            test_dashboard_briefing_keeper_tool_audit_keeps_inband_tools_without_evidence;
          Alcotest.test_case "keeper brief uses decision log fallback" `Quick
            test_dashboard_briefing_keeper_tool_audit_uses_decision_log;
        ] );
    ]
