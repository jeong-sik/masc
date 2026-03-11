open Alcotest

module Dashboard_mission_briefing = Masc_mcp.Dashboard_mission_briefing
module Briefing = Masc_mcp.Dashboard_mission_briefing.For_test
module Room = Masc_mcp.Room

let temp_dir () =
  let dir = Filename.temp_file "test_dashboard_mission_briefing_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  rm dir

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let get_field key = function
  | `Assoc fields -> List.assoc key fields
  | _ -> fail ("expected assoc for key " ^ key)

let check_string_field json key expected =
  let actual =
    match get_field key json with
    | `String value -> value
    | _ -> fail ("expected string field " ^ key)
  in
  check string key expected actual

let check_int_field json key expected =
  let actual =
    match get_field key json with
    | `Int value -> value
    | _ -> fail ("expected int field " ^ key)
  in
  check int key expected actual

let check_list_field json key expected_len =
  let actual_len =
    match get_field key json with
    | `List items -> List.length items
    | _ -> fail ("expected list field " ^ key)
  in
  check int key expected_len actual_len

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let test_disabled_override_returns_unavailable () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let config = Room.default_config base_path in
      ignore (Room.init config ~agent_name:None);
      with_env "MASC_DASHBOARD_BRIEFING_MODELS" "disabled" (fun () ->
        let json =
          Dashboard_mission_briefing.json
            ~config ~sw ~clock ~proc_mgr:None ()
        in
        let open Yojson.Safe.Util in
        check string "status" "unavailable"
          (json |> member "status" |> to_string);
        check bool "refreshing false" false
          (json |> member "refreshing" |> to_bool);
        check string "error reason"
          "No dashboard briefing model is available in the current environment."
          (json |> member "error" |> to_string)))

let test_compact_session_json_normalizes_missing_fields () =
  let json =
    `Assoc
      [
        ("session_id", `String "sess-1");
        ( "status",
          `Assoc
            [
              ("session", `Assoc [ ("goal", `Null); ("room_id", `Null); ("status", `Null) ]);
              ("summary", `Assoc []);
              ("team_health", `Assoc []);
              ("communication_metrics", `Assoc []);
            ] );
        ("recent_events", `List []);
      ]
  in
  let compact = Briefing.compact_session_json json in
  check_string_field compact "goal" "unassigned";
  check_string_field compact "room_id" "unknown-room";
  check_string_field compact "status" "unknown";
  check_list_field compact "agent_names" 0;
  check_int_field compact "active_agents_count" 0;
  check_string_field compact "communication_mode" "unknown";
  check_string_field compact "communication_summary" "unknown · broadcast 0 · portal 0"

let test_compact_keeper_json_normalizes_missing_fields () =
  let json =
    `Assoc
      [
        ("name", `String "keeper-a");
        ("status", `Null);
        ("agent_name", `Null);
        ("diagnostic", `Assoc []);
        ("agent", `Assoc [ ("current_task", `Null) ]);
      ]
  in
  let compact = Briefing.compact_keeper_json json in
  check_string_field compact "status" "unknown";
  check_string_field compact "agent_name" "unknown";
  check_string_field compact "current_task" "unassigned";
  check_string_field compact "last_reply_status" "not_recorded";
  check_string_field compact "last_reply_preview" "not_recorded";
  check_list_field compact "active_goal_ids" 0

let test_compact_agent_json_uses_current_focus () =
  let agent : Masc_mcp.Types.agent =
    {
      name = "worker-1";
      agent_type = "codex";
      capabilities = [ "ops"; "review"; "debug" ];
      current_task = None;
      status = Masc_mcp.Types.Active;
      joined_at = "2026-03-11T08:00:00Z";
      last_seen = "2026-03-11T08:05:00Z";
      meta = None;
    }
  in
  let compact = Briefing.compact_agent_json agent in
  check_string_field compact "assignment_status" "unassigned";
  check_string_field compact "current_focus" "unassigned";
  check_string_field compact "goal_hint" "unassigned";
  check_list_field compact "capabilities" 2

let test_relevant_sessions_for_briefing_filters_stale_terminal_sessions () =
  let now_ts = Unix.gettimeofday () in
  let stale_terminal =
    `Assoc
      [
        ("session_id", `String "old");
        ( "status",
          `Assoc
            [
              ("session", `Assoc [ ("room_id", `String "default"); ("status", `String "interrupted") ]);
              ("summary", `Assoc []);
            ] );
        ("recent_events", `List []);
      ]
  in
  let active_session =
    `Assoc
      [
        ("session_id", `String "live");
        ( "status",
          `Assoc
            [
              ("session", `Assoc [ ("room_id", `String "default"); ("status", `String "running") ]);
              ("summary", `Assoc []);
            ] );
        ( "recent_events",
          `List
            [
              `Assoc [ ("ts_iso", `String (iso_of_unix (now_ts -. 30.0))) ];
            ] );
      ]
  in
  let relevant =
    Briefing.relevant_sessions_for_briefing ~current_room:"default" ~now_ts
      [ stale_terminal; active_session ]
  in
  check int "relevant session count" 1 (List.length relevant);
  match relevant with
  | [ json ] -> check_string_field json "session_id" "live"
  | _ -> fail "expected one relevant session"

let test_collect_metadata_gaps_separates_null_like_inputs () =
  let sessions =
    [
      Briefing.compact_session_json
        (`Assoc
          [
            ("session_id", `String "sess-gap");
            ( "status",
              `Assoc
                [
                  ("session", `Assoc [ ("goal", `Null); ("room_id", `String "default") ]);
                  ("summary", `Assoc []);
                  ("team_health", `Assoc []);
                  ("communication_metrics", `Assoc []);
                ] );
            ("recent_events", `List []);
          ]);
    ]
  in
  let keepers =
    [
      Briefing.compact_keeper_json
        (`Assoc
          [
            ("name", `String "keeper-gap");
            ("diagnostic", `Assoc []);
            ("agent", `Assoc [ ("current_task", `Null) ]);
          ]);
    ]
  in
  let agent : Masc_mcp.Types.agent =
    {
      name = "agent-gap";
      agent_type = "codex";
      capabilities = [];
      current_task = None;
      status = Masc_mcp.Types.Active;
      joined_at = "2026-03-11T08:00:00Z";
      last_seen = "2026-03-11T08:05:00Z";
      meta = None;
    }
  in
  let gaps =
    Briefing.collect_metadata_gaps ~sessions ~keepers
      ~agents:[ Briefing.compact_agent_json agent ]
  in
  check int "gap count" 4 (List.length gaps)

let () =
  run "Dashboard Mission Briefing"
    [
      ( "env override",
        [
          test_case "disabled override returns unavailable" `Quick
            test_disabled_override_returns_unavailable;
        ] );
      ( "normalization",
        [
          test_case "session defaults" `Quick
            test_compact_session_json_normalizes_missing_fields;
          test_case "keeper defaults" `Quick
            test_compact_keeper_json_normalizes_missing_fields;
          test_case "agent current focus" `Quick
            test_compact_agent_json_uses_current_focus;
        ] );
      ( "filtering",
        [
          test_case "stale terminal sessions filtered" `Quick
            test_relevant_sessions_for_briefing_filters_stale_terminal_sessions;
          test_case "metadata gaps collected" `Quick
            test_collect_metadata_gaps_separates_null_like_inputs;
        ] );
    ]
