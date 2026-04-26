open Alcotest
open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_dashboard_tool_host_events_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with
  | _ -> ()
;;

let test_report_of_yojson_defaults () =
  let json =
    `Assoc
      [ "tool_name", `String "masc_keeper_msg"
      ; "message", `String "timed out awaiting tools/call after 120s"
      ]
  in
  match Dashboard_tool_host_events.report_of_yojson ~fallback_agent:"codex" json with
  | Error err -> fail err
  | Ok report ->
    check string "agent defaulted from fallback" "codex" report.agent_name;
    check string "client defaulted from fallback" "codex" report.client_name;
    check string "transport default" "mcp_http" report.transport;
    check (option string) "phase missing" None report.phase
;;

let test_report_of_yojson_accepts_stringish_ids () =
  let json =
    `Assoc
      [ "client_name", `String "codex"
      ; "tool_name", `String "masc_keeper_msg"
      ; "message", `String "timed out awaiting tools/call after 120s"
      ; "request_id", `Int 42
      ; "session_id", `String "sess-1"
      ; "trace_id", `String "trace-1"
      ; "timeout_ms", `Int 120000
      ; "phase", `String "tools/call"
      ]
  in
  match Dashboard_tool_host_events.report_of_yojson json with
  | Error err -> fail err
  | Ok report ->
    check (option string) "request_id" (Some "42") report.request_id;
    check (option int) "timeout_ms" (Some 120000) report.timeout_ms;
    check (option string) "trace_id" (Some "trace-1") report.trace_id
;;

let test_record_writes_audit_ring_and_telemetry () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Coord.default_config base_dir in
       let report =
         { Dashboard_tool_host_events.agent_name = "codex"
         ; client_name = "codex"
         ; tool_name = "masc_keeper_msg"
         ; transport = "mcp_http"
         ; phase = Some "tools/call"
         ; message = "timed out awaiting tools/call after 120s"
         ; request_id = Some "99"
         ; session_id = Some "sess-99"
         ; trace_id = Some "trace-99"
         ; timeout_ms = Some 120000
         }
       in
       Dashboard_tool_host_events.record ~fs:() config report;
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
       (match entry.outcome with
        | Audit_log.Failure reason -> check string "failure reason" report.message reason
        | Audit_log.Success -> fail "expected failure outcome");
       let latest =
         match Log.Ring.recent ~limit:1 () with
         | row :: _ -> row
         | [] -> fail "expected ring entry"
       in
       check string "ring source" "client_tool_host" latest.source;
       check string "ring module" "ToolHost" latest.module_name;
       check
         bool
         "ring details object"
         true
         (match latest.details with
          | `Assoc _ -> true
          | _ -> false);
       let failure_envelope = Yojson.Safe.Util.member "failure_envelope" latest.details in
       check
         string
         "failure cause code"
         "tool_host_timeout"
         Yojson.Safe.Util.(failure_envelope |> member "cause_code" |> to_string);
       check
         string
         "failure recoverability"
         "operator_action_required"
         Yojson.Safe.Util.(failure_envelope |> member "recoverability" |> to_string);
       check
         string
         "failure operator action"
         "masc_operator_digest"
         Yojson.Safe.Util.(failure_envelope |> member "operator_action" |> to_string);
       check
         string
         "failure evidence request_id"
         "99"
         Yojson.Safe.Util.(
           failure_envelope |> member "evidence_ref" |> member "request_id" |> to_string);
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
;;

let test_generic_failure_envelope_is_retryable_without_operator_action () =
  let details =
    Dashboard_tool_host_events.details_json
      { agent_name = "codex"
      ; client_name = "codex"
      ; tool_name = "masc_keeper_msg"
      ; transport = "mcp_http"
      ; phase = Some "tools/call"
      ; message = "upstream returned malformed payload"
      ; request_id = Some "generic-1"
      ; session_id = None
      ; trace_id = None
      ; timeout_ms = None
      }
  in
  let failure_envelope = Yojson.Safe.Util.member "failure_envelope" details in
  check
    string
    "generic cause code"
    "tool_host_failure"
    Yojson.Safe.Util.(failure_envelope |> member "cause_code" |> to_string);
  check
    string
    "generic recoverability"
    "retryable"
    Yojson.Safe.Util.(failure_envelope |> member "recoverability" |> to_string);
  check
    bool
    "generic operator action omitted"
    true
    Yojson.Safe.Util.(failure_envelope |> member "operator_action" = `Null)
;;

let test_blank_entity_id_is_normalized_out () =
  let details =
    Dashboard_tool_host_events.details_json
      { agent_name = "codex"
      ; client_name = "codex"
      ; tool_name = "masc_keeper_msg"
      ; transport = "mcp_http"
      ; phase = Some "tools/call"
      ; message = "upstream returned malformed payload"
      ; request_id = Some "   "
      ; session_id = Some ""
      ; trace_id = Some "trace-7"
      ; timeout_ms = None
      }
  in
  let failure_envelope = Yojson.Safe.Util.member "failure_envelope" details in
  check
    string
    "normalized entity_id uses first non-empty id"
    "trace-7"
    Yojson.Safe.Util.(failure_envelope |> member "entity_id" |> to_string);
  check
    bool
    "blank request_id omitted from evidence"
    true
    Yojson.Safe.Util.(
      failure_envelope |> member "evidence_ref" |> member "request_id" = `Null);
  check
    bool
    "blank session_id omitted from evidence"
    true
    Yojson.Safe.Util.(
      failure_envelope |> member "evidence_ref" |> member "session_id" = `Null)
;;

let () =
  run
    "Dashboard_tool_host_events"
    [ ( "dashboard_tool_host_events"
      , [ test_case "report defaults" `Quick test_report_of_yojson_defaults
        ; test_case
            "report stringish ids"
            `Quick
            test_report_of_yojson_accepts_stringish_ids
        ; test_case
            "record writes audit ring and telemetry"
            `Quick
            test_record_writes_audit_ring_and_telemetry
        ; test_case
            "generic failure envelope stays retryable"
            `Quick
            test_generic_failure_envelope_is_retryable_without_operator_action
        ; test_case
            "blank entity_id is normalized out"
            `Quick
            test_blank_entity_id_is_normalized_out
        ] )
    ]
;;
