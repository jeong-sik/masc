module Types = Masc_domain

open Alcotest
open Masc

let temp_dir () =
  let dir = Filename.temp_file "test_workspace_state_recovery_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let write_text_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let state_path base_dir =
  Filename.concat (Filename.concat base_dir Common.masc_dirname) "state.json"

let agent_path config agent_name =
  Filename.concat (Workspace.agents_dir config) (Workspace.safe_filename agent_name ^ ".json")

let test_read_state_repairs_empty_object () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      write_text_file (state_path base_dir) "{}";

      let state = Workspace.read_state config in
      check string "protocol default" "0.1.0" state.protocol_version;
      check int "message_seq default" 0 state.message_seq;
      check (list string) "active_agents default" [] state.active_agents;

      let repaired_json = Workspace.read_json config (state_path base_dir) in
      check string "repaired protocol" "0.1.0"
        (Safe_ops.json_string ~default:"" "protocol_version" repaired_json);
      check int "repaired message_seq" 0
        (Safe_ops.json_int ~default:(-1) "message_seq" repaired_json))

let test_read_state_drops_legacy_active_agent_objects () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      let legacy_json =
        `Assoc
          [
            ("protocol_version", `String "0.1.0");
            ("project", `String (Filename.basename base_dir));
            ("started_at", `String "2026-03-26T00:00:00Z");
            ("message_seq", `Int 7);
            ( "active_agents",
              `List
                [
                  `Assoc [ ("name", `String "codex-swift-fox") ];
                  `String "gemini-brave-bear";
                  `Assoc [ ("agent_name", `String "keeper-sangsu-agent") ];
                  `Assoc [ ("id", `String "ignored") ];
                ] );
          ]
      in
      write_text_file (state_path base_dir) (Yojson.Safe.to_string legacy_json);

      let state = Workspace.read_state config in
      check int "message_seq preserved" 7 state.message_seq;
      check (list string) "only canonical string active_agents recovered"
        [ "gemini-brave-bear" ]
        state.active_agents;

      let open Yojson.Safe.Util in
      let repaired_json = Workspace.read_json config (state_path base_dir) in
      let repaired_agents =
        repaired_json |> member "active_agents" |> to_list |> List.map to_string
      in
      check (list string) "canonical active_agents rewritten" state.active_agents
        repaired_agents)

let test_read_state_filters_invalid_active_agent_entries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      let corrupted_json =
        `Assoc
          [
            ("protocol_version", `String "0.1.0");
            ("project", `String (Filename.basename base_dir));
            ("started_at", `String "2026-03-26T00:00:00Z");
            ( "active_agents",
              `List
                [
                  `Assoc [];
                  `Bool true;
                  `Assoc [ ("name", `String "codex-swift-fox") ];
                  `String "";
                  `String "gemini-brave-bear";
                ] );
          ]
      in
      write_text_file (state_path base_dir) (Yojson.Safe.to_string corrupted_json);

      let state = Workspace.read_state config in
      check (list string) "invalid entries filtered"
        [ "gemini-brave-bear" ]
        state.active_agents)

let test_read_state_result_reports_repair_write_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      write_text_file (state_path base_dir) "{}";
      let masc_dir = Filename.concat base_dir Common.masc_dirname in
      Unix.chmod masc_dir 0o500;
      Fun.protect
        ~finally:(fun () -> Unix.chmod masc_dir 0o755)
        (fun () ->
          match Workspace.read_state_result config with
          | Ok _ -> fail "repair write failure must be reported"
          | Error
              (Workspace.State_repair_write_failed
                 { decode_error; write_error; recovered_state }) ->
              check bool "decode error reported" true (String.length decode_error > 0);
              check bool "write error reported" true (String.length write_error > 0);
              check string "recovered protocol" "0.1.0"
                recovered_state.protocol_version;
              let snapshot = Workspace.read_state_snapshot config in
              check string "snapshot status" "recovered_unpersisted"
                (Workspace.read_state_status_to_string snapshot.status);
              check int "snapshot read error count" 1
                (List.length snapshot.read_errors)
          | Error (Workspace.State_read_failed msg) ->
              fail ("expected repair write failure, got read failure: " ^ msg)))

let test_read_state_result_reports_unreadable_state_path () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      Unix.unlink (state_path base_dir);
      Unix.mkdir (state_path base_dir) 0o755;
      match Workspace.read_state_result config with
      | Ok _ -> fail "directory state path must be reported as read failure"
      | Error (Workspace.State_repair_write_failed _) ->
          fail "directory state path should fail before repair"
      | Error (Workspace.State_read_failed msg) ->
          check bool "read failure message reported" true (String.length msg > 0);
          let snapshot = Workspace.read_state_snapshot config in
          check string "snapshot status" "default_from_read_error"
            (Workspace.read_state_status_to_string snapshot.status);
          check int "snapshot read error count" 1
            (List.length snapshot.read_errors))

let test_state_result_helpers_report_unreadable_state_path () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      Unix.unlink (state_path base_dir);
      Unix.mkdir (state_path base_dir) 0o755;
      let expect_error label = function
        | Ok _ -> fail (label ^ " unexpectedly succeeded")
        | Error msg ->
            check bool (label ^ " read failure") true (String.length msg > 0)
      in
      expect_error
        "update_state_result"
        (Workspace.update_state_result config (fun state ->
           { state with message_seq = state.message_seq + 1 }));
      expect_error "is_paused_result" (Workspace.is_paused_result config);
      expect_error "pause_info_result" (Workspace.pause_info_result config))

let test_agent_of_yojson_accepts_numeric_last_seen () =
  let json =
    `Assoc
      [
        ("name", `String "keeper-sangsu-agent");
        ("agent_type", `String "keeper");
        ("status", `String "active");
        ("capabilities", `List []);
        ("current_task", `Null);
        ("session_bound_at", `String "2026-03-26T00:00:00Z");
        ("last_seen", `Float 1711411200.0);
      ]
  in
  match Masc_domain.agent_of_yojson json with
  | Ok agent ->
      check string "agent parsed" "keeper-sangsu-agent" agent.name;
      check bool "last_seen normalized to ISO" true
        (String.length agent.last_seen > 0 && String.contains agent.last_seen 'T')
  | Error msg -> fail ("expected numeric last_seen compatibility: " ^ msg)

let test_agent_of_yojson_bootstraps_null_last_seen_from_session_bound_at () =
  (* #7947 Layer 2: null last_seen must be repaired from session_bound_at rather than
     dropping the whole agent record (which loses current_task/meta). *)
  let json =
    `Assoc
      [
        ("name", `String "gemini-cool-whale");
        ("agent_type", `String "gemini");
        ("status", `String "busy");
        ("capabilities", `List []);
        ("current_task", `String "task-208");
        ("session_bound_at", `String "2026-04-15T03:00:00Z");
        ("last_seen", `Null);
      ]
  in
  match Masc_domain.agent_of_yojson json with
  | Ok agent ->
      check string "agent parsed" "gemini-cool-whale" agent.name;
      check (option string) "current_task preserved"
        (Some "task-208") agent.current_task;
      check string "last_seen bootstrapped from session_bound_at"
        "2026-04-15T03:00:00Z" agent.last_seen
  | Error msg ->
      fail ("null last_seen should bootstrap from session_bound_at: " ^ msg)

let test_agent_of_yojson_annotates_invalid_last_seen () =
  (* #7947 Layer 1: when repair is not possible, the error message must
     include the actual offending value so operators can diagnose the
     schema drift instead of seeing only the field path. *)
  let json =
    `Assoc
      [
        ("name", `String "gemini-cool-whale");
        ("agent_type", `String "gemini");
        ("status", `String "busy");
        ("capabilities", `List []);
        ("current_task", `Null);
        ("session_bound_at", `Bool true);
        ("last_seen", `Bool false);
      ]
  in
  match Masc_domain.agent_of_yojson json with
  | Ok _ -> fail "bool last_seen should not succeed without a usable session_bound_at"
  | Error msg ->
      let contains needle =
        let n = String.length needle in
        let h = String.length msg in
        let rec loop i =
          if i + n > h then false
          else if String.sub msg i n = needle then true
          else loop (i + 1)
        in
        loop 0
      in
      check bool "error mentions last_seen value" true
        (contains "last_seen=")

let test_agent_of_yojson_missing_last_seen_falls_back_to_now () =
  (* #9751: when last_seen is entirely absent AND session_bound_at is not a usable
     string, fall back to a current-wall-clock timestamp rather than
     failing the whole record. last_seen is a liveness marker, not
     identity-critical. *)
  let json =
    `Assoc
      [
        ("name", `String "keeper-orphan");
        ("agent_type", `String "keeper");
        ("status", `String "active");
        ("capabilities", `List []);
        ("current_task", `Null);
        (* no session_bound_at, no last_seen *)
      ]
  in
  match Masc_domain.agent_of_yojson json with
  | Ok agent ->
      check string "agent parsed without last_seen or session_bound_at"
        "keeper-orphan" agent.name;
      check bool "last_seen populated with ISO timestamp" true
        (String.length agent.last_seen > 0
         && String.contains agent.last_seen 'T'
         && String.contains agent.last_seen 'Z')
  | Error msg ->
      fail ("missing last_seen+session_bound_at should fall back, not error: " ^ msg)

let test_read_agent_with_repair_rewrites_missing_last_seen () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      let legacy_agent_json =
        `Assoc
          [
            ("name", `String "keeper-orphan");
            ("agent_type", `String "keeper");
            ("status", `String "active");
            ("capabilities", `List []);
            ("current_task", `Null);
            ("session_bound_at", `String "2026-03-26T00:00:00Z");
          ]
      in
      write_text_file (agent_path config "keeper-orphan")
        (Yojson.Safe.to_string legacy_agent_json);

      match Workspace.read_agent_with_repair config (agent_path config "keeper-orphan") with
      | Error msg -> fail ("missing last_seen should repair: " ^ msg)
      | Ok agent ->
          check string "last_seen bootstrapped from session_bound_at"
            "2026-03-26T00:00:00Z" agent.last_seen;
          let repaired_json =
            match Safe_ops.read_file_safe (agent_path config "keeper-orphan") with
            | Error error -> fail error
            | Ok raw ->
                raw
                |> Backend.Compression.decompress_auto
                |> Yojson.Safe.from_string
          in
          check bool "last_seen rewritten as canonical string" true
            (match Yojson.Safe.Util.member "last_seen" repaired_json with
             | `String "2026-03-26T00:00:00Z" -> true
             | _ -> false))

let test_heartbeat_repairs_legacy_agent_last_seen () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      let legacy_agent_json =
        `Assoc
          [
            ("name", `String "keeper-sangsu-agent");
            ("agent_type", `String "keeper");
            ("status", `String "active");
            ("capabilities", `List [ `String "heartbeat" ]);
            ("current_task", `Null);
            ("session_bound_at", `String "2026-03-26T00:00:00Z");
            ("last_seen", `Int 1711411200);
          ]
      in
      write_text_file (agent_path config "keeper-sangsu-agent")
        (Yojson.Safe.to_string legacy_agent_json);

      ignore (Workspace.heartbeat config ~agent_name:"keeper-sangsu-agent");

      let repaired_json =
        match Safe_ops.read_file_safe (agent_path config "keeper-sangsu-agent") with
        | Error error -> fail error
        | Ok raw ->
            raw
            |> Backend.Compression.decompress_auto
            |> Yojson.Safe.from_string
      in
      check bool "last_seen rewritten as string" true
        (match Yojson.Safe.Util.member "last_seen" repaired_json with
         | `String value -> String.length value > 0
         | _ -> false))

let () =
  run "Workspace_state_recovery"
    [
      ( "workspace_state",
        [
          test_case "repairs empty object" `Quick
            test_read_state_repairs_empty_object;
          test_case "drops legacy active_agents objects" `Quick
            test_read_state_drops_legacy_active_agent_objects;
          test_case "filters invalid active_agents entries" `Quick
            test_read_state_filters_invalid_active_agent_entries;
          test_case "read_state_result reports repair write failure" `Quick
            test_read_state_result_reports_repair_write_failure;
          test_case "read_state_result reports unreadable state path" `Quick
            test_read_state_result_reports_unreadable_state_path;
          test_case "state result helpers report unreadable state path" `Quick
            test_state_result_helpers_report_unreadable_state_path;
          test_case "agent parser accepts numeric last_seen" `Quick
            test_agent_of_yojson_accepts_numeric_last_seen;
          test_case "agent parser bootstraps null last_seen from session_bound_at (#7947)" `Quick
            test_agent_of_yojson_bootstraps_null_last_seen_from_session_bound_at;
          test_case "agent parser error annotates invalid last_seen (#7947)" `Quick
            test_agent_of_yojson_annotates_invalid_last_seen;
          test_case "agent parser falls back when both last_seen and session_bound_at missing (#9751)" `Quick
            test_agent_of_yojson_missing_last_seen_falls_back_to_now;
          test_case "read_agent_with_repair rewrites missing last_seen" `Quick
            test_read_agent_with_repair_rewrites_missing_last_seen;
          test_case "heartbeat repairs legacy agent last_seen" `Quick
            test_heartbeat_repairs_legacy_agent_last_seen;
        ] );
    ]
