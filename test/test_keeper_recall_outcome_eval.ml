module Eval = Masc.Keeper_recall_outcome_eval

let write_lines path lines =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  let closed = ref false in
  let close_propagating () =
    try
      close_out oc;
      closed := true
    with exn ->
      close_out_noerr oc;
      closed := true;
      raise exn
  in
  Fun.protect
    ~finally:(fun () -> if not !closed then close_out_noerr oc)
    (fun () ->
       List.iter (fun line -> output_string oc line; output_char oc '\n') lines;
       close_propagating ())
;;

let read_lines path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         match input_line ic with
         | line -> loop (line :: acc)
         | exception End_of_file -> List.rev acc
       in
       loop [])
;;

let with_temp_masc_root f =
  let marker = Filename.temp_file "recall-outcome-eval-" ".tmp" in
  Sys.remove marker;
  Fs_compat.mkdir_p marker;
  f marker
;;

let test_joins_recall_to_receipts () =
  with_temp_masc_root (fun masc_root ->
    write_lines
      (Filename.concat masc_root "recall_injections/2026-06/27.jsonl")
      [ {|{"keeper_id":"alpha","trace_id":"trace-1","turn":1,"injected_fact_keys":["a","b"],"injected_episode_keys":[],"n_facts_in_store":2,"ts":1.0}|}
      ; {|{"keeper_id":"alpha","trace_id":"trace-1","turn":2,"injected_fact_keys":["a"],"injected_episode_keys":["trace-1:g0"],"n_facts_in_store":2,"ts":2.0}|}
      ; {|{"keeper_id":"beta","trace_id":"trace-2","turn":1,"injected_fact_keys":[],"injected_episode_keys":[],"n_facts_in_store":0,"failure_reason":"prompt_render_error","ts":3.0}|}
      ];
    write_lines
      (Filename.concat
         masc_root
         "keepers/alpha/execution-receipts/2026-06/27.jsonl")
      [ {|{"schema":"keeper.execution_receipt.v1","keeper_name":"alpha","trace_id":"trace-1","outcome":"receipt_done","terminal_reason_code":"completed","current_task_id":"T-1","ended_at":"2026-06-27T00:00:00Z"}|}
      ];
    let report = Eval.evaluate ~masc_root in
    Alcotest.(check int) "read errors" 0 report.read_error_count;
    Alcotest.(check int) "malformed rows" 0 report.malformed_jsonl_rows;
    Alcotest.(check int) "invalid recall rows" 0 report.invalid_recall_rows;
    Alcotest.(check int) "invalid receipt rows" 0 report.invalid_receipt_rows;
    Alcotest.(check int) "recall records" 3 report.recall_records;
    Alcotest.(check int) "recall traces" 2 report.recall_traces;
    Alcotest.(check int) "joined traces" 1 report.traces_with_receipt;
    Alcotest.(check int) "missing receipt" 1 report.traces_without_receipt;
    Alcotest.(check int) "fact keys" 3 report.injected_fact_keys;
    Alcotest.(check int) "recall failures" 1 report.recall_failure_records;
    Alcotest.(check int) "ok outcomes" 1 report.outcome_ok;
    (match
       List.find_opt
         (fun row -> String.equal row.Eval.fact_key "a")
         report.fact_key_summaries
     with
     | Some row ->
       Alcotest.(check int) "fact a trace count" 1 row.trace_count;
       Alcotest.(check int) "fact a injections" 2 row.injected_count;
       Alcotest.(check int) "fact a ok outcomes" 1 row.outcome_ok
     | None -> Alcotest.fail "missing fact key summary a");
    match List.find_opt (fun row -> String.equal row.Eval.trace_id "trace-1") report.traces with
    | Some row ->
      Alcotest.(check string)
        "bucket"
        "ok"
        (Eval.outcome_bucket_to_string row.outcome_bucket);
      Alcotest.(check (list string)) "trace fact keys" [ "a"; "b" ] row.fact_keys;
      Alcotest.(check int) "trace recall count" 2 row.recall_records;
      (match row.receipt with
       | Some receipt ->
         Alcotest.(check bool) "receipt ended_at parsed" true
           (Option.is_some receipt.ended_at_unix)
       | None -> Alcotest.fail "missing receipt")
    | None -> Alcotest.fail "missing trace-1")
;;

let test_surfaces_bad_rows_and_uses_typed_outcome () =
  with_temp_masc_root (fun masc_root ->
    write_lines
      (Filename.concat masc_root "recall_injections/2026-06/27.jsonl")
      [ {|{"keeper_id":"alpha","trace_id":"trace-1","turn":1,"injected_fact_keys":["a"],"injected_fact_key_count":7,"injected_episode_keys":[],"ts":1.0}|}
      ; {|{"keeper_id":"alpha","turn":2,"injected_fact_keys":[],"injected_episode_keys":[]}|}
      ; {|{"keeper_id":"alpha","trace_id":"trace-bad","turn":3,"injected_fact_keys":[1],"injected_episode_keys":[]}|}
      ; {|{"keeper_id":|}
      ];
    write_lines
      (Filename.concat
         masc_root
         "keepers/alpha/execution-receipts/2026-06/27.jsonl")
      [ {|{"schema":"keeper.execution_receipt.v1","keeper_name":"alpha","trace_id":"trace-1","outcome":"receipt_cancelled","terminal_reason_code":"cancelled","ended_at":"2026-06-27T00:00:00Z"}|}
      ; {|{"schema":"keeper.execution_receipt.v1","keeper_name":"alpha","trace_id":"trace-2","outcome":"receipt_done","ended_at":"not-a-time"}|}
      ];
    write_lines
      (Filename.concat masc_root "keepers/alpha/metrics/2026-06/27.jsonl")
      [ {|{"trace_id":"trace-ignored","outcome":"receipt_failed"}|} ];
    let report = Eval.evaluate ~masc_root in
    Alcotest.(check int) "recall records" 1 report.recall_records;
    Alcotest.(check int) "typed cancelled outcome" 1 report.outcome_cancelled;
    Alcotest.(check int) "explicit injected count" 7 report.injected_fact_keys;
    Alcotest.(check int) "malformed rows" 1 report.malformed_jsonl_rows;
    Alcotest.(check int) "invalid recall rows" 2 report.invalid_recall_rows;
    Alcotest.(check int) "invalid receipt rows" 1 report.invalid_receipt_rows;
    Alcotest.(check int) "receipt metrics rows ignored" 0 report.outcome_error;
    Alcotest.(check bool) "load error details" true (report.load_errors <> []))
;;

let test_selects_newest_receipt_by_timestamp () =
  with_temp_masc_root (fun masc_root ->
    write_lines
      (Filename.concat masc_root "recall_injections/2026-06/27.jsonl")
      [ {|{"keeper_id":"alpha","trace_id":"trace-1","turn":1,"injected_fact_keys":[],"injected_episode_keys":[],"ts":1.0}|}
      ];
    write_lines
      (Filename.concat
         masc_root
         "keepers/alpha/execution-receipts/2026-06/27.jsonl")
      [ {|{"schema":"keeper.execution_receipt.v1","keeper_name":"alpha","trace_id":"trace-1","outcome":"receipt_failed","terminal_reason_code":"error","ended_at":"2026-06-27T00:00:02Z"}|}
      ; {|{"schema":"keeper.execution_receipt.v1","keeper_name":"alpha","trace_id":"trace-1","outcome":"receipt_done","terminal_reason_code":"completed","ended_at":"2026-06-27T00:00:03Z"}|}
      ];
    let report = Eval.evaluate ~masc_root in
    Alcotest.(check int) "ok newest outcome" 1 report.outcome_ok;
    Alcotest.(check int) "older error ignored" 0 report.outcome_error)
;;

let test_json_respects_trace_limit () =
  with_temp_masc_root (fun masc_root ->
    write_lines
      (Filename.concat masc_root "recall_injections/2026-06/27.jsonl")
      [ {|{"keeper_id":"alpha","trace_id":"trace-1","turn":1,"injected_fact_keys":[],"injected_episode_keys":[],"n_facts_in_store":0}|}
      ; {|{"keeper_id":"alpha","trace_id":"trace-2","turn":1,"injected_fact_keys":[],"injected_episode_keys":[],"n_facts_in_store":0}|}
      ];
    let json =
      Eval.evaluate ~masc_root |> Eval.to_json ~trace_limit:1 ~fact_key_limit:0
    in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "traces" fields with
       | Some (`List [ _ ]) -> ()
       | _ -> Alcotest.fail "expected one trace in limited JSON")
    | _ -> Alcotest.fail "expected JSON object")
;;

let test_writes_fact_key_summary_index () =
  with_temp_masc_root (fun masc_root ->
    write_lines
      (Filename.concat masc_root "recall_injections/2026-06/27.jsonl")
      [ {|{"keeper_id":"alpha","trace_id":"trace-ok","turn":1,"injected_fact_keys":["shared:a"],"injected_episode_keys":[]}|}
      ; {|{"keeper_id":"beta","trace_id":"trace-err","turn":1,"injected_fact_keys":["shared:a"],"injected_episode_keys":[]}|}
      ];
    write_lines
      (Filename.concat
         masc_root
         "keepers/alpha/execution-receipts/2026-06/27.jsonl")
      [ {|{"schema":"keeper.execution_receipt.v1","keeper_name":"alpha","trace_id":"trace-ok","outcome":"receipt_done","terminal_reason_code":"completed","ended_at":"2026-06-27T00:00:00Z"}|}
      ; {|{"schema":"keeper.execution_receipt.v1","keeper_name":"beta","trace_id":"trace-err","outcome":"receipt_failed","terminal_reason_code":"error","ended_at":"2026-06-27T00:00:01Z"}|}
      ];
    let report = Eval.evaluate ~masc_root in
    let path = Filename.concat masc_root "summary-index/facts.jsonl" in
    Eval.write_summary_index ~path report;
    match read_lines path with
    | [ line ] ->
      (match Yojson.Safe.from_string line with
       | `Assoc fields ->
         Alcotest.(check string)
           "fact key"
           "shared:a"
           (match List.assoc_opt "fact_key" fields with
            | Some (`String value) -> value
            | _ -> Alcotest.fail "missing fact_key");
         (match List.assoc_opt "outcomes" fields with
          | Some (`Assoc outcome_fields) ->
            Alcotest.(check int)
              "ok"
              1
              (match List.assoc_opt "ok" outcome_fields with
               | Some (`Int value) -> value
               | _ -> Alcotest.fail "missing ok");
            Alcotest.(check int)
              "error"
              1
              (match List.assoc_opt "error" outcome_fields with
               | Some (`Int value) -> value
               | _ -> Alcotest.fail "missing error")
          | _ -> Alcotest.fail "missing outcomes")
       | _ -> Alcotest.fail "expected JSON object")
    | lines ->
      Alcotest.failf "expected one summary-index row, got %d" (List.length lines))
;;

let () =
  Alcotest.run
    "keeper_recall_outcome_eval"
    [ ( "eval"
      , [ Alcotest.test_case "joins recall to receipts" `Quick test_joins_recall_to_receipts
        ; Alcotest.test_case "json respects trace limit" `Quick test_json_respects_trace_limit
        ; Alcotest.test_case
            "surfaces bad rows and uses typed outcome"
            `Quick
            test_surfaces_bad_rows_and_uses_typed_outcome
        ; Alcotest.test_case
            "selects newest receipt by timestamp"
            `Quick
            test_selects_newest_receipt_by_timestamp
        ; Alcotest.test_case
            "writes fact-key summary index"
            `Quick
            test_writes_fact_key_summary_index
        ] )
    ]
;;
