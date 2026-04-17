open Alcotest

module Dashboard_mission_briefing = Masc_mcp.Dashboard_mission_briefing
module Briefing = Masc_mcp.Dashboard_mission_briefing.For_test
module Coord = Masc_mcp.Coord

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

let find_section sections id =
  sections
  |> List.find_opt (fun json ->
         match get_field "id" json with
         | `String value -> String.equal value id
         | _ -> false)
  |> function
  | Some json -> json
  | None -> fail ("missing section " ^ id)

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let test_briefing_cold_call_returns_pending () =
  (* After #2094, cold calls (no cache) return "pending" and trigger async refresh.
     This avoids blocking the dashboard on cold-start computation. *)
  (* Force filesystem backend to prevent PG auto-detection in hermetic tests *)
  let saved_storage = Sys.getenv_opt "MASC_STORAGE_TYPE" in
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Briefing.reset_cache ();
      cleanup_dir base_path;
      (match saved_storage with
       | Some v -> Unix.putenv "MASC_STORAGE_TYPE" v
       | None -> Unix.putenv "MASC_STORAGE_TYPE" ""))
    (fun () ->
      Briefing.reset_cache ();
      let config = Coord.default_config base_path in
      ignore (Coord.init config ~agent_name:None);
      let json =
        Dashboard_mission_briefing.json
          ~config ~sw ~clock ~proc_mgr:None ()
      in
      let open Yojson.Safe.Util in
      (* Cold call now computes synchronously instead of returning pending *)
      check string "cold call returns ok" "ok"
        (json |> member "status" |> to_string);
      check bool "refreshing false on cold call" false
        (json |> member "refreshing" |> to_bool))

let test_force_refresh_without_cache_returns_pending () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Briefing.reset_cache ();
      cleanup_dir base_path)
    (fun () ->
      Briefing.reset_cache ();
      let config = Coord.default_config base_path in
      ignore (Coord.init config ~agent_name:None);
      let json =
        Dashboard_mission_briefing.json
          ~force:true ~config ~sw ~clock ~proc_mgr:None ()
      in
      let open Yojson.Safe.Util in
      check string "status pending" "pending"
        (json |> member "status" |> to_string);
      check bool "refreshing true" true
        (json |> member "refreshing" |> to_bool))

let test_force_refresh_with_cached_result_returns_stale_cached_payload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Briefing.reset_cache ();
      cleanup_dir base_path)
    (fun () ->
      Briefing.reset_cache ();
      let config = Coord.default_config base_path in
      ignore (Coord.init config ~agent_name:None);
      Briefing.seed_cache
        ~cached_at:(Unix.gettimeofday ())
        (`Assoc
          [
            ("generated_at", `String "2026-03-11T00:00:00Z");
            ("cached", `Bool false);
            ("stale", `Bool false);
            ("refreshing", `Bool false);
            ("status", `String "ok");
            ("summary", `String "cached summary");
            ("provenance", `String "narrative");
            ("authoritative", `Bool false);
            ("model", `String "deterministic");
            ("ttl_sec", `Int 300);
            ("criteria", `List []);
            ("sections", `List []);
            ("error", `Null);
            ("last_error", `Null);
          ]);
      let json =
        Dashboard_mission_briefing.json
          ~force:true ~config ~sw ~clock ~proc_mgr:None ()
      in
      let open Yojson.Safe.Util in
      check string "status ok" "ok"
        (json |> member "status" |> to_string);
      check bool "cached true" true
        (json |> member "cached" |> to_bool);
      check bool "stale true" true
        (json |> member "stale" |> to_bool);
      check bool "refreshing true" true
        (json |> member "refreshing" |> to_bool);
      check string "summary preserved" "cached summary"
        (json |> member "summary" |> to_string))

let test_compact_session_json_normalizes_missing_fields () =
  let json =
    `Assoc
      [
        ("session_id", `String "sess-1");
        ( "status",
          `Assoc
            [
              ("session", `Assoc [ ("goal", `Null); ("status", `Null) ]);
              ("summary", `Assoc []);
              ("team_health", `Assoc []);
              ("communication_metrics", `Assoc []);
            ] );
        ("recent_events", `List []);
      ]
  in
  let compact = Briefing.compact_session_json json in
  check_string_field compact "goal" "unassigned";
  check_string_field compact "project" "default";
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
  let agent : Types.agent =
    {
      name = "worker-1";
      agent_type = "codex";
      capabilities = [ "ops"; "review"; "debug" ];
      current_task = None;
      status = Types.Active;
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
              ("session", `Assoc [ ("project", `String "default"); ("status", `String "interrupted") ]);
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
              ("session", `Assoc [ ("project", `String "default"); ("status", `String "running") ]);
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
    Briefing.relevant_sessions_for_briefing ~current_namespace:"default" ~now_ts
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
                  ("session", `Assoc [ ("goal", `Null); ("namespace_id", `String "default") ]);
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
  let agent : Types.agent =
    {
      name = "agent-gap";
      agent_type = "codex";
      capabilities = [];
      current_task = None;
      status = Types.Active;
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

let test_collect_metadata_gaps_ignores_inactive_agents () =
  let inactive_agent : Types.agent =
    {
      name = "agent-idle";
      agent_type = "codex";
      capabilities = [];
      current_task = None;
      status = Types.Inactive;
      joined_at = "2026-03-11T08:00:00Z";
      last_seen = "2026-03-11T08:05:00Z";
      meta = None;
    }
  in
  let active_agent : Types.agent =
    {
      inactive_agent with
      name = "agent-live";
      status = Types.Active;
    }
  in
  let gaps =
    Briefing.collect_metadata_gaps ~sessions:[] ~keepers:[]
      ~agents:
        [
          Briefing.compact_agent_json inactive_agent;
          Briefing.compact_agent_json active_agent;
        ]
  in
  check int "only live unassigned agent becomes a gap" 1 (List.length gaps);
  match gaps with
  | [ json ] -> check_string_field json "kind" "agent_focus_missing"
  | _ -> fail "expected one live agent focus gap"

let test_build_briefing_sections_demotes_metadata_only_communication () =
  let mission_summary_json =
    `Assoc
      [
        ("room_health", `String "ok");
        ("incident_count", `Int 0);
        ("recommended_action_count", `Int 0);
        ("top_attention_summary", `String "");
      ]
  in
  let watch_summary, sections =
    Briefing.build_briefing_sections ~mission_summary_json ~sessions:[]
      ~agents:[] ~recent_messages:[]
      ~metadata_gaps:
        [
          `Assoc
            [
              ("kind", `String "keeper_last_reply_missing");
              ("summary", `String "Keeper last reply status is not recorded.");
              ("scope_type", `String "keeper");
              ("scope_id", `String "keeper-a");
              ("severity", `String "info");
            ];
        ]
  in
  let communication = find_section sections "communication" in
  let watch = find_section sections "watch" in
  check string "watch summary" "No immediate operator action is flagged by the namespace summary."
    watch_summary;
  check_string_field communication "status" "unclear";
  check_string_field communication "signal_class" "metadata_gap";
  check_string_field communication "evidence_quality" "missing";
  check_string_field watch "status" "ok"

let test_build_briefing_sections_keeps_metadata_evidence_visible () =
  let mission_summary_json =
    `Assoc
      [
        ("room_health", `String "ok");
        ("incident_count", `Int 0);
        ("recommended_action_count", `Int 0);
        ("top_attention_summary", `String "");
      ]
  in
  let session =
    `Assoc
      [
        ("session_id", `String "sess-live");
        ("goal", `String "goal-a");
        ("namespace_id", `String "default");
        ("status", `String "running");
        ("agent_names", `List []);
        ("elapsed_sec", `Int 10);
        ("progress_pct", `Float 0.1);
        ("done_delta_total", `Int 0);
        ("team_health", `String "ok");
        ("active_agents_count", `Int 1);
        ("required_agents", `Int 1);
        ("communication_mode", `String "broadcast");
        ("broadcast_count", `Int 1);
        ("portal_count", `Int 0);
        ("communication_summary", `String "broadcast · broadcast 1 · portal 0");
        ("last_event", `Assoc []);
      ]
  in
  let _watch_summary, sections =
    Briefing.build_briefing_sections ~mission_summary_json ~sessions:[ session ]
      ~agents:[] ~recent_messages:[ `Assoc [ ("from", `String "agent-a") ] ]
      ~metadata_gaps:
        [
          `Assoc
            [
              ("kind", `String "keeper_last_reply_missing");
              ("summary", `String "Keeper last reply status is not recorded.");
              ("scope_type", `String "keeper");
              ("scope_id", `String "keeper-a");
              ("severity", `String "info");
            ];
        ]
  in
  let communication = find_section sections "communication" in
  check_string_field communication "status" "watch";
  match get_field "evidence" communication with
  | `List items ->
      let found =
        List.exists
          (function
            | `String value ->
                String.equal value "Keeper last reply status is not recorded."
            | _ -> false)
          items
      in
      check bool "metadata evidence remains visible" true found
  | _ -> fail "expected communication evidence list"

let test_build_briefing_sections_watch_evidence_uses_namespace_wording () =
  let mission_summary_json =
    `Assoc
      [
        ("room_health", `String "bad");
        ("incident_count", `Int 0);
        ("recommended_action_count", `Int 0);
        ("top_attention_summary", `String "");
      ]
  in
  let _watch_summary, sections =
    Briefing.build_briefing_sections ~mission_summary_json ~sessions:[]
      ~agents:[] ~recent_messages:[]
      ~metadata_gaps:[]
  in
  let watch = find_section sections "watch" in
  match get_field "evidence" watch with
  | `List (`String evidence :: _) ->
      check string "watch evidence wording" "Namespace health is bad" evidence
  | _ -> fail "expected watch evidence list"

let () =
  run "Dashboard Mission Briefing"
    [
      ( "deterministic",
        [
          test_case "cold call returns pending" `Quick
            test_briefing_cold_call_returns_pending;
          test_case "force refresh without cache returns pending" `Quick
            test_force_refresh_without_cache_returns_pending;
          test_case "force refresh with cache returns stale cached payload" `Quick
            test_force_refresh_with_cached_result_returns_stale_cached_payload;
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
          test_case "inactive agents ignored for focus gaps" `Quick
            test_collect_metadata_gaps_ignores_inactive_agents;
          test_case "metadata-only communication becomes unclear" `Quick
            test_build_briefing_sections_demotes_metadata_only_communication;
          test_case "metadata evidence remains visible in communication" `Quick
            test_build_briefing_sections_keeps_metadata_evidence_visible;
          test_case "watch evidence uses namespace wording" `Quick
            test_build_briefing_sections_watch_evidence_uses_namespace_wording;
        ] );
    ]
