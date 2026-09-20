open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let dir = Filename.temp_file "test_dashboard_tool_host_events_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let test_report_of_yojson_defaults () =
  let json =
    `Assoc
      [
        ("tool_name", `String "masc_keeper_msg");
        ("cause_code", `String "tool_host_timeout");
        ("message", `String "timed out awaiting tools/call after 120s");
      ]
  in
  match Dashboard_tool_host_events.report_of_yojson ~fallback_agent:"codex" json with
  | Error err -> fail err
  | Ok report ->
      check string "agent defaulted from fallback" "codex" report.agent_name;
      check string "client defaulted from fallback" "codex" report.client_name;
      check string "transport default" "mcp_http" report.transport;
      check bool "typed timeout cause" true
        (report.cause = Failure_envelope.Tool_host_timeout);
      check (option string) "phase missing" None report.phase

let test_report_of_yojson_accepts_stringish_ids () =
  let json =
    `Assoc
      [
        ("client_name", `String "codex");
        ("tool_name", `String "masc_keeper_msg");
        ("cause_code", `String "tool_host_timeout");
        ("message", `String "timed out awaiting tools/call after 120s");
        ("request_id", `Int 42);
        ("session_id", `String "sess-1");
        ("trace_id", `String "trace-1");
        ("timeout_ms", `Int 120000);
        ("phase", `String "tools/call");
      ]
  in
  match Dashboard_tool_host_events.report_of_yojson json with
  | Error err -> fail err
  | Ok report ->
      check (option string) "request_id" (Some "42") report.request_id;
      check (option int) "timeout_ms" (Some 120000) report.timeout_ms;
      check (option string) "trace_id" (Some "trace-1") report.trace_id

let test_report_rejects_missing_or_unknown_cause () =
  let payload cause =
    `Assoc
      ([
         ("tool_name", `String "masc_keeper_msg");
         ("message", `String "operator-facing detail");
       ]
       @ cause)
  in
  let check_error label expected json =
    match Dashboard_tool_host_events.report_of_yojson json with
    | Ok _ -> failf "%s: expected Error" label
    | Error actual -> check string label expected actual
  in
  check_error
    "missing cause"
    "missing required field: cause_code"
    (payload []);
  check_error
    "unknown cause"
    "unknown tool host cause_code: \"browser_said_no\""
    (payload [ ("cause_code", `String "browser_said_no") ]);
  check_error
    "padded cause"
    "unknown tool host cause_code: \" tool_host_timeout \""
    (payload [ ("cause_code", `String " tool_host_timeout ") ]);
  check_error
    "non-string cause"
    "field cause_code must be a JSON string"
    (payload [ ("cause_code", `Int 1) ])

let test_record_writes_audit_ring_and_telemetry () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace.default_config base_dir in
      let report =
        {
          Dashboard_tool_host_events.agent_name = "codex";
          client_name = "codex";
          tool_name = "masc_keeper_msg";
          transport = "mcp_http";
          phase = Some "tools/call";
          cause = Failure_envelope.Tool_host_timeout;
          message = "timed out awaiting tools/call after 120s";
          request_id = Some "99";
          session_id = Some "sess-99";
          trace_id = Some "trace-99";
          timeout_ms = Some 120000;
        }
      in
      Dashboard_tool_host_events.record ~fs:() config ~reported_by:"reporter" report;
      let entries = Audit_log.read_entries ~n:20 config in
      let matching =
        List.find_opt
          (fun (entry : Audit_log.audit_entry) ->
            match entry.action with
            | Audit_log.Custom "client_tool_host_failure" -> true
            | _ -> false)
          entries
      in
      let entry =
        match matching with
        | Some entry -> entry
        | None -> fail "expected client_tool_host_failure audit entry"
      in
      check string "audit reporter" "reporter" entry.agent_id;
      check string "audit subject" report.agent_name
        Yojson.Safe.Util.(entry.details |> member "reported_agent" |> to_string);
      (match entry.outcome with
      | Audit_log.Failure reason ->
          check string "failure reason" report.message reason
      | Audit_log.Success -> fail "expected failure outcome");
      let latest =
        match
          Log.Ring.recent ~limit:20 ()
          |> List.find_opt (fun (row : Log.Ring.entry) ->
            String.equal (Log.source_to_string row.source) "client_tool_host"
            && String.equal row.module_name "ToolHost")
        with
        | Some row -> row
        | None -> fail "expected client_tool_host ring entry"
      in
      check string "ring source" "client_tool_host"
        (Log.source_to_string latest.source);
      check string "ring module" "ToolHost" latest.module_name;
      check bool "ring details object" true
        (match latest.details with `Assoc _ -> true | _ -> false);
      let failure_envelope =
        Yojson.Safe.Util.member "failure_envelope" latest.details
      in
      check string "failure cause code" "tool_host_timeout"
        Yojson.Safe.Util.(failure_envelope |> member "cause_code" |> to_string);
      check string "failure recoverability" "operator_action_required"
        Yojson.Safe.Util.
          (failure_envelope |> member "recoverability" |> to_string);
      check string "failure operator action" "masc_operator_digest"
        Yojson.Safe.Util.
          (failure_envelope |> member "operator_action" |> to_string);
      check string "failure evidence request_id" "99"
        Yojson.Safe.Util.
          (failure_envelope |> member "evidence_ref" |> member "request_id"
         |> to_string);
      let telemetry_events = Telemetry_eio.read_all_events config in
      let has_client_error =
        List.exists
          (fun (entry : Telemetry_eio.event_record) ->
            match entry.event with
            | Telemetry_eio.Error_occurred { code; context; _ } ->
                String.equal code "client_tool_host_failure"
                && String.contains context '='
            | _ -> false)
          telemetry_events
      in
      check bool "telemetry error recorded" true has_client_error)

let test_explicit_cause_is_not_reparsed_from_message () =
  let payload =
    `Assoc
      [
        ("client_name", `String "codex");
        ("tool_name", `String "masc_keeper_msg");
        ("transport", `String "mcp_http");
        ("phase", `String "tools/call");
        ("cause_code", `String "tool_host_transport_unavailable");
        ("message", `String "timed out after connection refused");
        ("request_id", `String "transport-1");
        ("timeout_ms", `Int 120000);
      ]
  in
  let report =
    match Dashboard_tool_host_events.report_of_yojson payload with
    | Ok report -> report
    | Error error -> fail error
  in
  let details = Dashboard_tool_host_events.details_json report in
  let failure_envelope = Yojson.Safe.Util.member "failure_envelope" details in
  check string
    "typed transport cause wins"
    "tool_host_transport_unavailable"
    Yojson.Safe.Util.(failure_envelope |> member "cause_code" |> to_string)

let test_blank_entity_id_is_normalized_out () =
  let details =
    Dashboard_tool_host_events.details_json
      {
        agent_name = "codex";
        client_name = "codex";
        tool_name = "masc_keeper_msg";
        transport = "mcp_http";
        phase = Some "tools/call";
        cause = Failure_envelope.Tool_host_transport_unavailable;
        message = "upstream returned malformed payload";
        request_id = Some "   ";
        session_id = Some "";
        trace_id = Some "trace-7";
        timeout_ms = None;
      }
  in
  let failure_envelope = Yojson.Safe.Util.member "failure_envelope" details in
  check string "normalized entity_id uses first non-empty id" "trace-7"
    Yojson.Safe.Util.(failure_envelope |> member "entity_id" |> to_string);
  check bool "blank request_id omitted from evidence" true
    Yojson.Safe.Util.
      (failure_envelope |> member "evidence_ref" |> member "request_id" = `Null);
  check bool "blank session_id omitted from evidence" true
    Yojson.Safe.Util.
      (failure_envelope |> member "evidence_ref" |> member "session_id" = `Null)

let with_report_route ~auth_enabled f =
  let base_path = temp_dir () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Fs_compat.clear_fs ();
      cleanup_dir base_path)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with
          enabled = auth_enabled; require_token = auth_enabled };
      let token =
        match Auth.create_token base_path ~agent_name:"reporter" ~role:Masc_domain.Worker with
        | Ok (token, _) -> token
        | Error error -> fail (Masc_domain.masc_error_to_string error)
      in
      Server_auth.For_testing.restore_server_state (Some state);
      let router = Server_routes_http_routes_dashboard.add_routes ~sw
        ~clock:(Eio.Stdenv.clock env) (Http_server_eio.Router.create ()) in
      let send ?token ?(include_names = true) () =
        let authority =
          match Server_request_authority.of_host_port ~host:"localhost" ~port:8935 with
          | Ok authority -> authority
          | Error `Malformed -> fail "invalid test authority"
        in
        Server_request_authority.with_current authority (fun () ->
          let body = Yojson.Safe.to_string (`Assoc
            ((if include_names then ["agent_name", `String "reported-agent"] else [])
            @ [ "client_name", `String "test-client"
            ; "tool_name", `String "masc_keeper_msg"
            ; "cause_code", `String "tool_host_timeout"
            ; "message", `String "synthetic tool timeout" ])) in
          let authorization = match token with
            | None -> ""
            | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
          let actor_header =
            if include_names then "X-Masc-Agent: local-reporter\r\n" else "" in
          let request = Printf.sprintf
            "POST /api/v1/dashboard/logs/tool-host-failures HTTP/1.1\r\nHost: localhost:8935\r\nOrigin: http://localhost:8935\r\n%s%sContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
            authorization actor_header (String.length body) body in
          let output = Buffer.create 256 in
          let connection = Httpun.Server_connection.create (fun reqd ->
            Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
          let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
          ignore (Httpun.Server_connection.read_eof connection input ~off:0
            ~len:(Bigstringaf.length input));
          let rec drain () =
            match Httpun.Server_connection.next_write_operation connection with
            | `Write iovecs ->
              let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                total + iov.len) 0 iovecs in
              Httpun.Server_connection.report_write_result connection (`Ok bytes);
              drain ()
            | `Yield | `Close _ -> ()
          in
          drain ();
          match String.split_on_char ' ' (Buffer.contents output) with
          | _ :: status :: _ -> int_of_string status
          | _ -> fail "missing HTTP response")
      in
      f ~config ~token ~send)

let report_entries config =
  Audit_log.read_entries ~n:20 config
  |> List.filter (fun (entry : Audit_log.audit_entry) ->
    entry.action = Audit_log.Custom "client_tool_host_failure")

let check_report_actor ?(reported_agent = "reported-agent") config expected_actor =
  let entry = match report_entries config with
    | [entry] -> entry
    | _ -> fail "expected one stored failure report"
  in
  check string "audit actor is the reporting caller" expected_actor entry.agent_id;
  check string "event actor is the reporting caller" expected_actor
    Yojson.Safe.Util.(Audit_log.audit_event_json entry |> member "actor" |> to_string);
  check string "reported subject remains separate" reported_agent
    Yojson.Safe.Util.(entry.details |> member "reported_agent" |> to_string)

let test_report_route_binds_bearer_reporter () =
  with_report_route ~auth_enabled:true (fun ~config ~token ~send ->
    check int "bearer report accepted" 200 (send ~token ());
    check_report_actor config "reporter")

let test_report_route_preserves_local_reporter () =
  with_report_route ~auth_enabled:false (fun ~config ~token:_ ~send ->
    check int "local report accepted" 200 (send ());
    check_report_actor config "local-reporter")

let test_report_route_keeps_subject_fallback () =
  with_report_route ~auth_enabled:false (fun ~config ~token:_ ~send ->
    check int "unnamed local report accepted" 200 (send ~include_names:false ());
    check_report_actor ~reported_agent:"test-client" config "dashboard")

let test_report_route_rejects_unauthorized_reports () =
  with_report_route ~auth_enabled:true (fun ~config ~token:_ ~send ->
    check int "missing credential rejected" 401 (send ());
    check int "invalid credential rejected" 401 (send ~token:"invalid-credential" ());
    check int "no failure report stored" 0 (List.length (report_entries config)))

let () =
  run "Dashboard_tool_host_events"
    [
      ( "dashboard_tool_host_events",
        [
          test_case "report defaults" `Quick test_report_of_yojson_defaults;
          test_case "report stringish ids" `Quick
            test_report_of_yojson_accepts_stringish_ids;
          test_case "report cause is required and closed" `Quick
            test_report_rejects_missing_or_unknown_cause;
          test_case "record writes audit ring and telemetry" `Quick
            test_record_writes_audit_ring_and_telemetry;
          test_case "message does not override typed cause" `Quick
            test_explicit_cause_is_not_reparsed_from_message;
          test_case "blank entity_id is normalized out" `Quick
            test_blank_entity_id_is_normalized_out;
          test_case "HTTP report records the bearer reporter" `Quick
            test_report_route_binds_bearer_reporter;
          test_case "HTTP report preserves admitted local attribution" `Quick
            test_report_route_preserves_local_reporter;
          test_case "HTTP report keeps the unnamed subject fallback" `Quick
            test_report_route_keeps_subject_fallback;
          test_case "HTTP report rejects unauthorized callers" `Quick
            test_report_route_rejects_unauthorized_reports;
        ] );
    ]
