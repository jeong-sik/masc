open Masc_mcp
open Test_tool_team_session_support

let test_missing_required_args () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let ok1, _ = dispatch_exn ctx ~name:"masc_team_session_start" ~args:(`Assoc []) in
  let ok2, _ = dispatch_exn ctx ~name:"masc_team_session_status" ~args:(`Assoc []) in
  let ok3, _ = dispatch_exn ctx ~name:"masc_team_session_stop" ~args:(`Assoc []) in
  let ok4, _ = dispatch_exn ctx ~name:"masc_team_session_report" ~args:(`Assoc []) in
  let ok5, _ =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String "../escape") ])
  in
  let ok6, _ =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:(`Assoc [ ("session_id", `String "../../etc/passwd") ])
  in
  let ok7, _ =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:(`Assoc [ ("session_id", `String "bad-id") ])
  in
  let ok8, _ =
    dispatch_exn ctx ~name:"masc_team_session_compare"
      ~args:(`Assoc [ ("base_session_id", `String "bad-id") ])
  in
  let ok9, _ =
    dispatch_exn ctx ~name:"masc_team_session_list"
      ~args:(`Assoc [ ("status", `String "not-a-status") ])
  in
  let ok10, _ =
    dispatch_exn ctx ~name:"masc_team_session_turn" ~args:(`Assoc [])
  in
  let ok11, _ =
    dispatch_exn ctx ~name:"masc_team_session_events" ~args:(`Assoc [])
  in
  let ok12, _ =
    dispatch_exn ctx ~name:"masc_team_session_prove" ~args:(`Assoc [])
  in
  let ok13, _ =
    dispatch_exn ctx ~name:"masc_team_session_step" ~args:(`Assoc [])
  in
  let ok14, _ =
    dispatch_exn ctx ~name:"masc_team_session_finalize" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "start invalid" false ok1;
  Alcotest.(check bool) "status invalid" false ok2;
  Alcotest.(check bool) "stop invalid" false ok3;
  Alcotest.(check bool) "report invalid" false ok4;
  Alcotest.(check bool) "status traversal invalid" false ok5;
  Alcotest.(check bool) "stop traversal invalid" false ok6;
  Alcotest.(check bool) "report format invalid" false ok7;
  Alcotest.(check bool) "compare invalid" false ok8;
  Alcotest.(check bool) "list invalid status" false ok9;
  Alcotest.(check bool) "turn invalid" false ok10;
  Alcotest.(check bool) "events invalid" false ok11;
  Alcotest.(check bool) "prove invalid" false ok12;
  Alcotest.(check bool) "step invalid" false ok13;
  Alcotest.(check bool) "finalize invalid" false ok14;
  cleanup_dir base_dir

let test_step_actor_must_match_caller () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"step-actor-must-match-caller" |> get_session_id
  in
  let ok, body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("actor", `String "planner");
            ("message", `String "spoofed note");
          ])
  in
  Alcotest.(check bool) "step rejects actor mismatch" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "status error" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "actor mismatch message"
    "actor must match the authenticated caller; omit actor to use the current agent"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_step_spawn_requires_proc_mgr () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-proc-manager-check" |> get_session_id in
  let step_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_agent", `String "glm");
            ("spawn_prompt", `String "hello");
          ])
  in
  Alcotest.(check bool) "step should fail without proc_mgr for spawn" false step_ok;
  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_step_spawn" ]);
          ])
  in
  Alcotest.(check bool) "events query ok" true events_ok;
  let events = events_list_of_body events_body in
  Alcotest.(check int) "spawn failure event recorded" 1 (List.length events);
  let first = List.hd events in
  let detail = Yojson.Safe.Util.member "detail" first in
  let success = detail |> Yojson.Safe.Util.member "success" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "spawn failure success=false" false success;
  let error_msg =
    detail |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string_option
    |> Option.value ~default:""
  in
  Alcotest.(check bool) "spawn failure has error" true (String.trim error_msg <> "");
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "cleanup");
             ("generate_report", `Bool false);
           ]));
  ignore (wait_until_terminal ctx session_id);
  cleanup_dir base_dir

let test_step_spawn_llama_requires_spawn_model () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let selection_note =
    "[model-selection] leader selected qwen3.5-35b-a3b-ud-q8-xl from inventory"
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-llama-model-check" |> get_session_id in
  let step_ok, step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_agent", `String "llama");
            ("spawn_prompt", `String "inspect and report");
            ("spawn_role", `String "planner");
            ("spawn_selection_note", `String selection_note);
          ])
  in
  Alcotest.(check bool) "step should fail without spawn_model for llama" false step_ok;
  let body = parse_json_exn step_body in
  let message =
    body |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "error mentions spawn_model" true
    (try
       let _ = Str.search_forward (Str.regexp_string "spawn_model") message 0 in
       true
     with Not_found -> false);
  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_step_spawn" ]);
          ])
  in
  Alcotest.(check bool) "events query ok" true events_ok;
  let events = events_list_of_body events_body in
  Alcotest.(check int) "spawn failure event recorded" 1 (List.length events);
  let detail = Yojson.Safe.Util.member "detail" (List.hd events) in
  let spawn_model =
    detail |> Yojson.Safe.Util.member "spawn_model"
  in
  Alcotest.(check bool) "spawn_model absent in failure event" true (spawn_model = `Null);
  let attached_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_attached")
  in
  Alcotest.(check int) "no phantom attachment on validation failure" 0
    (List.length attached_events);
  let recorded_selection_note =
    detail |> Yojson.Safe.Util.member "spawn_selection_note"
    |> Yojson.Safe.Util.to_string_option
  in
  let recorded_selection_note =
    match recorded_selection_note with
    | Some value -> value
    | None -> Alcotest.fail "selection note missing in failure event"
  in
  Alcotest.(check bool) "selection note preserved in failure event" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string selection_note)
           recorded_selection_note 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "routing summary appended in failure event" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "[routing]")
           recorded_selection_note 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

