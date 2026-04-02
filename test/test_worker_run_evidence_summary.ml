open Alcotest
open Masc_mcp
open Test_tool_team_session_support

module U = Yojson.Safe.Util

let has_key key = function
  | `Assoc fields -> List.exists (fun (field, _) -> String.equal field key) fields
  | _ -> false

let sample_trace_ref ~session_id ~worker_run_id ~agent_name =
  `Assoc
    [
      ("session_id", `String session_id);
      ("worker_run_id", `String worker_run_id);
      ("agent_name", `String agent_name);
      ("start_seq", `Int 1);
      ("end_seq", `Int 9);
    ]

let sample_meta ?(trace_capability = `String "raw")
    ?(trace_ref =
      Some
        (sample_trace_ref ~session_id:"ts-evidence-summary"
           ~worker_run_id:"wr-evidence-1" ~agent_name:"worker-a"))
    ?(trace_summary =
      Some
        (`Assoc
          [
            ("record_count", `Int 8);
            ("assistant_block_count", `Int 3);
            ("final_text", `String "Patched calc.py and verification passed.");
            ("stop_reason", `String "end_turn");
          ]))
    ?(trace_validation =
      Some
        (`Assoc
          [
            ("ok", `Bool false);
            ( "checks",
              `List
                [
                  `Assoc [ ("name", `String "seq_monotonic"); ("passed", `Bool false) ];
                ] );
          ]))
    ?(proof_present = `Bool true) ?(proof_run_id = `String "proof-run-123")
    ?(tool_trace_refs =
      `List [ `String "proof-store://wr-evidence-1/tool_traces/trace-1.jsonl" ])
    ?(raw_evidence_refs =
      `List [ `String "proof-store://wr-evidence-1/evidence/mode_violations.json" ])
    ?(checkpoint_ref = `String "proof-store://wr-evidence-1/checkpoint.json")
    ?(evidence_refs =
      `List [ `String "proof-store://wr-evidence-1/checkpoint.json" ])
    () =
  `Assoc
    [
      ("session_id", `String "ts-evidence-summary");
      ("operation_id", `String "op-evidence-summary");
      ("worker_run_id", `String "wr-evidence-1");
      ("worker_name", `String "worker-a");
      ("status", `String "completed");
      ("mode", `String "delegate");
      ("wait_mode", `String "background");
      ("success", `Bool true);
      ("trace_capability", trace_capability);
      ( "trace_ref",
        Option.value ~default:`Null trace_ref );
      ( "trace_summary",
        Option.value ~default:`Null trace_summary );
      ( "trace_validation",
        Option.value ~default:`Null trace_validation );
      ("execution_scope", `String "limited_code_change");
      ("requested_worker_class", `String "executor");
      ("requested_worker_size", `String "lg");
      ("resolved_runtime", `String "llama-8085");
      ("resolved_model", `String "qwen3.5-35b-a3b-ud-q8-xl");
      ("routing_reason", `String "explicit_task_profile");
      ("tool_names", `List [ `String "file_write"; `String "shell_exec" ]);
      ("tool_call_count", `Int 2);
      ("output_preview", `String "Patched calc.py and verification passed.");
      ("proof_present", proof_present);
      ("proof_run_id", proof_run_id);
      ("proof_status", `String "completed");
      ("proof_risk_class", `String "medium");
      ("proof_execution_mode", `String "execute");
      ("proof_evidence_count", `Int 2);
      ("tool_trace_refs", tool_trace_refs);
      ("raw_evidence_refs", raw_evidence_refs);
      ("checkpoint_ref", checkpoint_ref);
      ("evidence_session_id", `String "oas-proof-session");
      ("evidence_refs", evidence_refs);
      ("validated", `Bool true);
      ("final_text", `String "Patched calc.py and verification passed.");
      ("failure_reason", `Null);
      ( "session_conformance",
        `Assoc
          [
            ("ok", `Bool true);
            ( "checks",
              `List
                [
                  `Assoc
                    [
                      ("name", `String "proof bundle available");
                      ("passed", `Bool true);
                    ];
                ] );
          ] );
      ("ts_iso", `String "2026-04-02T00:00:00Z");
    ]

let test_status_and_dashboard_use_canonical_summary () =
  let meta_json = sample_meta () in
  let canonical = Worker_run_evidence_summary.summary_json meta_json in
  let status_json = Team_session_engine_status.worker_run_status_json meta_json in
  let dashboard_json = Dashboard_proof_actors.worker_run_summary_json meta_json in
  check bool "status equals canonical" true (Yojson.Safe.equal canonical status_json);
  check bool "dashboard equals canonical" true
    (Yojson.Safe.equal canonical dashboard_json)

let test_summary_distinguishes_missing_vs_unavailable_evidence () =
  let missing_trace =
    Worker_run_evidence_summary.summary_json
      (sample_meta ~trace_ref:None ~trace_summary:None ~trace_validation:None ())
  in
  check string "raw trace without refs is missing" "missing"
    U.(missing_trace |> member "trace_evidence_status" |> to_string);
  let unavailable_trace =
    Worker_run_evidence_summary.summary_json
      (sample_meta ~trace_capability:(`String "summary_only") ~trace_ref:None
         ~trace_summary:None ~trace_validation:None ())
  in
  check string "summary_only without refs is unavailable" "unavailable"
    U.(unavailable_trace |> member "trace_evidence_status" |> to_string);
  let missing_proof =
    Worker_run_evidence_summary.summary_json
      (sample_meta ~proof_present:(`Bool true) ~proof_run_id:`Null
         ~tool_trace_refs:(`List []) ~raw_evidence_refs:(`List [])
         ~checkpoint_ref:`Null ~evidence_refs:(`List []) ())
  in
  check string "proof declared without refs is missing" "missing"
    U.(missing_proof |> member "proof_evidence_status" |> to_string);
  let unavailable_proof =
    Worker_run_evidence_summary.summary_json
      (sample_meta ~proof_present:(`Bool false) ~proof_run_id:`Null
         ~tool_trace_refs:(`List []) ~raw_evidence_refs:(`List [])
         ~checkpoint_ref:`Null ~evidence_refs:(`List []) ())
  in
  check string "proof absent without refs is unavailable" "unavailable"
    U.(unavailable_proof |> member "proof_evidence_status" |> to_string);
  let trace_only_evidence_refs =
    Worker_run_evidence_summary.summary_json
      (sample_meta ~proof_present:(`Bool false) ~proof_run_id:`Null
         ~tool_trace_refs:(`List []) ~raw_evidence_refs:(`List [])
         ~checkpoint_ref:`Null
         ~evidence_refs:(`List [ `String "traces/wr-evidence-1.jsonl" ]) ())
  in
  check string "trace-only evidence refs do not imply proof availability"
    "unavailable"
    U.(trace_only_evidence_refs |> member "proof_evidence_status" |> to_string);
  check bool "proof fields stay absent when no proof_run_id" false
    (has_key "proof_run_id" unavailable_proof);
  check bool "proof status stays absent when no proof_run_id" false
    (has_key "proof_status" unavailable_proof)

let test_verify_trace_returns_canonical_worker_run_summary () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    {
      config;
      agent_name = "owner";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = None;
      net = None;
    }
  in
  let session_id = start_session_exn ctx ~goal:"verify-trace-canonical" |> get_session_id in
  let worker_run_id = "run-trace-1" in
  ignore
    (write_worker_run_raw_trace_exn config ~session_id ~worker_run_id
       ~worker_name:"llama-local-impl");
  let verify_ok, verify_body =
    dispatch_exn ctx ~name:"masc_team_session_verify_trace"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("worker_run_id", `String worker_run_id);
          ])
  in
  check bool "verify trace ok" true verify_ok;
  let result = parse_json_exn verify_body |> result_field in
  let worker_run = U.member "worker_run" result in
  let meta_json =
    Team_session_store.worker_run_meta_path config session_id worker_run_id
    |> Room_utils.read_json config
  in
  let canonical = Worker_run_evidence_summary.summary_json meta_json in
  check bool "verify_trace worker_run uses canonical summary" true
    (Yojson.Safe.equal canonical worker_run);
  cleanup_dir base_dir

let () =
  Alcotest.run "worker_run_evidence_summary"
    [
      ( "summary",
        [
          test_case "status and dashboard use canonical summary" `Quick
            test_status_and_dashboard_use_canonical_summary;
          test_case "distinguishes missing vs unavailable evidence" `Quick
            test_summary_distinguishes_missing_vs_unavailable_evidence;
          test_case "verify_trace returns canonical worker run summary" `Quick
            test_verify_trace_returns_canonical_worker_run_summary;
        ] );
    ]
