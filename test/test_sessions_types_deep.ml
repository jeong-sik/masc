(** Deep roundtrip tests for sessions_types.ml — targeting uncovered
    ppx-generated yojson paths (94 uncovered points at 80%).

    Exercises to_yojson/of_yojson for every type, including:
    - raw_trace_run, raw_trace_summary, raw_trace_validation
    - worker_run with all 6 status variants
    - proof_bundle (the large composite type)
    - Edge cases: None fields, empty lists, all-Some fields *)

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

let roundtrip_json_stable
      (type a)
      ~(to_yojson : a -> Yojson.Safe.t)
      ~(of_yojson : Yojson.Safe.t -> a Ppx_deriving_yojson_runtime.error_or)
      ~name
      (value : a)
  =
  let json = to_yojson value in
  match of_yojson json with
  | Ok decoded ->
    let json2 = to_yojson decoded in
    Alcotest.(check string)
      (name ^ " json stability")
      (Yojson.Safe.to_string json)
      (Yojson.Safe.to_string json2)
  | Error msg -> Alcotest.fail (Printf.sprintf "%s: of_yojson failed: %s" name msg)
;;

(* ── raw_trace_run (= Raw_trace.run_ref) ────────────────────────── *)

let mk_run_ref ?(session_id = Some "s-001") () : Raw_trace.run_ref =
  { worker_run_id = "wr-abc12345-0001-0000"
  ; path = "/tmp/traces/agent.jsonl"
  ; start_seq = 1
  ; end_seq = 10
  ; agent_name = "coder"
  ; session_id
  }
;;

let test_raw_trace_run_full () =
  let v = mk_run_ref () in
  roundtrip
    ~to_yojson:Sessions.raw_trace_run_to_yojson
    ~of_yojson:Sessions.raw_trace_run_of_yojson
    ~show:Sessions.show_raw_trace_run
    ~name:"raw_trace_run_full"
    v
;;

let test_raw_trace_run_no_session () =
  let v = mk_run_ref ~session_id:None () in
  roundtrip
    ~to_yojson:Sessions.raw_trace_run_to_yojson
    ~of_yojson:Sessions.raw_trace_run_of_yojson
    ~show:Sessions.show_raw_trace_run
    ~name:"raw_trace_run_no_session"
    v
;;

let test_raw_trace_run_json_stable () =
  let v = mk_run_ref () in
  roundtrip_json_stable
    ~to_yojson:Sessions.raw_trace_run_to_yojson
    ~of_yojson:Sessions.raw_trace_run_of_yojson
    ~name:"raw_trace_run_json"
    v
;;

(* ── raw_trace_summary (= Raw_trace.run_summary) ────────────────── *)

let mk_run_summary ?(final_text = Some "Done.") ?(error = None) () : Raw_trace.run_summary
  =
  { run_ref = mk_run_ref ()
  ; record_count = 25
  ; assistant_block_count = 8
  ; tool_execution_started_count = 5
  ; tool_execution_finished_count = 5
  ; hook_invoked_count = 2
  ; hook_names = [ "pre_tool"; "post_tool" ]
  ; tool_names = [ "bash"; "read_file" ]
  ; model = Some "glm-5.1"
  ; tool_choice = Some (Agent_sdk.Types.tool_choice_to_json Agent_sdk.Types.Any)
  ; enable_thinking = Some true
  ; preserve_thinking = Some true
  ; thinking_budget = Some 4096
  ; reasoning_effort = Some "high"
  ; thinking_block_count = 3
  ; text_block_count = 2
  ; tool_use_block_count = 5
  ; tool_result_block_count = 5
  ; first_assistant_block_kind = Some "thinking"
  ; selection_outcome = "mixed"
  ; saw_tool_use = true
  ; saw_thinking = true
  ; final_text
  ; stop_reason = Some "end_turn"
  ; error
  ; started_at = Some 1.7e9
  ; finished_at = Some (1.7e9 +. 30.0)
  }
;;

let test_raw_trace_summary_full () =
  let v = mk_run_summary () in
  roundtrip
    ~to_yojson:Sessions.raw_trace_summary_to_yojson
    ~of_yojson:Sessions.raw_trace_summary_of_yojson
    ~show:Sessions.show_raw_trace_summary
    ~name:"raw_trace_summary_full"
    v
;;

let test_raw_trace_summary_empty_lists () =
  let v : Raw_trace.run_summary =
    { run_ref = mk_run_ref ()
    ; record_count = 0
    ; assistant_block_count = 0
    ; tool_execution_started_count = 0
    ; tool_execution_finished_count = 0
    ; hook_invoked_count = 0
    ; hook_names = []
    ; tool_names = []
    ; model = None
    ; tool_choice = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; thinking_block_count = 0
    ; text_block_count = 0
    ; tool_use_block_count = 0
    ; tool_result_block_count = 0
    ; first_assistant_block_kind = None
    ; selection_outcome = "empty"
    ; saw_tool_use = false
    ; saw_thinking = false
    ; final_text = None
    ; stop_reason = None
    ; error = None
    ; started_at = None
    ; finished_at = None
    }
  in
  roundtrip
    ~to_yojson:Sessions.raw_trace_summary_to_yojson
    ~of_yojson:Sessions.raw_trace_summary_of_yojson
    ~show:Sessions.show_raw_trace_summary
    ~name:"raw_trace_summary_empty"
    v
;;

let test_raw_trace_summary_with_error () =
  let v = mk_run_summary ~final_text:None ~error:(Some "rate_limit_exceeded") () in
  roundtrip
    ~to_yojson:Sessions.raw_trace_summary_to_yojson
    ~of_yojson:Sessions.raw_trace_summary_of_yojson
    ~show:Sessions.show_raw_trace_summary
    ~name:"raw_trace_summary_error"
    v
;;

(* ── raw_trace_validation (= Raw_trace.run_validation) ──────────── *)

let mk_run_validation ?(ok = true) ?(failure_reason = None) () : Raw_trace.run_validation =
  { run_ref = mk_run_ref ()
  ; ok
  ; checks =
      [ { name = "seq_monotonic"; passed = true }
      ; { name = "run_started"; passed = true }
      ; { name = "run_finished"; passed = ok }
      ; { name = "tool_pairs"; passed = true }
      ]
  ; evidence = [ "record_count=25"; "tool_exec_started=5" ]
  ; paired_tool_result_count = 5
  ; final_text = Some "All done."
  ; tool_names = [ "bash"; "write_file"; "file_write" ]
  ; stop_reason = Some "end_turn"
  ; failure_reason
  }
;;

let test_raw_trace_validation_pass () =
  let v = mk_run_validation () in
  roundtrip
    ~to_yojson:Sessions.raw_trace_validation_to_yojson
    ~of_yojson:Sessions.raw_trace_validation_of_yojson
    ~show:Sessions.show_raw_trace_validation
    ~name:"raw_trace_validation_pass"
    v
;;

let test_raw_trace_validation_fail () =
  let v = mk_run_validation ~ok:false ~failure_reason:(Some "run_finished") () in
  roundtrip
    ~to_yojson:Sessions.raw_trace_validation_to_yojson
    ~of_yojson:Sessions.raw_trace_validation_of_yojson
    ~show:Sessions.show_raw_trace_validation
    ~name:"raw_trace_validation_fail"
    v
;;

let test_raw_trace_validation_empty_checks () =
  let v : Raw_trace.run_validation =
    { run_ref = mk_run_ref ~session_id:None ()
    ; ok = false
    ; checks = []
    ; evidence = []
    ; paired_tool_result_count = 0
    ; final_text = None
    ; tool_names = []
    ; stop_reason = None
    ; failure_reason = None
    }
  in
  roundtrip
    ~to_yojson:Sessions.raw_trace_validation_to_yojson
    ~of_yojson:Sessions.raw_trace_validation_of_yojson
    ~show:Sessions.show_raw_trace_validation
    ~name:"raw_trace_validation_empty"
    v
;;

let test_raw_trace_manifest_roundtrip () =
  let run_ref = mk_run_ref () in
  let v : Sessions.raw_trace_manifest =
    { session_id = "s-001"
    ; generated_at = 123.0
    ; latest_raw_trace_run = Some run_ref
    ; raw_trace_runs = [ run_ref ]
    ; raw_trace_summaries = [ mk_run_summary () ]
    ; raw_trace_validations = [ mk_run_validation () ]
    }
  in
  roundtrip
    ~to_yojson:Sessions.raw_trace_manifest_to_yojson
    ~of_yojson:Sessions.raw_trace_manifest_of_yojson
    ~show:Sessions.show_raw_trace_manifest
    ~name:"raw_trace_manifest"
    v
;;

(* ── worker_run with each status variant ────────────────────────── *)

let mk_worker_run status : Sessions.worker_run =
  { worker_run_id = Printf.sprintf "wr-%s" (Sessions.show_worker_status status)
  ; worker_id = Some "w-001"
  ; agent_name = "tester"
  ; runtime_actor = Some "rt-1"
  ; role = Some "exec"
  ; aliases = [ "t"; "test" ]
  ; primary_alias = Some "t"
  ; provider = Some "anthropic"
  ; model = Some "sonnet-4-6"
  ; requested_provider = Some "anthropic"
  ; requested_model = Some "sonnet-4-6"
  ; resolved_provider = Some "anthropic"
  ; resolved_model = Some "claude-sonnet-4-6-20250514"
  ; status
  ; trace_capability = Sessions.Raw
  ; validated = status = Sessions.Completed
  ; tool_names = [ "bash"; "read" ]
  ; final_text =
      (match status with
       | Sessions.Completed -> Some "OK"
       | _ -> None)
  ; stop_reason =
      (match status with
       | Sessions.Completed -> Some "end_turn"
       | _ -> None)
  ; error =
      (match status with
       | Sessions.Failed -> Some "timeout"
       | _ -> None)
  ; failure_reason =
      (match status with
       | Sessions.Failed -> Some "timeout"
       | _ -> None)
  ; accepted_at = Some 1.7e9
  ; ready_at = Some 1.7e9
  ; first_progress_at = Some (1.7e9 +. 1.0)
  ; started_at = Some 1.7e9
  ; finished_at =
      (match status with
       | Sessions.Completed | Sessions.Failed -> Some (1.7e9 +. 60.0)
       | _ -> None)
  ; last_progress_at = Some (1.7e9 +. 30.0)
  ; paired_tool_result_count = 3
  }
;;

let test_worker_run_all_statuses () =
  List.iter
    (fun status ->
       let v = mk_worker_run status in
       roundtrip
         ~to_yojson:Sessions.worker_run_to_yojson
         ~of_yojson:Sessions.worker_run_of_yojson
         ~show:Sessions.show_worker_run
         ~name:(Printf.sprintf "worker_run_%s" (Sessions.show_worker_status status))
         v)
    Sessions.[ Planned; Accepted; Ready; Running; Completed; Failed ]
;;

(* ── worker_run with each trace_capability ──────────────────────── *)

let test_worker_run_trace_capabilities () =
  List.iter
    (fun tc ->
       let v : Sessions.worker_run =
         { (mk_worker_run Sessions.Completed) with trace_capability = tc }
       in
       roundtrip
         ~to_yojson:Sessions.worker_run_to_yojson
         ~of_yojson:Sessions.worker_run_of_yojson
         ~show:Sessions.show_worker_run
         ~name:(Printf.sprintf "worker_run_tc_%s" (Sessions.show_trace_capability tc))
         v)
    Sessions.[ Raw; Summary_only; No_trace ]
;;

(* ── validation_check roundtrip ─────────────────────────────────── *)

let test_validation_check () =
  let passed : Raw_trace.validation_check = { name = "seq_ok"; passed = true } in
  roundtrip
    ~to_yojson:Raw_trace.validation_check_to_yojson
    ~of_yojson:Raw_trace.validation_check_of_yojson
    ~show:Raw_trace.show_validation_check
    ~name:"validation_check_pass"
    passed;
  let failed : Raw_trace.validation_check = { name = "run_finished"; passed = false } in
  roundtrip
    ~to_yojson:Raw_trace.validation_check_to_yojson
    ~of_yojson:Raw_trace.validation_check_of_yojson
    ~show:Raw_trace.show_validation_check
    ~name:"validation_check_fail"
    failed
;;

(* ── record_type roundtrip ──────────────────────────────────────── *)

let test_record_type_roundtrip () =
  List.iter
    (fun rt ->
       roundtrip
         ~to_yojson:Raw_trace.record_type_to_yojson
         ~of_yojson:Raw_trace.record_type_of_yojson
         ~show:Raw_trace.show_record_type
         ~name:(Printf.sprintf "record_type_%s" (Raw_trace.show_record_type rt))
         rt)
    Raw_trace.
      [ Run_started
      ; Assistant_block
      ; Tool_execution_started
      ; Tool_execution_finished
      ; Hook_invoked
      ; Run_finished
      ]
;;

(* ── record (full trace record) roundtrip ───────────────────────── *)

let test_record_full () =
  let v : Raw_trace.record =
    { trace_version = Raw_trace.trace_version
    ; worker_run_id = "wr-00112233-aaaa-0001"
    ; seq = 5
    ; ts = 1.7e9
    ; agent_name = "builder"
    ; session_id = Some "s-100"
    ; record_type = Raw_trace.Tool_execution_finished
    ; prompt = None
    ; model = None
    ; tool_choice = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; block_index = None
    ; block_kind = None
    ; assistant_block = None
    ; tool_use_id = Some "tu-001"
    ; tool_name = Some "bash"
    ; tool_input = Some (`Assoc [ "command", `String "ls" ])
    ; tool_turn = None
    ; tool_planned_index = None
    ; tool_batch_index = None
    ; tool_batch_size = None
    ; tool_execution_mode = None
    ; tool_result = Some "file.txt\n"
    ; tool_error = Some false
    ; hook_name = None
    ; hook_decision = None
    ; hook_detail = None
    ; final_text = None
    ; stop_reason = None
    ; error = None
    }
  in
  roundtrip
    ~to_yojson:Raw_trace.record_to_yojson
    ~of_yojson:Raw_trace.record_of_yojson
    ~show:Raw_trace.show_record
    ~name:"record_tool_exec"
    v
;;

let test_record_minimal () =
  let v : Raw_trace.record =
    { trace_version = Raw_trace.trace_version
    ; worker_run_id = "wr-min"
    ; seq = 1
    ; ts = 1.0
    ; agent_name = "a"
    ; session_id = None
    ; record_type = Raw_trace.Run_started
    ; prompt = Some "hello"
    ; model = Some "glm-5.1"
    ; tool_choice = Some (Agent_sdk.Types.tool_choice_to_json Agent_sdk.Types.Any)
    ; enable_thinking = Some false
    ; preserve_thinking = None
    ; thinking_budget = Some 2048
    ; reasoning_effort = Some "high"
    ; block_index = None
    ; block_kind = None
    ; assistant_block = None
    ; tool_use_id = None
    ; tool_name = None
    ; tool_input = None
    ; tool_turn = None
    ; tool_planned_index = None
    ; tool_batch_index = None
    ; tool_batch_size = None
    ; tool_execution_mode = None
    ; tool_result = None
    ; tool_error = None
    ; hook_name = None
    ; hook_decision = None
    ; hook_detail = None
    ; final_text = None
    ; stop_reason = None
    ; error = None
    }
  in
  roundtrip
    ~to_yojson:Raw_trace.record_to_yojson
    ~of_yojson:Raw_trace.record_of_yojson
    ~show:Raw_trace.show_record
    ~name:"record_minimal"
    v
;;

(* ── proof_bundle composite roundtrip ───────────────────────────── *)

let mk_runtime_session () : Runtime.session =
  { session_id = "s-001"
  ; goal = "verify proof bundle"
  ; title = Some "Proof"
  ; tag = Some "coverage"
  ; phase = Runtime.Completed
  ; created_at = 1.0
  ; updated_at = 2.0
  ; provider = Some "anthropic"
  ; model = Some "claude-sonnet"
  ; system_prompt = Some "system"
  ; workdir = Some "/tmp"
  ; planned_participants = [ "tester" ]
  ; participants = []
  ; artifacts = []
  ; pending_input = None
  ; turn_count = 1
  ; last_seq = 3
  ; outcome = Some "ok"
  }
;;

let test_proof_bundle_roundtrip () =
  let run_ref = mk_run_ref () in
  let worker = mk_worker_run Sessions.Completed in
  let telemetry_step : Sessions.telemetry_step =
    { seq = 1
    ; ts = 1.0
    ; kind = "Agent_completed"
    ; participant = Some "tester"
    ; detail = Some "done"
    }
  in
  let structured_step : Sessions.structured_telemetry_step =
    { seq = 1
    ; ts = 1.0
    ; event_name = "agent_completed"
    ; participant = Some "tester"
    ; detail = Some "done"
    ; actor = Some "agent"
    ; role = Some "worker"
    ; provider = Some "anthropic"
    ; model = Some "claude-sonnet"
    ; raw_trace_run_id = Some run_ref.worker_run_id
    ; stop_reason = Some "end_turn"
    ; artifact_id = Some "artifact-1"
    ; artifact_name = Some "report"
    ; artifact_kind = Some "json"
    ; checkpoint_label = Some "final"
    ; outcome = Some "ok"
    ; dropped_output_deltas = Some 0
    ; persistence_failure_phase = None
    }
  in
  let bundle : Sessions.proof_bundle =
    { session = mk_runtime_session ()
    ; report =
        { Runtime.session_id = "s-001"
        ; summary = [ "completed" ]
        ; markdown = "# completed"
        ; generated_at = 3.0
        }
    ; proof =
        { Runtime.session_id = "s-001"
        ; ok = true
        ; checks = [ ({ name = "seq_contiguous"; passed = true } : Runtime.proof_check) ]
        ; evidence = [ "events=3" ]
        ; generated_at = 3.0
        }
    ; telemetry =
        { session_id = "s-001"
        ; generated_at = 3.0
        ; step_count = 1
        ; event_counts = [ { name = "Agent_completed"; count = 1 } ]
        ; steps = [ telemetry_step ]
        }
    ; structured_telemetry =
        { session_id = "s-001"
        ; generated_at = 3.0
        ; step_count = 1
        ; event_counts = [ { event_name = "agent_completed"; count = 1 } ]
        ; steps = [ structured_step ]
        }
    ; evidence =
        { session_id = "s-001"
        ; generated_at = 3.0
        ; files =
            [ { label = "report"
              ; path = "/tmp/report.json"
              ; size_bytes = 12
              ; md5 = "0123456789abcdef0123456789abcdef"
              }
            ]
        ; missing_files = [ { label = "proof"; path = "/tmp/proof.json" } ]
        }
    ; hook_summary =
        [ { hook_name = "pre_tool"
          ; count = 1
          ; latest_decision = Some "allow"
          ; latest_detail = Some "ok"
          ; latest_ts = Some 2.0
          }
        ]
    ; tool_catalog =
        [ { name = "read_file"
          ; description = "Read a file"
          ; origin = Some "runtime"
          ; execution_mode = Tool_contract.Concurrent
          ; completion = Tool_contract.Continue_after_success
          }
        ]
    ; latest_raw_trace_run = Some run_ref
    ; raw_trace_runs = [ run_ref ]
    ; raw_trace_summaries = [ mk_run_summary () ]
    ; raw_trace_validations = [ mk_run_validation () ]
    ; worker_runs = [ worker ]
    ; latest_accepted_worker_run = None
    ; latest_ready_worker_run = None
    ; latest_running_worker_run = None
    ; latest_worker_run = Some worker
    ; latest_completed_worker_run = Some worker
    ; latest_validated_worker_run = Some worker
    ; latest_failed_worker_run = None
    ; validated_worker_runs = [ worker ]
    ; raw_trace_run_count = 1
    ; validated_worker_run_count = 1
    ; trace_capabilities = [ Sessions.Raw; Sessions.Summary_only; Sessions.No_trace ]
    ; capabilities = { raw_trace = true; validated_summary = true; proof_bundle = true }
    }
  in
  roundtrip_json_stable
    ~to_yojson:Sessions.proof_bundle_to_yojson
    ~of_yojson:Sessions.proof_bundle_of_yojson
    ~name:"proof_bundle"
    bundle;
  Alcotest.(check bool)
    "show proof bundle"
    true
    (String.length (Sessions.show_proof_bundle bundle) > 0)
;;

(* ── Test runner ───────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Sessions_types_deep"
    [ ( "raw_trace_run"
      , [ Alcotest.test_case "full" `Quick test_raw_trace_run_full
        ; Alcotest.test_case "no session_id" `Quick test_raw_trace_run_no_session
        ; Alcotest.test_case "json stability" `Quick test_raw_trace_run_json_stable
        ] )
    ; ( "raw_trace_summary"
      , [ Alcotest.test_case "full" `Quick test_raw_trace_summary_full
        ; Alcotest.test_case "empty lists" `Quick test_raw_trace_summary_empty_lists
        ; Alcotest.test_case "with error" `Quick test_raw_trace_summary_with_error
        ] )
    ; ( "raw_trace_validation"
      , [ Alcotest.test_case "pass" `Quick test_raw_trace_validation_pass
        ; Alcotest.test_case "fail" `Quick test_raw_trace_validation_fail
        ; Alcotest.test_case "empty checks" `Quick test_raw_trace_validation_empty_checks
        ] )
    ; ( "raw_trace_manifest"
      , [ Alcotest.test_case "roundtrip" `Quick test_raw_trace_manifest_roundtrip ] )
    ; ( "worker_run_statuses"
      , [ Alcotest.test_case "all 6 variants" `Quick test_worker_run_all_statuses
        ; Alcotest.test_case
            "trace capabilities"
            `Quick
            test_worker_run_trace_capabilities
        ] )
    ; ( "validation_check"
      , [ Alcotest.test_case "pass and fail" `Quick test_validation_check ] )
    ; ( "record_type"
      , [ Alcotest.test_case "all 6 variants" `Quick test_record_type_roundtrip ] )
    ; ( "record"
      , [ Alcotest.test_case "tool execution" `Quick test_record_full
        ; Alcotest.test_case "minimal run_started" `Quick test_record_minimal
        ] )
    ; ( "proof_bundle"
      , [ Alcotest.test_case "roundtrip" `Quick test_proof_bundle_roundtrip ] )
    ]
;;
