(* Bounded parse-retry policy for librarian extraction (typed-harness contract
   C6). The retry combinator is pure given a pure [attempt], so these drive it
   with a stub instead of a provider and pin the policy in isolation:
   - parse success returns immediately (no retry),
   - an unparseable response is retried with a corrective nudge,
   - retries are bounded by [max_retries] (initial attempt not counted),
   - a transport failure is surfaced without retry,
   - exactly one nudge is appended per retry. *)

open Alcotest
module R = Masc.Keeper_librarian_runtime
module Lib = Masc.Keeper_librarian
module Types = Agent_sdk.Types

let field_episode_summary = Lib.wire_field_episode_summary
let field_claims = Lib.wire_field_claims
let field_claim = Lib.wire_field_claim
let deprecated_field_confidence = "confidence"
let field_category = Lib.wire_field_category
let field_source_turn = Lib.wire_field_source_turn
let field_source_tool_call_id = Lib.wire_field_source_tool_call_id
let field_claim_id = Lib.wire_field_claim_id

let claim_json ?confidence ?(claim = "c") ?(source_turn = `Int 0) () =
  let fields =
    [ field_claim, `String claim
    ; field_category, `String "fact"
    ; field_source_turn, source_turn
    ; field_source_tool_call_id, `Null
    ; field_claim_id, `Null
    ]
  in
  let fields =
    match confidence with
    | None -> fields
    | Some confidence -> (deprecated_field_confidence, confidence) :: fields
  in
  `Assoc fields
;;

let episode_json ?(episode_summary = "s") ?(claims = [ claim_json () ]) () =
  `Assoc
    [ field_episode_summary, `String episode_summary
    ; field_claims, `List claims
    ]
;;

(* Drive [cadence_step] sequentially from a fresh keeper (counter -1) for
   [turns] turns, collecting the [due] decision each turn. When a turn is due
   we simulate a successful extraction by resetting the counter to 0, matching
   the behavior of [run_best_effort] calling [cadence_record_success]. *)
let run_cadence ~cadence ~turns =
  let counter = ref (-1) in
  List.init turns (fun _ ->
    let next, due = R.cadence_step ~cadence ~counter:!counter in
    counter := next;
    if due then counter := 0;
    due)

let test_cadence_fresh_then_every_cadence () =
  (* cadence 3: first turn is due immediately, then wait three turns between
     subsequent extractions. *)
  check (list bool) "fresh due immediately, then every third turn"
    [ true; false; false; true; false; false; true; false; false ]
    (run_cadence ~cadence:3 ~turns:9)

let test_cadence_one_always_due () =
  (* cadence 1 (and the floored <=1 case) restores per-turn extraction. *)
  check (list bool) "cadence 1 is due every turn"
    [ true; true; true; true ]
    (run_cadence ~cadence:1 ~turns:4);
  check (pair int bool) "cadence<=1 pins counter at 0"
    (0, true)
    (R.cadence_step ~cadence:1 ~counter:5)

let test_cadence_step_transitions () =
  (* A fresh counter is due immediately and moves to the due threshold. *)
  check (pair int bool) "fresh keeper is due immediately"
    (3, true)
    (R.cadence_step ~cadence:3 ~counter:(-1));
  (* A due threshold stays due until reset by a successful extraction. *)
  check (pair int bool) "due counter stays at threshold"
    (3, true)
    (R.cadence_step ~cadence:3 ~counter:3);
  (* Mid-cycle advances without firing. *)
  check (pair int bool) "mid-cycle advances without firing"
    (2, false)
    (R.cadence_step ~cadence:3 ~counter:1)

let test_cadence_record_success_resets () =
  let kid = "test-cadence-record-success" and tid = "trace-record-success" in
  check bool "fresh (keeper, trace) is due" true
    (R.cadence_due ~keeper_id:kid ~trace_id:tid);
  R.cadence_record_success ~keeper_id:kid ~trace_id:tid;
  check bool "after success the next turn is not due" false
    (R.cadence_due ~keeper_id:kid ~trace_id:tid)

let test_cadence_record_attempt_defers () =
  let kid = "test-cadence-record-attempt" and tid = "trace-record-attempt" in
  check bool "fresh (keeper, trace) is due" true
    (R.cadence_due ~keeper_id:kid ~trace_id:tid);
  R.cadence_record_attempt ~keeper_id:kid ~trace_id:tid;
  check bool "after a completed non-success attempt the next turn is not due" false
    (R.cadence_due ~keeper_id:kid ~trace_id:tid)

(* [cadence_due] drives the real per-(keeper, trace) counter table (the gate
   [run_best_effort] uses). A fresh pair is due immediately, and successful
   structured extractions are due once per configured period. Asserted as
   period-invariants so they hold for any configured cadence. *)
let test_cadence_due_periodic () =
  let kid = "test-cadence-due-periodic" and tid = "trace-periodic" in
  let cadence = R.cadence_turns () in
  let periods = 4 in
  let dues = ref 0 in
  for _ = 1 to cadence * periods do
    if R.cadence_due ~keeper_id:kid ~trace_id:tid
    then (
      incr dues;
      R.cadence_record_success ~keeper_id:kid ~trace_id:tid)
  done;
  check int "exactly one extraction per cadence period" periods !dues

let test_cadence_due_independent_keepers () =
  let cadence = R.cadence_turns () in
  if cadence <= 1
  then () (* cadence 1: both due every turn, independence is trivial *)
  else (
    let ka = "test-cadence-due-ind-a" and ta = "trace-a"
    and kb = "test-cadence-due-ind-b" and tb = "trace-b" in
    (* Put ka into a persistent due state without recording a completed attempt. *)
    ignore (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    (* Put kb at counter 0 by recording success on its fresh due turn. *)
    ignore (R.cadence_due ~keeper_id:kb ~trace_id:tb);
    R.cadence_record_success ~keeper_id:kb ~trace_id:tb;
    (* ka remains due after skipped work; kb is mid-cycle and not due. *)
    check bool "ka stays due after skipped attempt" true
      (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    R.cadence_record_attempt ~keeper_id:ka ~trace_id:ta;
    check bool "ka backs off after completed non-success attempt" false
      (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    check bool "kb advances on its own counter, not due on ka's schedule" false
      (R.cadence_due ~keeper_id:kb ~trace_id:tb))

(* A handoff rollover (a new trace_id for the same keeper) resets the cadence
   schedule in place. The table is keyed by keeper_id, so the rotated trace
   overwrites the keeper's single row rather than minting a new one — the
   previous trace's counter is intentionally not preserved (production never has
   two live traces for one keeper; meta.runtime.trace_id is the single active
   trace and rolls over sequentially). *)
let test_cadence_due_resets_on_trace_rollover () =
  let cadence = R.cadence_turns () in
  if cadence <= 1
  then () (* cadence 1: every turn due, rollover semantics are trivial *)
  else (
    let kid = "test-cadence-rollover" and ta = "trace-a" and tb = "trace-b" in
    (* Advance trace a past its fresh-due turn to a non-due turn. *)
    if R.cadence_due ~keeper_id:kid ~trace_id:ta
    then R.cadence_record_success ~keeper_id:kid ~trace_id:ta;
    check bool "trace a is mid-cycle, not due" false
      (R.cadence_due ~keeper_id:kid ~trace_id:ta);
    (* A new trace (rollover) is fresh and due immediately, overwriting the row. *)
    check bool "rolled-over trace is due immediately" true
      (R.cadence_due ~keeper_id:kid ~trace_id:tb);
    (* Rolling back to trace a is itself a rollover off trace b: fresh, due
       immediately — the old trace-a counter was not retained. *)
    check bool "returning to the prior trace is a fresh rollover, due immediately"
      true
      (R.cadence_due ~keeper_id:kid ~trace_id:ta))

(* Leak regression: the cadence table is keyed by keeper_id, so an unbounded
   number of trace rotations for one keeper must add exactly one row (the
   pre-fix (keeper, trace) keying added one row per rotation and never reclaimed
   it). Measured as a delta so concurrent rows from other tests do not matter. *)
let test_cadence_table_bounded_under_trace_rotation () =
  let kid = "test-cadence-rotation-bound" in
  let before = R.cadence_counter_entries () in
  for i = 1 to 64 do
    ignore (R.cadence_due ~keeper_id:kid ~trace_id:(Printf.sprintf "rot-trace-%d" i))
  done;
  check int "64 trace rotations add exactly one keeper row" 1
    (R.cadence_counter_entries () - before)

(* Pure rollover decision: a stored entry from a different trace, or no entry,
   is fresh (due immediately) and the returned value carries the current trace;
   a matching trace advances the stored counter. *)
let test_cadence_step_keyed () =
  check (pair (pair string int) bool) "unseen keeper is fresh, due, carries trace"
    (("t1", 3), true)
    (R.cadence_step_keyed ~cadence:3 ~current_trace:"t1" ~prior:None);
  check (pair (pair string int) bool) "matching trace advances mid-cycle, not due"
    (("t1", 2), false)
    (R.cadence_step_keyed ~cadence:3 ~current_trace:"t1" ~prior:(Some ("t1", 1)));
  check (pair (pair string int) bool)
    "rotated trace is fresh (due), discards prior counter, carries new trace"
    (("t2", 3), true)
    (R.cadence_step_keyed ~cadence:3 ~current_trace:"t2" ~prior:(Some ("t1", 2)))

let message text =
  Agent_sdk.Types.make_message
    ~role:Agent_sdk.Types.User
    [ Agent_sdk.Types.Text text ]
;;

let expect_unexpected_field field json =
  let inp =
    { Lib.turn_ref =
        Masc.Ids.Turn_ref.make ~trace_id:"unexpected-field-t" ~absolute_turn:1
    ; messages = [ message "current JSON boundary" ]
    }
  in
  match Lib.episode_of_json_result ~now:1_000_000.0 ~generation:0 inp json with
  | Error (Lib.Unexpected_field got) -> check string "unexpected field" field got
  | Error error ->
    Alcotest.failf
      "expected Unexpected_field %s, got %s"
      field
      (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.failf "expected Unexpected_field %s" field
;;

let test_rejects_unexpected_episode_field () =
  List.iter
    (fun field ->
       let raw =
         `Assoc
           [ field_episode_summary, `String "s"
           ; field_claims, `List [ claim_json () ]
           ; field, `List []
           ]
       in
       expect_unexpected_field field raw)
    [ "open_items"; "constraints"; "preserved_tool_refs" ]
;;

let test_rejects_unexpected_claim_field () =
  expect_unexpected_field
    deprecated_field_confidence
    (episode_json
       ~claims:[ claim_json ~confidence:(`Float 0.9) () ]
       ())
;;

let () =
  Eio_main.run @@ fun _env ->
  run "keeper_librarian_retry"
    [
      ( "cadence",
        [
          test_case "fresh then every cadence" `Quick test_cadence_fresh_then_every_cadence;
          test_case "cadence 1 always due" `Quick test_cadence_one_always_due;
          test_case "step transitions" `Quick test_cadence_step_transitions;
          test_case "record success resets" `Quick test_cadence_record_success_resets;
          test_case "record attempt defers" `Quick test_cadence_record_attempt_defers;
          test_case "cadence_due fires once per period" `Quick test_cadence_due_periodic;
          test_case "cadence_due is per-keeper" `Quick test_cadence_due_independent_keepers;
          test_case "cadence_due resets on trace rollover" `Quick
            test_cadence_due_resets_on_trace_rollover;
          test_case "cadence table bounded under trace rotation" `Quick
            test_cadence_table_bounded_under_trace_rotation;
          test_case "cadence_step_keyed rollover decision" `Quick test_cadence_step_keyed;
        ] );
      ( "current_json_boundary",
        [ test_case "rejects unexpected episode field" `Quick
            test_rejects_unexpected_episode_field
        ; test_case
            "rejects unexpected claim field"
            `Quick
            test_rejects_unexpected_claim_field
        ] );
    ]
