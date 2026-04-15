open Alcotest
open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_room_state_recovery_" "" in
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
  Filename.concat (Filename.concat base_dir ".masc") "state.json"

let agent_path config agent_name =
  Filename.concat (Coord.agents_dir config) (Coord.safe_filename agent_name ^ ".json")

let test_read_state_repairs_empty_object () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:None);
      write_text_file (state_path base_dir) "{}";

      let state = Coord.read_state config in
      check string "protocol default" "0.1.0" state.protocol_version;
      check int "message_seq default" 0 state.message_seq;
      check (list string) "active_agents default" [] state.active_agents;

      let repaired_json = Coord.read_json config (state_path base_dir) in
      check string "repaired protocol" "0.1.0"
        (Safe_ops.json_string ~default:"" "protocol_version" repaired_json);
      check int "repaired message_seq" 0
        (Safe_ops.json_int ~default:(-1) "message_seq" repaired_json))

let test_read_state_recovers_legacy_active_agent_entries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:None);
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

      let state = Coord.read_state config in
      check int "message_seq preserved" 7 state.message_seq;
      check (list string) "legacy active_agents recovered"
        [ "codex-swift-fox"; "gemini-brave-bear"; "keeper-sangsu-agent" ]
        state.active_agents;

      let open Yojson.Safe.Util in
      let repaired_json = Coord.read_json config (state_path base_dir) in
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:None);
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

      let state = Coord.read_state config in
      check (list string) "invalid entries filtered"
        [ "codex-swift-fox"; "gemini-brave-bear" ]
        state.active_agents)

let test_agent_of_yojson_accepts_numeric_last_seen () =
  let json =
    `Assoc
      [
        ("name", `String "keeper-sangsu-agent");
        ("agent_type", `String "keeper");
        ("status", `String "active");
        ("capabilities", `List []);
        ("current_task", `Null);
        ("joined_at", `String "2026-03-26T00:00:00Z");
        ("last_seen", `Float 1711411200.0);
      ]
  in
  match Types.agent_of_yojson json with
  | Ok agent ->
      check string "agent parsed" "keeper-sangsu-agent" agent.name;
      check bool "last_seen normalized to ISO" true
        (String.length agent.last_seen > 0 && String.contains agent.last_seen 'T')
  | Error msg -> fail ("expected numeric last_seen compatibility: " ^ msg)

let test_heartbeat_repairs_legacy_agent_last_seen () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:None);
      let legacy_agent_json =
        `Assoc
          [
            ("name", `String "keeper-sangsu-agent");
            ("agent_type", `String "keeper");
            ("status", `String "active");
            ("capabilities", `List [ `String "heartbeat" ]);
            ("current_task", `Null);
            ("joined_at", `String "2026-03-26T00:00:00Z");
            ("last_seen", `Int 1711411200);
          ]
      in
      write_text_file (agent_path config "keeper-sangsu-agent")
        (Yojson.Safe.to_string legacy_agent_json);

      ignore (Coord.heartbeat config ~agent_name:"keeper-sangsu-agent");

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
  run "Coord_state_recovery"
    [
      ( "room_state",
        [
          test_case "repairs empty object" `Quick
            test_read_state_repairs_empty_object;
          test_case "recovers legacy active_agents entries" `Quick
            test_read_state_recovers_legacy_active_agent_entries;
          test_case "filters invalid active_agents entries" `Quick
            test_read_state_filters_invalid_active_agent_entries;
          test_case "agent parser accepts numeric last_seen" `Quick
            test_agent_of_yojson_accepts_numeric_last_seen;
          test_case "heartbeat repairs legacy agent last_seen" `Quick
            test_heartbeat_repairs_legacy_agent_last_seen;
        ] );
    ]
