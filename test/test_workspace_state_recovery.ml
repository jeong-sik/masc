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

let raw_state_file base_dir =
  match Safe_ops.read_file_safe (state_path base_dir) with
  | Error error -> fail error
  | Ok raw -> raw

let stored_state config base_dir =
  match
    Masc_domain.workspace_state_of_yojson
      (Workspace.read_json config (state_path base_dir))
  with
  | Ok state -> state
  | Error error -> fail ("stored state.json does not decode: " ^ error)

let test_read_state_leaves_undecodable_state_untouched () =
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
      (match Workspace.observe_state config with
       | Workspace.State_recovered { fault = Workspace.State_schema_fault _; _ } -> ()
       | Workspace.State_recovered { fault = Workspace.State_document_fault _; _ } ->
         fail "an empty object parses; the fault is its schema"
       | Workspace.State_absent _ -> fail "state.json is there"
       | Workspace.State_decoded _ -> fail "an empty object is not a workspace state");
      check string "the reads wrote nothing" "{}" (raw_state_file base_dir))

(* #51419: the MCP status resources read on a system thread, where the store's
   write lock cannot be taken. A read that repaired the document there poisoned
   that lock, and every later write of state.json was lost. *)
let test_status_resource_read_keeps_state_writable () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let server = Mcp_server_eio.For_testing.create_state ~base_path:base_dir () in
      let config = Mcp_server.workspace_config server in
      ignore (Workspace.init config ~agent_name:None);
      write_text_file (state_path base_dir) "{}";
      let read_resource uri =
        let response =
          Mcp_server_eio_resource.handle_read_resource_eio
            server
            (`Int 1)
            (Some (`Assoc [ "uri", `String uri ]))
        in
        let open Yojson.Safe.Util in
        match response |> member "result" |> member "contents" with
        | `List [ content ] -> content |> member "text" |> to_string
        | _ -> fail (uri ^ " returned no content: " ^ Yojson.Safe.to_string response)
      in
      let status_json = Yojson.Safe.from_string (read_resource "masc://status.json") in
      check string "status.json says the state was recovered" "recovered"
        Yojson.Safe.Util.(
          status_json |> member "state_read" |> member "outcome" |> to_string);
      let status_text = read_resource "masc://status" in
      check bool "status says state.json did not decode" true
        (Astring.String.is_infix ~affix:"state.json did not decode" status_text);
      check string "the resource reads wrote nothing" "{}" (raw_state_file base_dir);

      let updated =
        Workspace.update_state config (fun state ->
          { state with project = "written-after-the-read" })
      in
      check string "the write after the read is stored" updated.project
        (stored_state config base_dir).project)

(* [is_initialized] reads [state.json], so reading the state of a workspace
   that was never initialized must leave it uninitialized. *)
let test_read_state_does_not_create_state_json () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      let state = Workspace.read_state config in
      check string "declared default" "0.1.0" state.protocol_version;
      check bool "no state.json written" false
        (Sys.file_exists (state_path base_dir));
      check bool "still not initialized" false (Workspace.is_initialized config))

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
                  `Assoc [ ("agent_name", `String "keeper-alpha-agent") ];
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

      check string "the read wrote nothing" (Yojson.Safe.to_string legacy_json)
        (raw_state_file base_dir);

      (* The next state write is what replaces the undecodable document. *)
      check int "the next message number follows the recovered counter" 8
        (Workspace.next_seq config);
      check (list string) "that write stores the canonical active_agents"
        state.active_agents
        (stored_state config base_dir).active_agents)

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

let agent_fields_without_last_seen =
  [
    ("name", `String "keeper-orphan");
    ("agent_type", `String "keeper");
    ("status", `String "active");
    ("capabilities", `List []);
    ("current_task", `Null);
    ("session_bound_at", `String "2026-03-26T00:00:00Z");
  ]

let expect_agent_decode_error ~label json =
  match Masc_domain.agent_of_yojson json with
  | Ok agent -> fail (label ^ " must not decode, got agent " ^ agent.name)
  | Error _ -> ()

let test_agent_of_yojson_rejects_numeric_last_seen () =
  expect_agent_decode_error ~label:"float last_seen"
    (`Assoc (("last_seen", `Float 1711411200.0) :: agent_fields_without_last_seen));
  expect_agent_decode_error ~label:"int last_seen"
    (`Assoc (("last_seen", `Int 1711411200) :: agent_fields_without_last_seen))

let test_agent_of_yojson_rejects_null_last_seen () =
  expect_agent_decode_error ~label:"null last_seen"
    (`Assoc (("last_seen", `Null) :: agent_fields_without_last_seen))

let test_agent_of_yojson_rejects_missing_last_seen () =
  expect_agent_decode_error ~label:"missing last_seen"
    (`Assoc agent_fields_without_last_seen)

let test_agent_of_yojson_rejects_missing_session_bound_at () =
  expect_agent_decode_error ~label:"missing session_bound_at"
    (`Assoc
       (("last_seen", `String "2026-03-26T00:00:00Z")
        :: List.remove_assoc "session_bound_at" agent_fields_without_last_seen))

let raw_agent_file config name =
  match Safe_ops.read_file_safe (agent_path config name) with
  | Error error -> fail error
  | Ok raw -> raw

let test_read_agent_leaves_undecodable_file_untouched () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      let written = Yojson.Safe.to_string (`Assoc agent_fields_without_last_seen) in
      write_text_file (agent_path config "keeper-orphan") written;
      (match Workspace.read_agent config (agent_path config "keeper-orphan") with
       | Ok agent -> fail ("missing last_seen must not decode: " ^ agent.name)
       | Error _ -> ());
      check string "file bytes unchanged after the failed read" written
        (raw_agent_file config "keeper-orphan"))

let test_heartbeat_reports_invalid_file_for_numeric_last_seen () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      let written =
        Yojson.Safe.to_string
          (`Assoc (("last_seen", `Int 1711411200) :: agent_fields_without_last_seen))
      in
      write_text_file (agent_path config "keeper-orphan") written;
      (match Workspace.heartbeat config ~agent_name:"keeper-orphan" with
       | Workspace.Agent_file_invalid name ->
           check string "heartbeat names the undecodable agent" "keeper-orphan" name
       | Workspace.Heartbeat_updated _ -> fail "numeric last_seen must not heartbeat"
       | Workspace.Agent_not_found _ -> fail "the agent file exists");
      check string "file bytes unchanged after the rejected heartbeat" written
        (raw_agent_file config "keeper-orphan"))

let agents_drop_count () =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_persistence_read_drops
    ~labels:
      [
        ("surface", "workspace_agents");
        ("reason", Read_drop_reason.to_wire Read_drop_reason.Entry_load_error);
      ]
    ()

let test_listing_drops_and_counts_undecodable_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:None);
      write_text_file (agent_path config "claude-steady-otter")
        (Yojson.Safe.to_string
           (`Assoc
              [
                ("name", `String "claude-steady-otter");
                ("agent_type", `String "claude");
                ("status", `String "active");
                ("capabilities", `List []);
                ("current_task", `Null);
                ("session_bound_at", `String "2026-03-26T00:00:00Z");
                ("last_seen", `String "2026-03-26T00:00:00Z");
              ]));
      write_text_file (agent_path config "keeper-orphan")
        (Yojson.Safe.to_string
           (`Assoc (("last_seen", `Float 1711411200.0) :: agent_fields_without_last_seen)));
      let before = agents_drop_count () in
      let names =
        Workspace.get_agents_raw config
        |> List.map (fun (agent : Masc_domain.agent) -> agent.name)
      in
      check (list string) "only the decodable agent is listed"
        [ "claude-steady-otter" ] names;
      check (float 0.0) "the dropped row is counted once" (before +. 1.0)
        (agents_drop_count ()))

let () =
  run "Workspace_state_recovery"
    [
      ( "workspace_state",
        [
          test_case "a read leaves an undecodable state.json untouched" `Quick
            test_read_state_leaves_undecodable_state_untouched;
          test_case "state.json stays writable after the status resources read it"
            `Quick test_status_resource_read_keeps_state_writable;
          test_case "reading an uninitialized workspace writes nothing" `Quick
            test_read_state_does_not_create_state_json;
          test_case "the next write replaces legacy active_agents objects" `Quick
            test_read_state_drops_legacy_active_agent_objects;
          test_case "filters invalid active_agents entries" `Quick
            test_read_state_filters_invalid_active_agent_entries;
          test_case "agent parser rejects numeric last_seen" `Quick
            test_agent_of_yojson_rejects_numeric_last_seen;
          test_case "agent parser rejects null last_seen" `Quick
            test_agent_of_yojson_rejects_null_last_seen;
          test_case "agent parser rejects missing last_seen" `Quick
            test_agent_of_yojson_rejects_missing_last_seen;
          test_case "agent parser rejects missing session_bound_at" `Quick
            test_agent_of_yojson_rejects_missing_session_bound_at;
          test_case "read_agent leaves an undecodable file untouched" `Quick
            test_read_agent_leaves_undecodable_file_untouched;
          test_case "heartbeat reports Agent_file_invalid for numeric last_seen" `Quick
            test_heartbeat_reports_invalid_file_for_numeric_last_seen;
          test_case "listing drops and counts an undecodable agent file" `Quick
            test_listing_drops_and_counts_undecodable_agent;
        ] );
    ]
