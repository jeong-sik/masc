(** Roundtrip tests for Runtime ppx-generated yojson/show functions.
    Targets the ~270 uncovered points in runtime.ml from ppx codegen. *)

open Agent_sdk

let roundtrip
      (type a)
      ~(to_yojson : a -> Yojson.Safe.t)
      ~(of_yojson : Yojson.Safe.t -> a Ppx_deriving_yojson_runtime.error_or)
      ~(show : a -> string)
      ~name
      (value : a)
  =
  let json = to_yojson value in
  match of_yojson json with
  | Ok decoded ->
    Alcotest.(check string) (name ^ " roundtrip") (show value) (show decoded)
  | Error msg -> Alcotest.fail (Printf.sprintf "%s: of_yojson failed: %s" name msg)
;;

let test_phase () =
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Runtime.phase_to_yojson
         ~of_yojson:Runtime.phase_of_yojson
         ~show:Runtime.show_phase
         ~name:(Runtime.show_phase v)
         v)
    Runtime.
      [ Bootstrapping
      ; Running
      ; Input_required
      ; Waiting_on_workers
      ; Finalizing
      ; Completed
      ; Failed
      ; Cancelled
      ]
;;

let test_participant_state () =
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Runtime.participant_state_to_yojson
         ~of_yojson:Runtime.participant_state_of_yojson
         ~show:Runtime.show_participant_state
         ~name:(Runtime.show_participant_state v)
         v)
    Runtime.[ Planned; Starting; Live; Idle; Done; Failed_participant; Detached ]
;;

let test_participant () =
  let v : Runtime.participant =
    { name = "worker-1"
    ; role = Some "executor"
    ; aliases = [ "w1"; "exec" ]
    ; worker_id = Some "wid-1"
    ; runtime_actor = Some "ra-1"
    ; requested_provider = Some "anthropic"
    ; requested_model = Some "sonnet-4-6"
    ; provider = Some "anthropic"
    ; model = Some "sonnet-4-6"
    ; resolved_provider = Some "anthropic"
    ; resolved_model = Some "sonnet-4-6-20250514"
    ; state = Runtime.Live
    ; summary = Some "running well"
    ; accepted_at = Some 1.7e9
    ; ready_at = Some 1.7e9
    ; first_progress_at = Some 1.7e9
    ; started_at = Some 1.7e9
    ; finished_at = None
    ; last_progress_at = Some 1.7e9
    ; last_error = None
    }
  in
  roundtrip
    ~to_yojson:Runtime.participant_to_yojson
    ~of_yojson:Runtime.participant_of_yojson
    ~show:Runtime.show_participant
    ~name:"participant"
    v
;;

let test_artifact () =
  let v : Runtime.artifact =
    { artifact_id = "art-1"
    ; name = "result.json"
    ; kind = "json"
    ; mime_type = "application/json"
    ; path = Some "/tmp/result.json"
    ; inline_content = Some "{}"
    ; size_bytes = 2
    ; created_at = 1.7e9
    }
  in
  roundtrip
    ~to_yojson:Runtime.artifact_to_yojson
    ~of_yojson:Runtime.artifact_of_yojson
    ~show:Runtime.show_artifact
    ~name:"artifact"
    v
;;

let test_session () =
  let v : Runtime.session =
    { session_id = "sess-rt"
    ; goal = "test runtime"
    ; title = Some "Runtime Test"
    ; tag = Some "test"
    ; phase = Runtime.Running
    ; created_at = 1.7e9
    ; updated_at = 1.7e9
    ; provider = Some "anthropic"
    ; model = Some "sonnet-4-6"
    ; system_prompt = Some "You are helpful."
    ; workdir = Some "/tmp/work"
    ; planned_participants = [ "agent-1" ]
    ; participants =
        [ { name = "agent-1"
          ; role = None
          ; aliases = []
          ; worker_id = None
          ; runtime_actor = None
          ; requested_provider = None
          ; requested_model = None
          ; provider = None
          ; model = None
          ; resolved_provider = None
          ; resolved_model = None
          ; state = Runtime.Planned
          ; summary = None
          ; accepted_at = None
          ; ready_at = None
          ; first_progress_at = None
          ; started_at = None
          ; finished_at = None
          ; last_progress_at = None
          ; last_error = None
          }
        ]
    ; artifacts = []
    ; pending_input = None
    ; turn_count = 0
    ; last_seq = 0
    ; outcome = None
    }
  in
  roundtrip
    ~to_yojson:Runtime.session_to_yojson
    ~of_yojson:Runtime.session_of_yojson
    ~show:Runtime.show_session
    ~name:"session"
    v
;;

let test_init_request () =
  let v : Runtime.init_request =
    { session_root = Some "/tmp/sessions"
    ; provider = Some "anthropic"
    ; model = Some "sonnet-4-6"
    ; include_partial_messages = true
    ; setting_sources = [ "env"; "config" ]
    ; resume_session = None
    ; cwd = Some "/workspace"
    }
  in
  roundtrip
    ~to_yojson:Runtime.init_request_to_yojson
    ~of_yojson:Runtime.init_request_of_yojson
    ~show:Runtime.show_init_request
    ~name:"init_request"
    v
;;

let test_init_response () =
  let v : Runtime.init_response =
    { sdk_name = "oas"
    ; sdk_version = Agent_sdk.Sdk_version.version
    ; runtime_version = "1.0"
    ; protocol_version = "1"
    ; capabilities = [ "streaming"; "tools" ]
    }
  in
  roundtrip
    ~to_yojson:Runtime.init_response_to_yojson
    ~of_yojson:Runtime.init_response_of_yojson
    ~show:Runtime.show_init_response
    ~name:"init_response"
    v
;;

let test_report () =
  let v : Runtime.report =
    { session_id = "sess-rpt"
    ; summary = [ "did things"; "completed" ]
    ; markdown = "# Report\nDone."
    ; generated_at = 1.7e9
    }
  in
  roundtrip
    ~to_yojson:Runtime.report_to_yojson
    ~of_yojson:Runtime.report_of_yojson
    ~show:Runtime.show_report
    ~name:"report"
    v
;;

let test_proof () =
  let v : Runtime.proof =
    { session_id = "sess-proof"
    ; ok = true
    ; checks = [ { name = "all_tools_paired"; passed = true } ]
    ; evidence = [ "trace.jsonl" ]
    ; generated_at = 1.7e9
    }
  in
  roundtrip
    ~to_yojson:Runtime.proof_to_yojson
    ~of_yojson:Runtime.proof_of_yojson
    ~show:Runtime.show_proof
    ~name:"proof"
    v
;;

(* ── Additional protocol types ────────────────────────────────── *)

let test_start_request () =
  let v : Runtime.start_request =
    { session_id = Some "s1"
    ; goal = "test"
    ; participants = [ "a1" ]
    ; provider = Some "anthropic"
    ; model = Some "sonnet"
    ; system_prompt = Some "be helpful"
    ; workdir = Some "/work"
    }
  in
  roundtrip
    ~to_yojson:Runtime.start_request_to_yojson
    ~of_yojson:Runtime.start_request_of_yojson
    ~show:Runtime.show_start_request
    ~name:"start_request"
    v
;;

let test_spawn_agent_request () =
  let v : Runtime.spawn_agent_request =
    { participant_name = "sub"
    ; role = Some "helper"
    ; prompt = "help me"
    ; provider = Some "local"
    ; model = Some "dashscope"
    ; system_prompt = None
    }
  in
  roundtrip
    ~to_yojson:Runtime.spawn_agent_request_to_yojson
    ~of_yojson:Runtime.spawn_agent_request_of_yojson
    ~show:Runtime.show_spawn_agent_request
    ~name:"spawn_agent"
    v
;;

let test_update_settings () =
  let v : Runtime.update_settings_request = { model = Some "opus" } in
  roundtrip
    ~to_yojson:Runtime.update_settings_request_to_yojson
    ~of_yojson:Runtime.update_settings_request_of_yojson
    ~show:Runtime.show_update_settings_request
    ~name:"update_settings"
    v
;;

let test_attach_artifact_request () =
  let v : Runtime.attach_artifact_request =
    { name = "log.txt"; kind = "text"; content = "log data" }
  in
  roundtrip
    ~to_yojson:Runtime.attach_artifact_request_to_yojson
    ~of_yojson:Runtime.attach_artifact_request_of_yojson
    ~show:Runtime.show_attach_artifact_request
    ~name:"attach_artifact"
    v
;;

let test_command () =
  let input_request : Runtime.input_request =
    { request_id = "input-1"
    ; participant_name = Some "sub"
    ; question = "Confirm?"
    ; schema = None
    ; timeout_s = Some 10.0
    ; created_at = 1.7e9
    }
  in
  let variants =
    [ Runtime.Record_turn { actor = Some "user"; message = "hello" }
    ; Runtime.Request_input input_request
    ; Runtime.Provide_input
        { request_id = "input-1"; response = Runtime.Input_answer (`String "yes") }
    ; Runtime.Spawn_agent
        { participant_name = "sub"
        ; role = None
        ; prompt = "p"
        ; provider = None
        ; model = None
        ; system_prompt = None
        }
    ; Runtime.Update_session_settings { model = Some "opus" }
    ; Runtime.Attach_artifact { name = "r.txt"; kind = "text"; content = "data" }
    ; Runtime.Checkpoint { label = Some "mid" }
    ; Runtime.Request_finalize { reason = Some "done" }
    ]
  in
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Runtime.command_to_yojson
         ~of_yojson:Runtime.command_of_yojson
         ~show:Runtime.show_command
         ~name:"command"
         v)
    variants
;;

let test_event_kind () =
  let input_request : Runtime.input_request =
    { request_id = "input-1"
    ; participant_name = Some "sub"
    ; question = "Confirm?"
    ; schema = None
    ; timeout_s = Some 10.0
    ; created_at = 1.7e9
    }
  in
  let events =
    [ Runtime.Session_started { goal = "test"; participants = [ "a1" ] }
    ; Runtime.Turn_recorded { actor = Some "user"; message = "hi" }
    ; Runtime.Input_required input_request
    ; Runtime.Input_provided
        { request_id = "input-1"
        ; participant_name = Some "sub"
        ; response = Runtime.Input_answer (`String "yes")
        }
    ; Runtime.Agent_spawn_requested
        { participant_name = "sub"
        ; role = None
        ; prompt = "p"
        ; provider = None
        ; model = None
        }
    ; Runtime.Agent_became_live
        { participant =
            { participant_name = "sub"
            ; summary = Some "ready"
            ; provider = Some "local"
            ; model = Some "dashscope"
            ; raw_trace_run_id = Some "wr-1"
            }
        }
    ; Runtime.Agent_completed
        { participant =
            { participant_name = "sub"
            ; summary = Some "done"
            ; provider = Some "local"
            ; model = Some "dashscope"
            ; raw_trace_run_id = Some "wr-1"
            }
        ; stop_reason = Some "stop"
        ; completion_anomaly = None
        }
    ; Runtime.Agent_failed
        { participant =
            { participant_name = "sub"
            ; summary = None
            ; provider = Some "local"
            ; model = Some "dashscope"
            ; raw_trace_run_id = Some "wr-2"
            }
        ; failure_cause = Runtime.Execution_error "failed"
        }
    ; Runtime.Agent_output_delta
        { participant_name = "sub"; delta = "..."; raw_trace_run_id = Some "wr-1" }
    ; Runtime.Artifact_attached
        { artifact_id = "a1"
        ; name = "r.json"
        ; kind = "json"
        ; mime_type = "application/json"
        ; path = "/tmp/r.json"
        ; size_bytes = 10
        }
    ; Runtime.Checkpoint_saved { label = Some "mid"; path = "/tmp/cp" }
    ; Runtime.Session_completed { outcome = Some "success" }
    ; Runtime.Session_failed { outcome = Some "error" }
    ]
  in
  List.iter
    (fun ek ->
       roundtrip
         ~to_yojson:Runtime.event_kind_to_yojson
         ~of_yojson:Runtime.event_kind_of_yojson
         ~show:Runtime.show_event_kind
         ~name:"event_kind"
         ek)
    events
;;

let test_output_delta_legacy_json_defaults_raw_trace_run_id () =
  let json = `Assoc [ "participant_name", `String "sub"; "delta", `String "legacy" ] in
  match Runtime.output_delta_event_of_yojson json with
  | Ok detail ->
    Alcotest.(check (option string)) "raw trace default" None detail.raw_trace_run_id
  | Error msg -> Alcotest.failf "output_delta_event parse failed: %s" msg
;;

let completion_anomaly count =
  match Runtime.dropped_output_deltas ~count with
  | Ok anomaly -> anomaly
  | Error error -> Alcotest.fail (Runtime.show_completion_anomaly_error error)
;;

let test_completion_anomaly_requires_positive_count () =
  roundtrip
    ~to_yojson:Runtime.completion_anomaly_to_yojson
    ~of_yojson:Runtime.completion_anomaly_of_yojson
    ~show:Runtime.show_completion_anomaly
    ~name:"completion_anomaly"
    (completion_anomaly 1);
  List.iter
    (fun count ->
       match Runtime.dropped_output_deltas ~count with
       | Error (Runtime.Non_positive_dropped_output_delta_count rejected) ->
         Alcotest.(check int) "rejected count" count rejected
       | Ok _ -> Alcotest.failf "count %d must be rejected" count)
    [ 0; -1 ]
;;

let test_completion_anomaly_decoder_rejects_non_positive_count () =
  let rec replace_count count = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "count"
              then name, `Int count
              else name, replace_count count value)
           fields)
    | `List values -> `List (List.map (replace_count count) values)
    | json -> json
  in
  let valid_json = completion_anomaly 1 |> Runtime.completion_anomaly_to_yojson in
  List.iter
    (fun count ->
       let invalid_json = replace_count count valid_json in
       Alcotest.(check bool)
         "decode rejected"
         true
         (Result.is_error (Runtime.completion_anomaly_of_yojson invalid_json)))
    [ 0; -1 ]
;;

let test_participant_lifecycle_payloads_exclude_contradictions () =
  let participant : Runtime.participant_event_common =
    { participant_name = "sub"
    ; summary = None
    ; provider = None
    ; model = None
    ; raw_trace_run_id = None
    }
  in
  let live : Runtime.participant_live_event = { participant } in
  let completed : Runtime.participant_completed_event =
    { participant; stop_reason = Some "stop"; completion_anomaly = None }
  in
  let failed : Runtime.participant_failed_event =
    { participant; failure_cause = Runtime.Execution_error "typed failure" }
  in
  roundtrip
    ~to_yojson:Runtime.participant_live_event_to_yojson
    ~of_yojson:Runtime.participant_live_event_of_yojson
    ~show:Runtime.show_participant_live_event
    ~name:"participant_live_event"
    live;
  roundtrip
    ~to_yojson:Runtime.participant_completed_event_to_yojson
    ~of_yojson:Runtime.participant_completed_event_of_yojson
    ~show:Runtime.show_participant_completed_event
    ~name:"participant_completed_event"
    completed;
  roundtrip
    ~to_yojson:Runtime.participant_failed_event_to_yojson
    ~of_yojson:Runtime.participant_failed_event_of_yojson
    ~show:Runtime.show_participant_failed_event
    ~name:"participant_failed_event"
    failed;
  let add_field name value = function
    | `Assoc fields -> `Assoc ((name, value) :: fields)
    | _ -> Alcotest.fail "participant lifecycle payload must encode as an object"
  in
  let remove_field name = function
    | `Assoc fields -> `Assoc (List.remove_assoc name fields)
    | _ -> Alcotest.fail "participant lifecycle payload must encode as an object"
  in
  let failure_json = Runtime.failure_cause_to_yojson failed.failure_cause in
  let completed_json = Runtime.participant_completed_event_to_yojson completed in
  let failed_json = Runtime.participant_failed_event_to_yojson failed in
  let live_json = Runtime.participant_live_event_to_yojson live in
  Alcotest.(check bool)
    "completed rejects failure cause"
    true
    (completed_json
     |> add_field "failure_cause" failure_json
     |> Runtime.participant_completed_event_of_yojson
     |> Result.is_error);
  Alcotest.(check bool)
    "failed rejects completion anomaly"
    true
    (failed_json
     |> add_field "completion_anomaly" `Null
     |> Runtime.participant_failed_event_of_yojson
     |> Result.is_error);
  Alcotest.(check bool)
    "failed requires failure cause"
    true
    (failed_json
     |> remove_field "failure_cause"
     |> Runtime.participant_failed_event_of_yojson
     |> Result.is_error);
  Alcotest.(check bool)
    "live rejects failure cause"
    true
    (live_json
     |> add_field "failure_cause" failure_json
     |> Runtime.participant_live_event_of_yojson
     |> Result.is_error);
  Alcotest.(check bool)
    "legacy flat completed payload rejected"
    true
    (participant
     |> Runtime.participant_event_common_to_yojson
     |> Runtime.participant_completed_event_of_yojson
     |> Result.is_error)
;;

let test_event () =
  let v : Runtime.event =
    { seq = 1
    ; ts = 1.7e9
    ; kind = Runtime.Session_started { goal = "x"; participants = [] }
    }
  in
  roundtrip
    ~to_yojson:Runtime.event_to_yojson
    ~of_yojson:Runtime.event_of_yojson
    ~show:Runtime.show_event
    ~name:"event"
    v
;;

let () =
  Alcotest.run
    "Runtime_types"
    [ "phase", [ Alcotest.test_case "all variants" `Quick test_phase ]
    ; ( "participant_state"
      , [ Alcotest.test_case "all variants" `Quick test_participant_state ] )
    ; ( "records"
      , [ Alcotest.test_case "participant" `Quick test_participant
        ; Alcotest.test_case "artifact" `Quick test_artifact
        ; Alcotest.test_case "session" `Quick test_session
        ; Alcotest.test_case "report" `Quick test_report
        ; Alcotest.test_case "proof" `Quick test_proof
        ] )
    ; ( "protocol"
      , [ Alcotest.test_case "init_request" `Quick test_init_request
        ; Alcotest.test_case "init_response" `Quick test_init_response
        ; Alcotest.test_case "start_request" `Quick test_start_request
        ; Alcotest.test_case "spawn_agent" `Quick test_spawn_agent_request
        ; Alcotest.test_case "update_settings" `Quick test_update_settings
        ; Alcotest.test_case "attach_artifact" `Quick test_attach_artifact_request
        ] )
    ; "command", [ Alcotest.test_case "variants" `Quick test_command ]
    ; ( "events"
      , [ Alcotest.test_case "event_kind all" `Quick test_event_kind
        ; Alcotest.test_case
            "completion anomaly positive count"
            `Quick
            test_completion_anomaly_requires_positive_count
        ; Alcotest.test_case
            "completion anomaly decode validation"
            `Quick
            test_completion_anomaly_decoder_rejects_non_positive_count
        ; Alcotest.test_case
            "participant lifecycle impossible states"
            `Quick
            test_participant_lifecycle_payloads_exclude_contradictions
        ; Alcotest.test_case
            "output delta legacy json"
            `Quick
            test_output_delta_legacy_json_defaults_raw_trace_run_id
        ; Alcotest.test_case "event" `Quick test_event
        ] )
    ]
;;
