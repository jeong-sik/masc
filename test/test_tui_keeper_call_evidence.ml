open Alcotest
module Decode = Masc.Tui_decode
module Evidence = Masc_tui_keeper_call_evidence
module Transcript = Masc_tui_keeper_chat_transcript

let row ?(keeper="alpha") ?(tool="Read") ?(execution="exec-1")
    ?(disposition="completed") ?(output=`Null) () =
  `Assoc ["keeper", `String keeper; "ts", `Float 100.; "tool", `String tool;
    "execution_id", `String execution; "input", `String "{}";
    "disposition", `String disposition; "output", output]

let snapshot ?(keeper="alpha") ?(health="ok") rows =
  match Decode.decode_keeper_calls_snapshot ~requested_keeper:"alpha"
    (`Assoc ["keeper", `String keeper; "health", `String health;
      "entries", `List rows]) with
  | Ok value -> value
  | Error detail -> fail detail

let resolve ?(loaded_keeper=Some "alpha") ?(loading=false) ?error
    ?(execution_id=Some "exec-1") snapshot =
  Evidence.resolve ~keeper_name:"alpha" ~execution_id ~loaded_keeper
    ~loading ~error ~snapshot

let exact = function Evidence.Call_execution_exact _ -> true | _ -> false
let missing = function Evidence.Call_execution_missing -> true | _ -> false
let gap = function Evidence.Call_execution_coverage_gap _ -> true | _ -> false

let identity_and_coverage () =
  let complete = snapshot [row ()] in
  check bool "same execution admits the receipt" true (exact (resolve (Some complete)));
  check bool "different keeper selection does not join" true
    (resolve ~loaded_keeper:(Some "beta") (Some complete) = Evidence.Call_log_not_loaded);
  check bool "foreign snapshot does not join" true
    (resolve (Some (snapshot ~keeper:"beta" [row ()])) = Evidence.Call_log_not_loaded);
  check bool "no execution id cannot select a receipt" true
    (resolve ~execution_id:None (Some complete) = Evidence.Call_execution_unrecorded);
  check bool "duplicate identity never picks one receipt" true
    (resolve (Some (snapshot [row (); row ()])) = Evidence.Call_execution_ambiguous 2);
  let absent health = resolve (Some (snapshot ~health [])) in
  List.iter (fun health -> check bool "complete absence is proven" true (missing (absent health)))
    ["ok"; "empty"; "missing"];
  List.iter (fun health -> check bool "incomplete absence stays unproven" true (gap (absent health)))
    ["stale"; "coverage_gap"; "future-health"];
  check bool "filtered foreign receipt leaves an absence gap" true
    (gap (resolve (Some (snapshot [row ~keeper:"beta" ()]))))

let refresh_retains_evidence () =
  check bool "first load has no evidence" true
    (resolve ~loading:true None = Evidence.Call_log_loading);
  let retained = snapshot [row ()] in
  check bool "refresh retains exact receipt" true
    (exact (resolve ~loading:true (Some retained)));
  check bool "refresh failure retains exact receipt" true
    (exact (resolve ~error:"refresh failed" (Some retained)));
  check bool "refresh failure cannot prove absence" true
    (resolve ~error:"refresh failed" ~execution_id:(Some "absent") (Some retained)
      = Evidence.Call_log_unavailable "refresh failed");
  check bool "failure with no snapshot stays unavailable" true
    (resolve ~error:"unavailable" None = Evidence.Call_log_unavailable "unavailable")

let durable_and_transcript_evidence () =
  let successful = resolve (Some (snapshot
    [row ~tool:"failed · running, returned" ~output:(`String "failed payload") ()])) in
  List.iter (fun outcome ->
    check bool "recorded output is evidence without turn delivery" true
      (Evidence.result_state outcome successful = Evidence.Durable_output))
    [Transcript.Started; Awaiting_result; Never_returned];
  check bool "native observation remains a native observation" true
    (Evidence.result_state Transcript.Native_ended successful
      = Evidence.Transcript_outcome Transcript.Native_ended);
  check bool "delivered transcript remains delivered" true
    (Evidence.result_state Transcript.Returned successful
      = Evidence.Transcript_outcome Transcript.Returned);
  let failed = resolve (Some (snapshot [row ~disposition:"failed" ()])) in
  check bool "exact durable failure wins over delivered transcript" true
    (Evidence.result_state Transcript.Returned failed = Evidence.Durable_failed);
  let deferred = resolve (Some (snapshot [row ~disposition:"deferred" ()])) in
  check bool "deferred receipt is not durable failure" false
    (Evidence.durable_call_failed deferred);
  check bool "receipt without output does not invent delivery" true
    (Evidence.result_state Transcript.Awaiting_result deferred
      = Evidence.Transcript_outcome Transcript.Awaiting_result);
  match successful with
  | Evidence.Call_execution_exact call ->
      check string "literal tool identity is preserved" "failed · running, returned" call.kc_tool
  | _ -> fail "missing exact receipt"

let () = run "keeper_call_evidence"
  ["receipt decisions", [
    test_case "identity and coverage boundaries" `Quick identity_and_coverage;
    test_case "refresh retains admitted evidence" `Quick refresh_retains_evidence;
    test_case "durable and transcript evidence stay distinct" `Quick durable_and_transcript_evidence]]
