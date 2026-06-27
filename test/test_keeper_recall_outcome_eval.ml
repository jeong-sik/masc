module Eval = Masc.Keeper_recall_outcome_eval

let mkdir_p path =
  let rec loop path =
    if path = "" || path = Filename.current_dir_name
    then ()
    else if Sys.file_exists path
    then ()
    else (
      let parent = Filename.dirname path in
      if not (String.equal parent path) then loop parent;
      Unix.mkdir path 0o755)
  in
  loop path
;;

let write_lines path lines =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       List.iter (fun line -> output_string oc line; output_char oc '\n') lines;
       close_out oc)
;;

let with_temp_masc_root f =
  let marker = Filename.temp_file "recall-outcome-eval-" ".tmp" in
  Sys.remove marker;
  mkdir_p marker;
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
      [ {|{"keeper_name":"alpha","trace_id":"trace-1","outcome":"receipt_done","terminal_reason_code":"completed","current_task_id":"T-1","ended_at":"2026-06-27T00:00:00Z"}|}
      ];
    let report = Eval.evaluate ~masc_root in
    Alcotest.(check int) "recall records" 3 report.recall_records;
    Alcotest.(check int) "recall traces" 2 report.recall_traces;
    Alcotest.(check int) "joined traces" 1 report.traces_with_receipt;
    Alcotest.(check int) "missing receipt" 1 report.traces_without_receipt;
    Alcotest.(check int) "fact keys" 3 report.injected_fact_keys;
    Alcotest.(check int) "recall failures" 1 report.recall_failure_records;
    Alcotest.(check int) "ok outcomes" 1 report.outcome_ok;
    match List.find_opt (fun row -> String.equal row.Eval.trace_id "trace-1") report.traces with
    | Some row ->
      Alcotest.(check string)
        "bucket"
        "ok"
        (Eval.outcome_bucket_to_string row.outcome_bucket);
      Alcotest.(check int) "trace recall count" 2 row.recall_records
    | None -> Alcotest.fail "missing trace-1")
;;

let test_json_respects_trace_limit () =
  with_temp_masc_root (fun masc_root ->
    write_lines
      (Filename.concat masc_root "recall_injections/2026-06/27.jsonl")
      [ {|{"keeper_id":"alpha","trace_id":"trace-1","turn":1,"injected_fact_keys":[],"injected_episode_keys":[],"n_facts_in_store":0}|}
      ; {|{"keeper_id":"alpha","trace_id":"trace-2","turn":1,"injected_fact_keys":[],"injected_episode_keys":[],"n_facts_in_store":0}|}
      ];
    let json = Eval.evaluate ~masc_root |> Eval.to_json ~trace_limit:1 in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "traces" fields with
       | Some (`List [ _ ]) -> ()
       | _ -> Alcotest.fail "expected one trace in limited JSON")
    | _ -> Alcotest.fail "expected JSON object")
;;

let () =
  Alcotest.run
    "keeper_recall_outcome_eval"
    [ ( "eval"
      , [ Alcotest.test_case "joins recall to receipts" `Quick test_joins_recall_to_receipts
        ; Alcotest.test_case "json respects trace limit" `Quick test_json_respects_trace_limit
        ] )
    ]
;;
