(** Sessions types deep coverage — exercises ppx-generated to_yojson/of_yojson
    for every type in sessions_types.ml, including edge cases:
    - Empty strings, negative numbers, None fields
    - Every constructor of variant types
    - Every record type round-trip
    - Large composite types (proof_bundle) *)

open Agent_sdk

(* ── Helpers ────────────────────────────────────────────────────── *)

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

(* ── trace_capability edge cases ──────────────────────────────── *)

let test_trace_cap_all () =
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Sessions.trace_capability_to_yojson
         ~of_yojson:Sessions.trace_capability_of_yojson
         ~show:Sessions.show_trace_capability
         ~name:("trace_cap_" ^ Sessions.show_trace_capability v)
         v)
    Sessions.[ Raw; Summary_only; No_trace ]
;;

let test_trace_cap_invalid () =
  match Sessions.trace_capability_of_yojson (`String "invalid") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for invalid trace_capability"
;;

(* ── worker_status all constructors ───────────────────────────── *)

let test_worker_status_all () =
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Sessions.worker_status_to_yojson
         ~of_yojson:Sessions.worker_status_of_yojson
         ~show:Sessions.show_worker_status
         ~name:("worker_status_" ^ Sessions.show_worker_status v)
         v)
    Sessions.[ Planned; Accepted; Ready; Running; Completed; Failed ]
;;

let test_worker_status_invalid () =
  match Sessions.worker_status_of_yojson (`String "unknown_status") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for invalid worker_status"
;;

(* ── session_info with edge values ────────────────────────────── *)

let test_session_info_edge () =
  let v : Sessions.session_info =
    { session_id = ""
    ; title = None
    ; tag = None
    ; goal = ""
    ; updated_at = 0.0
    ; phase = Runtime.Bootstrapping
    ; participant_count = 0
    ; path = ""
    }
  in
  roundtrip
    ~to_yojson:Sessions.session_info_to_yojson
    ~of_yojson:Sessions.session_info_of_yojson
    ~show:Sessions.show_session_info
    ~name:"session_info_empty"
    v
;;

let test_session_info_all_phases () =
  List.iter
    (fun phase ->
       let v : Sessions.session_info =
         { session_id = "s1"
         ; title = Some "t"
         ; tag = Some "tg"
         ; goal = "g"
         ; updated_at = 1.0
         ; phase
         ; participant_count = 1
         ; path = "/p"
         }
       in
       roundtrip
         ~to_yojson:Sessions.session_info_to_yojson
         ~of_yojson:Sessions.session_info_of_yojson
         ~show:Sessions.show_session_info
         ~name:("session_info_phase_" ^ Runtime.show_phase phase)
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

(* ── telemetry types ──────────────────────────────────────────── *)

let test_telemetry_event_count () =
  let v : Sessions.telemetry_event_count = { name = "ev1"; count = 42 } in
  roundtrip
    ~to_yojson:Sessions.telemetry_event_count_to_yojson
    ~of_yojson:Sessions.telemetry_event_count_of_yojson
    ~show:Sessions.show_telemetry_event_count
    ~name:"tel_ev_count"
    v
;;

let test_telemetry_step () =
  let v : Sessions.telemetry_step =
    { seq = 1
    ; ts = 1000.0
    ; kind = "agent_start"
    ; participant = Some "alice"
    ; detail = Some "started"
    }
  in
  roundtrip
    ~to_yojson:Sessions.telemetry_step_to_yojson
    ~of_yojson:Sessions.telemetry_step_of_yojson
    ~show:Sessions.show_telemetry_step
    ~name:"tel_step"
    v;
  let v2 : Sessions.telemetry_step =
    { seq = 0; ts = 0.0; kind = ""; participant = None; detail = None }
  in
  roundtrip
    ~to_yojson:Sessions.telemetry_step_to_yojson
    ~of_yojson:Sessions.telemetry_step_of_yojson
    ~show:Sessions.show_telemetry_step
    ~name:"tel_step_empty"
    v2
;;

let test_telemetry_full () =
  let v : Sessions.telemetry =
    { session_id = "s-tel"
    ; generated_at = 999.0
    ; step_count = 2
    ; event_counts = [ { name = "start"; count = 1 }; { name = "end"; count = 1 } ]
    ; steps =
        [ { seq = 1; ts = 100.0; kind = "start"; participant = Some "bob"; detail = None }
        ; { seq = 2; ts = 200.0; kind = "end"; participant = None; detail = Some "done" }
        ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.telemetry_to_yojson
    ~of_yojson:Sessions.telemetry_of_yojson
    ~show:Sessions.show_telemetry
    ~name:"telemetry_full"
    v
;;

(* ── structured telemetry types ───────────────────────────────── *)

let test_structured_event_count () =
  let v : Sessions.structured_event_count = { event_name = "sev1"; count = 7 } in
  roundtrip
    ~to_yojson:Sessions.structured_event_count_to_yojson
    ~of_yojson:Sessions.structured_event_count_of_yojson
    ~show:Sessions.show_structured_event_count
    ~name:"struct_ev_count"
    v
;;

let test_structured_telemetry_step () =
  let v : Sessions.structured_telemetry_step =
    { seq = 5
    ; ts = 500.0
    ; event_name = "tool_call"
    ; participant = Some "coder"
    ; detail = Some "called read_file"
    ; actor = Some "agent-1"
    ; role = Some "executor"
    ; provider = Some "anthropic"
    ; model = Some "claude"
    ; raw_trace_run_id = Some "wr-1"
    ; stop_reason = Some "end_turn"
    ; artifact_id = Some "art-1"
    ; artifact_name = Some "output.json"
    ; artifact_kind = Some "json"
    ; checkpoint_label = Some "cp1"
    ; outcome = Some "success"
    ; dropped_output_deltas = Some 1
    ; persistence_failure_phase = None
    }
  in
  roundtrip
    ~to_yojson:Sessions.structured_telemetry_step_to_yojson
    ~of_yojson:Sessions.structured_telemetry_step_of_yojson
    ~show:Sessions.show_structured_telemetry_step
    ~name:"struct_step_full"
    v;
  let v2 : Sessions.structured_telemetry_step =
    { seq = 0
    ; ts = 0.0
    ; event_name = ""
    ; participant = None
    ; detail = None
    ; actor = None
    ; role = None
    ; provider = None
    ; model = None
    ; raw_trace_run_id = None
    ; stop_reason = None
    ; artifact_id = None
    ; artifact_name = None
    ; artifact_kind = None
    ; checkpoint_label = None
    ; outcome = None
    ; dropped_output_deltas = None
    ; persistence_failure_phase = None
    }
  in
  roundtrip
    ~to_yojson:Sessions.structured_telemetry_step_to_yojson
    ~of_yojson:Sessions.structured_telemetry_step_of_yojson
    ~show:Sessions.show_structured_telemetry_step
    ~name:"struct_step_empty"
    v2
;;

let test_structured_telemetry_full () =
  let v : Sessions.structured_telemetry =
    { session_id = "s-sttel"
    ; generated_at = 888.0
    ; step_count = 1
    ; event_counts = [ { event_name = "test"; count = 3 } ]
    ; steps =
        [ { seq = 1
          ; ts = 100.0
          ; event_name = "test"
          ; participant = None
          ; detail = None
          ; actor = None
          ; role = None
          ; provider = None
          ; model = None
          ; artifact_id = None
          ; artifact_name = None
          ; artifact_kind = None
          ; checkpoint_label = None
          ; outcome = None
          ; raw_trace_run_id = None
          ; stop_reason = None
          ; dropped_output_deltas = None
          ; persistence_failure_phase = None
          }
        ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.structured_telemetry_to_yojson
    ~of_yojson:Sessions.structured_telemetry_of_yojson
    ~show:Sessions.show_structured_telemetry
    ~name:"struct_telemetry_full"
    v
;;

(* ── evidence types ───────────────────────────────────────────── *)

let test_evidence_file () =
  let v : Sessions.evidence_file =
    { label = "session_json"; path = "/tmp/s.json"; size_bytes = 1024; md5 = "abc123" }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_file_to_yojson
    ~of_yojson:Sessions.evidence_file_of_yojson
    ~show:Sessions.show_evidence_file
    ~name:"evidence_file"
    v
;;

let test_missing_file () =
  let v : Sessions.missing_file = { label = "missing"; path = "/tmp/none.json" } in
  roundtrip
    ~to_yojson:Sessions.missing_file_to_yojson
    ~of_yojson:Sessions.missing_file_of_yojson
    ~show:Sessions.show_missing_file
    ~name:"missing_file"
    v
;;

let test_evidence_bundle () =
  let v : Sessions.evidence =
    { session_id = "s-ev"
    ; generated_at = 777.0
    ; files = [ { label = "f1"; path = "/p1"; size_bytes = 100; md5 = "md5" } ]
    ; missing_files = [ { label = "m1"; path = "/m1" } ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_to_yojson
    ~of_yojson:Sessions.evidence_of_yojson
    ~show:Sessions.show_evidence
    ~name:"evidence_bundle"
    v
;;

(* ── hook_summary ─────────────────────────────────────────────── *)

let test_hook_summary () =
  let v : Sessions.hook_summary =
    { hook_name = "on_tool"
    ; count = 15
    ; latest_decision = Some "deny"
    ; latest_detail = Some "blocked dangerous"
    ; latest_ts = Some 555.0
    }
  in
  roundtrip
    ~to_yojson:Sessions.hook_summary_to_yojson
    ~of_yojson:Sessions.hook_summary_of_yojson
    ~show:Sessions.show_hook_summary
    ~name:"hook_summary_full"
    v;
  let v2 : Sessions.hook_summary =
    { hook_name = ""
    ; count = 0
    ; latest_decision = None
    ; latest_detail = None
    ; latest_ts = None
    }
  in
  roundtrip
    ~to_yojson:Sessions.hook_summary_to_yojson
    ~of_yojson:Sessions.hook_summary_of_yojson
    ~show:Sessions.show_hook_summary
    ~name:"hook_summary_empty"
    v2
;;

(* ── tool_contract ────────────────────────────────────────────── *)

let test_tool_contract () =
  let v : Sessions.tool_contract =
    { name = "run_cmd"
    ; description = "Run command"
    ; origin = Some "mcp"
    ; execution_mode = Tool_contract.Concurrent
    ; completion = Tool_contract.Continue_after_success
    }
  in
  roundtrip
    ~to_yojson:Sessions.tool_contract_to_yojson
    ~of_yojson:Sessions.tool_contract_of_yojson
    ~show:Sessions.show_tool_contract
    ~name:"tool_contract_full"
    v;
  let v2 : Sessions.tool_contract =
    { name = "simple"
    ; description = ""
    ; origin = None
    ; execution_mode = Tool_contract.Serial
    ; completion =
        Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown
    }
  in
  roundtrip
    ~to_yojson:Sessions.tool_contract_to_yojson
    ~of_yojson:Sessions.tool_contract_of_yojson
    ~show:Sessions.show_tool_contract
    ~name:"tool_contract_minimal"
    v2
;;

(* ── worker_run with all statuses ─────────────────────────────── *)

let test_worker_run_all_statuses () =
  List.iter
    (fun status ->
       let v : Sessions.worker_run =
         { worker_run_id = "wr-1"
         ; worker_id = Some "w1"
         ; agent_name = "a1"
         ; runtime_actor = Some "ra1"
         ; role = Some "executor"
         ; aliases = [ "a"; "b" ]
         ; primary_alias = Some "a"
         ; provider = Some "anthropic"
         ; model = Some "claude"
         ; requested_provider = Some "rp"
         ; requested_model = Some "rm"
         ; resolved_provider = Some "anthropic"
         ; resolved_model = Some "claude"
         ; status
         ; trace_capability = Sessions.Raw
         ; validated = status = Sessions.Completed
         ; tool_names = [ "read"; "write" ]
         ; final_text = Some "done"
         ; stop_reason = Some "end_turn"
         ; error = None
         ; failure_reason = None
         ; accepted_at = Some 10.0
         ; ready_at = Some 20.0
         ; first_progress_at = Some 30.0
         ; started_at = Some 40.0
         ; finished_at = Some 50.0
         ; last_progress_at = Some 45.0
         ; paired_tool_result_count = 3
         }
       in
       roundtrip
         ~to_yojson:Sessions.worker_run_to_yojson
         ~of_yojson:Sessions.worker_run_of_yojson
         ~show:Sessions.show_worker_run
         ~name:("worker_run_" ^ Sessions.show_worker_status status)
         v)
    Sessions.[ Planned; Accepted; Ready; Running; Completed; Failed ]
;;

let test_worker_run_minimal () =
  let v : Sessions.worker_run =
    { worker_run_id = ""
    ; worker_id = None
    ; agent_name = ""
    ; runtime_actor = None
    ; role = None
    ; aliases = []
    ; primary_alias = None
    ; provider = None
    ; model = None
    ; requested_provider = None
    ; requested_model = None
    ; resolved_provider = None
    ; resolved_model = None
    ; status = Sessions.Planned
    ; trace_capability = Sessions.No_trace
    ; validated = false
    ; tool_names = []
    ; final_text = None
    ; stop_reason = None
    ; error = None
    ; failure_reason = None
    ; accepted_at = None
    ; ready_at = None
    ; first_progress_at = None
    ; started_at = None
    ; finished_at = None
    ; last_progress_at = None
    ; paired_tool_result_count = 0
    }
  in
  roundtrip
    ~to_yojson:Sessions.worker_run_to_yojson
    ~of_yojson:Sessions.worker_run_of_yojson
    ~show:Sessions.show_worker_run
    ~name:"worker_run_minimal"
    v
;;

(* ── evidence_capabilities ────────────────────────────────────── *)

let test_evidence_capabilities () =
  let v : Sessions.evidence_capabilities =
    { raw_trace = true; validated_summary = false; proof_bundle = true }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_capabilities_to_yojson
    ~of_yojson:Sessions.evidence_capabilities_of_yojson
    ~show:Sessions.show_evidence_capabilities
    ~name:"evidence_caps"
    v;
  let v2 : Sessions.evidence_capabilities =
    { raw_trace = false; validated_summary = false; proof_bundle = false }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_capabilities_to_yojson
    ~of_yojson:Sessions.evidence_capabilities_of_yojson
    ~show:Sessions.show_evidence_capabilities
    ~name:"evidence_caps_all_false"
    v2
;;

(* ── Participant lookup ─────────────────────────────────────────── *)

let make_participant name : Runtime.participant =
  let open Runtime in
  { name
  ; role = None
  ; aliases = []
  ; worker_id = None
  ; runtime_actor = Some name
  ; requested_provider = None
  ; requested_model = None
  ; provider = None
  ; model = None
  ; resolved_provider = None
  ; resolved_model = None
  ; state = Planned
  ; summary = None
  ; accepted_at = None
  ; ready_at = None
  ; first_progress_at = None
  ; started_at = None
  ; finished_at = None
  ; last_progress_at = None
  ; last_error = None
  }
;;

let make_session participants : Runtime.session =
  let open Runtime in
  { session_id = "s-test"
  ; goal = "test"
  ; title = None
  ; tag = None
  ; phase = Bootstrapping
  ; created_at = 0.0
  ; updated_at = 0.0
  ; provider = None
  ; model = None
  ; system_prompt = None
  ; workdir = None
  ; planned_participants = List.map (fun (p : participant) -> p.name) participants
  ; participants
  ; artifacts = []
  ; pending_input = None
  ; turn_count = 0
  ; last_seq = 0
  ; outcome = None
  }
;;

let participant_name_opt result =
  let open Runtime in
  Option.map (fun (p : participant) -> p.name) result
;;

let test_participant_by_name_found () =
  let session = make_session [ make_participant "alice"; make_participant "bob" ] in
  let result = Sessions.participant_by_name session "alice" in
  Alcotest.(check (option string))
    "finds alice"
    (Some "alice")
    (participant_name_opt result)
;;

let test_participant_by_name_not_found () =
  let session = make_session [ make_participant "alice" ] in
  let result = Sessions.participant_by_name session "carol" in
  Alcotest.(check (option string)) "not found" None (participant_name_opt result)
;;

let test_participant_by_name_empty () =
  let session = make_session [] in
  let result = Sessions.participant_by_name session "anyone" in
  Alcotest.(check (option string)) "empty" None (participant_name_opt result)
;;

(* ── Suite ─────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "sessions_cov2"
    [ ( "trace_capability"
      , [ Alcotest.test_case "all variants" `Quick test_trace_cap_all
        ; Alcotest.test_case "invalid" `Quick test_trace_cap_invalid
        ] )
    ; ( "worker_status"
      , [ Alcotest.test_case "all variants" `Quick test_worker_status_all
        ; Alcotest.test_case "invalid" `Quick test_worker_status_invalid
        ] )
    ; ( "session_info"
      , [ Alcotest.test_case "edge values" `Quick test_session_info_edge
        ; Alcotest.test_case "all phases" `Quick test_session_info_all_phases
        ] )
    ; ( "telemetry"
      , [ Alcotest.test_case "event_count" `Quick test_telemetry_event_count
        ; Alcotest.test_case "step" `Quick test_telemetry_step
        ; Alcotest.test_case "full" `Quick test_telemetry_full
        ] )
    ; ( "structured_telemetry"
      , [ Alcotest.test_case "event_count" `Quick test_structured_event_count
        ; Alcotest.test_case "step" `Quick test_structured_telemetry_step
        ; Alcotest.test_case "full" `Quick test_structured_telemetry_full
        ] )
    ; ( "evidence"
      , [ Alcotest.test_case "file" `Quick test_evidence_file
        ; Alcotest.test_case "missing" `Quick test_missing_file
        ; Alcotest.test_case "bundle" `Quick test_evidence_bundle
        ] )
    ; "hook_summary", [ Alcotest.test_case "roundtrip" `Quick test_hook_summary ]
    ; "tool_contract", [ Alcotest.test_case "roundtrip" `Quick test_tool_contract ]
    ; ( "worker_run"
      , [ Alcotest.test_case "all statuses" `Quick test_worker_run_all_statuses
        ; Alcotest.test_case "minimal" `Quick test_worker_run_minimal
        ] )
    ; ( "evidence_capabilities"
      , [ Alcotest.test_case "roundtrip" `Quick test_evidence_capabilities ] )
    ; ( "participant_by_name"
      , [ Alcotest.test_case "found" `Quick test_participant_by_name_found
        ; Alcotest.test_case "not_found" `Quick test_participant_by_name_not_found
        ; Alcotest.test_case "empty" `Quick test_participant_by_name_empty
        ] )
    ]
;;
