(** Roundtrip tests for sessions_types.ml — ppx-generated yojson/show.

    Each type is tested: value -> to_yojson -> of_yojson -> show comparison.
    This covers the large uncovered ppx code-gen surface (~470 points).

    We use fully qualified [Sessions.xxx] to avoid record field shadowing
    (e.g. telemetry_event_count.name vs structured_event_count.event_name). *)

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

(* ── trace_capability ──────────────────────────────────────────── *)

let test_trace_capability () =
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Sessions.trace_capability_to_yojson
         ~of_yojson:Sessions.trace_capability_of_yojson
         ~show:Sessions.show_trace_capability
         ~name:(Sessions.show_trace_capability v)
         v)
    Sessions.[ Raw; Summary_only; No_trace ]
;;

(* ── session_info ──────────────────────────────────────────────── *)

let test_session_info () =
  let v : Sessions.session_info =
    { session_id = "sess-001"
    ; title = Some "Test"
    ; tag = Some "cov"
    ; goal = "coverage"
    ; updated_at = 1.7e9
    ; phase = Runtime.Running
    ; participant_count = 3
    ; path = "/tmp/s/001"
    }
  in
  roundtrip
    ~to_yojson:Sessions.session_info_to_yojson
    ~of_yojson:Sessions.session_info_of_yojson
    ~show:Sessions.show_session_info
    ~name:"session_info"
    v;
  roundtrip
    ~to_yojson:Sessions.session_info_to_yojson
    ~of_yojson:Sessions.session_info_of_yojson
    ~show:Sessions.show_session_info
    ~name:"session_info_minimal"
    { v with title = None; tag = None }
;;

(* ── telemetry types ───────────────────────────────────────────── *)

let test_telemetry_event_count () =
  let v : Sessions.telemetry_event_count = { name = "tool_call"; count = 42 } in
  roundtrip
    ~to_yojson:Sessions.telemetry_event_count_to_yojson
    ~of_yojson:Sessions.telemetry_event_count_of_yojson
    ~show:Sessions.show_telemetry_event_count
    ~name:"telemetry_event_count"
    v
;;

let test_telemetry_step () =
  let v : Sessions.telemetry_step =
    { seq = 1
    ; ts = 1.7e9
    ; kind = "tool_call"
    ; participant = Some "a-1"
    ; detail = Some "read_file"
    }
  in
  roundtrip
    ~to_yojson:Sessions.telemetry_step_to_yojson
    ~of_yojson:Sessions.telemetry_step_of_yojson
    ~show:Sessions.show_telemetry_step
    ~name:"telemetry_step"
    v;
  roundtrip
    ~to_yojson:Sessions.telemetry_step_to_yojson
    ~of_yojson:Sessions.telemetry_step_of_yojson
    ~show:Sessions.show_telemetry_step
    ~name:"telemetry_step_minimal"
    { v with participant = None; detail = None }
;;

let test_telemetry () =
  let v : Sessions.telemetry =
    { session_id = "sess-002"
    ; generated_at = 1.7e9
    ; step_count = 5
    ; event_counts = [ { name = "tool_call"; count = 3 }; { name = "block"; count = 2 } ]
    ; steps =
        [ { seq = 1
          ; ts = 1.7e9
          ; kind = "tool_call"
          ; participant = Some "a-1"
          ; detail = None
          }
        ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.telemetry_to_yojson
    ~of_yojson:Sessions.telemetry_of_yojson
    ~show:Sessions.show_telemetry
    ~name:"telemetry"
    v
;;

(* ── structured telemetry types ────────────────────────────────── *)

let test_structured_event_count () =
  let v : Sessions.structured_event_count = { event_name = "checkpoint"; count = 7 } in
  roundtrip
    ~to_yojson:Sessions.structured_event_count_to_yojson
    ~of_yojson:Sessions.structured_event_count_of_yojson
    ~show:Sessions.show_structured_event_count
    ~name:"structured_event_count"
    v
;;

let test_structured_telemetry_step () =
  let full : Sessions.structured_telemetry_step =
    { seq = 10
    ; ts = 1.7e9
    ; event_name = "tool_exec"
    ; participant = Some "w-1"
    ; detail = Some "ran grep"
    ; actor = Some "agent"
    ; role = Some "exec"
    ; provider = Some "anthropic"
    ; model = Some "sonnet-4-6"
    ; raw_trace_run_id = Some "wr-1"
    ; stop_reason = Some "end_turn"
    ; artifact_id = Some "a-001"
    ; artifact_name = Some "r.json"
    ; artifact_kind = Some "json"
    ; checkpoint_label = Some "mid"
    ; outcome = Some "success"
    ; dropped_output_deltas = Some 1
    ; persistence_failure_phase = None
    }
  in
  roundtrip
    ~to_yojson:Sessions.structured_telemetry_step_to_yojson
    ~of_yojson:Sessions.structured_telemetry_step_of_yojson
    ~show:Sessions.show_structured_telemetry_step
    ~name:"s_step_full"
    full;
  let empty : Sessions.structured_telemetry_step =
    { seq = 0
    ; ts = 0.0
    ; event_name = "idle"
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
    ~name:"s_step_empty"
    empty
;;

let test_structured_telemetry () =
  let v : Sessions.structured_telemetry =
    { session_id = "sess-003"
    ; generated_at = 1.7e9
    ; step_count = 1
    ; event_counts = [ { event_name = "tool_call"; count = 1 } ]
    ; steps =
        [ { seq = 1
          ; ts = 1.7e9
          ; event_name = "tool_exec"
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
        ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.structured_telemetry_to_yojson
    ~of_yojson:Sessions.structured_telemetry_of_yojson
    ~show:Sessions.show_structured_telemetry
    ~name:"structured_telemetry"
    v
;;

(* ── evidence types ────────────────────────────────────────────── *)

let test_evidence_file () =
  let v : Sessions.evidence_file =
    { label = "trace.json"; path = "/tmp/t.json"; size_bytes = 1024; md5 = "abc123" }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_file_to_yojson
    ~of_yojson:Sessions.evidence_file_of_yojson
    ~show:Sessions.show_evidence_file
    ~name:"evidence_file"
    v
;;

let test_missing_file () =
  let v : Sessions.missing_file = { label = "cfg"; path = "/etc/c" } in
  roundtrip
    ~to_yojson:Sessions.missing_file_to_yojson
    ~of_yojson:Sessions.missing_file_of_yojson
    ~show:Sessions.show_missing_file
    ~name:"missing_file"
    v
;;

let test_evidence () =
  let v : Sessions.evidence =
    { session_id = "sess-004"
    ; generated_at = 1.7e9
    ; files = [ { label = "log"; path = "/tmp/l"; size_bytes = 512; md5 = "a" } ]
    ; missing_files = [ { label = "m"; path = "/tmp/g" } ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_to_yojson
    ~of_yojson:Sessions.evidence_of_yojson
    ~show:Sessions.show_evidence
    ~name:"evidence"
    v
;;

(* ── hook_summary ──────────────────────────────────────────────── *)

let test_hook_summary () =
  let full : Sessions.hook_summary =
    { hook_name = "pre_tool"
    ; count = 5
    ; latest_decision = Some "allow"
    ; latest_detail = Some "ok"
    ; latest_ts = Some 1.7e9
    }
  in
  roundtrip
    ~to_yojson:Sessions.hook_summary_to_yojson
    ~of_yojson:Sessions.hook_summary_of_yojson
    ~show:Sessions.show_hook_summary
    ~name:"hook_summary_full"
    full;
  let minimal : Sessions.hook_summary =
    { hook_name = "post"
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
    ~name:"hook_summary_minimal"
    minimal
;;

(* ── tool_contract ─────────────────────────────────────────────── *)

let test_tool_contract () =
  let concurrent : Sessions.tool_contract =
    { name = "bash"
    ; description = "Shell"
    ; origin = Some "builtin"
    ; execution_mode = Tool_contract.Concurrent
    ; completion = Tool_contract.Continue_after_success
    }
  in
  roundtrip
    ~to_yojson:Sessions.tool_contract_to_yojson
    ~of_yojson:Sessions.tool_contract_of_yojson
    ~show:Sessions.show_tool_contract
    ~name:"tool_contract_concurrent"
    concurrent;
  let minimal : Sessions.tool_contract =
    { name = "read"
    ; description = "Read"
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
    minimal;
  let removed_shape =
    `Assoc
      [ "name", `String "read"
      ; "description", `String "Read"
      ; "origin", `Null
      ; "execution_mode", `String "serial"
      ; "completion", `Assoc [ "kind", `String "continue_after_success" ]
      ; "kind", `String "local"
      ]
  in
  Alcotest.(check bool)
    "removed fields rejected"
    true
    (Result.is_error (Sessions.tool_contract_of_yojson removed_shape));
  let missing_mode =
    `Assoc [ "name", `String "read"; "description", `String "Read"; "origin", `Null ]
  in
  Alcotest.(check bool)
    "missing execution mode rejected"
    true
    (Result.is_error (Sessions.tool_contract_of_yojson missing_mode));
  let missing_completion =
    `Assoc
      [ "name", `String "read"
      ; "description", `String "Read"
      ; "origin", `Null
      ; "execution_mode", `String "serial"
      ]
  in
  Alcotest.(check bool)
    "missing completion rejected"
    true
    (Result.is_error (Sessions.tool_contract_of_yojson missing_completion))
;;

(* ── worker_status ─────────────────────────────────────────────── *)

let test_worker_status () =
  List.iter
    (fun v ->
       roundtrip
         ~to_yojson:Sessions.worker_status_to_yojson
         ~of_yojson:Sessions.worker_status_of_yojson
         ~show:Sessions.show_worker_status
         ~name:(Sessions.show_worker_status v)
         v)
    Sessions.[ Planned; Accepted; Ready; Running; Completed; Failed ]
;;

(* ── worker_run (32 fields) ────────────────────────────────────── *)

let test_worker_run () =
  let full : Sessions.worker_run =
    { worker_run_id = "wr-001"
    ; worker_id = Some "w-001"
    ; agent_name = "coder"
    ; runtime_actor = Some "rt-1"
    ; role = Some "impl"
    ; aliases = [ "code"; "dev" ]
    ; primary_alias = Some "code"
    ; provider = Some "anthropic"
    ; model = Some "sonnet-4-6"
    ; requested_provider = Some "anthropic"
    ; requested_model = Some "sonnet-4-6"
    ; resolved_provider = Some "anthropic"
    ; resolved_model = Some "sonnet-4-6-20250514"
    ; status = Sessions.Running
    ; trace_capability = Sessions.Raw
    ; validated = true
    ; tool_names = [ "read"; "write"; "bash" ]
    ; final_text = Some "Done."
    ; stop_reason = Some "end_turn"
    ; error = None
    ; failure_reason = None
    ; accepted_at = Some 1.7e9
    ; ready_at = Some 1.7e9
    ; first_progress_at = Some 1.7e9
    ; started_at = Some 1.7e9
    ; finished_at = None
    ; last_progress_at = Some 1.7e9
    ; paired_tool_result_count = 12
    }
  in
  roundtrip
    ~to_yojson:Sessions.worker_run_to_yojson
    ~of_yojson:Sessions.worker_run_of_yojson
    ~show:Sessions.show_worker_run
    ~name:"worker_run_full"
    full;
  let minimal : Sessions.worker_run =
    { worker_run_id = "wr-min"
    ; worker_id = None
    ; agent_name = "min"
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
    minimal
;;

(* ── evidence_capabilities ─────────────────────────────────────── *)

let test_evidence_capabilities () =
  let v : Sessions.evidence_capabilities =
    { raw_trace = true; validated_summary = false; proof_bundle = true }
  in
  roundtrip
    ~to_yojson:Sessions.evidence_capabilities_to_yojson
    ~of_yojson:Sessions.evidence_capabilities_of_yojson
    ~show:Sessions.show_evidence_capabilities
    ~name:"evidence_capabilities"
    v
;;

(* ── Test runner ───────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Sessions_types"
    [ ( "trace_capability"
      , [ Alcotest.test_case "roundtrip all variants" `Quick test_trace_capability ] )
    ; "session_info", [ Alcotest.test_case "roundtrip" `Quick test_session_info ]
    ; ( "telemetry"
      , [ Alcotest.test_case "event_count" `Quick test_telemetry_event_count
        ; Alcotest.test_case "step" `Quick test_telemetry_step
        ; Alcotest.test_case "full" `Quick test_telemetry
        ] )
    ; ( "structured_telemetry"
      , [ Alcotest.test_case "event_count" `Quick test_structured_event_count
        ; Alcotest.test_case "step full+empty" `Quick test_structured_telemetry_step
        ; Alcotest.test_case "full" `Quick test_structured_telemetry
        ] )
    ; ( "evidence"
      , [ Alcotest.test_case "file" `Quick test_evidence_file
        ; Alcotest.test_case "missing_file" `Quick test_missing_file
        ; Alcotest.test_case "full" `Quick test_evidence
        ] )
    ; "hook_summary", [ Alcotest.test_case "roundtrip" `Quick test_hook_summary ]
    ; "tool_contract", [ Alcotest.test_case "roundtrip" `Quick test_tool_contract ]
    ; "worker_status", [ Alcotest.test_case "all variants" `Quick test_worker_status ]
    ; "worker_run", [ Alcotest.test_case "full + minimal" `Quick test_worker_run ]
    ; ( "evidence_capabilities"
      , [ Alcotest.test_case "roundtrip" `Quick test_evidence_capabilities ] )
    ]
;;
