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

(* A minimal valid episode, parsed from known-good JSON, reused as the [Parsed]
   payload so the stub does not have to fabricate the record by hand. *)
let sample_episode () =
  let raw =
    {|{"episode_summary":"s","claims":[{"claim":"c","confidence":0.9,"category":"fact","source_turn":0}],"open_items":[],"constraints":[],"preserved_tool_refs":[]}|}
  in
  let inp = { Lib.trace_id = "t"; generation = 0; messages = [] } in
  match Lib.episode_of_output ~now:1_000_000.0 inp raw with
  | Some ep -> ep
  | None -> Alcotest.fail "fixture episode failed to parse"

let parse_retry_error_to_string = function
  | R.Retry_exhausted_unparseable e -> "unparseable: " ^ e
  | R.Retry_transport_failed e -> "transport: " ^ e

let nudge_count messages =
  List.length
    (List.filter
       (fun (m : Types.message) ->
         List.exists
           (function
             | Types.Text t -> String.equal t R.parse_retry_nudge
             | _ -> false)
           m.content)
       messages)

let test_succeeds_first_attempt () =
  let ep = sample_episode () in
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Parsed ep
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> ()
   | Error e ->
     Alcotest.failf "expected Ok, got Error %s" (parse_retry_error_to_string e));
  check int "no retry when first attempt parses" 1 !calls

let test_retries_then_succeeds () =
  let ep = sample_episode () in
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    if !calls < 2 then R.Unparseable "bad json" else R.Parsed ep
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> ()
   | Error e ->
     Alcotest.failf
       "expected Ok after retry, got %s"
       (parse_retry_error_to_string e));
  check int "one retry to recover" 2 !calls

let test_bounded_then_fails () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Unparseable "still bad"
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> Alcotest.fail "expected Error after exhausting retries"
   | Error (R.Retry_exhausted_unparseable e) ->
     check string "last error surfaced" "still bad" e
   | Error (R.Retry_transport_failed e) ->
     Alcotest.failf "expected unparseable exhaustion, got transport %s" e);
  check int "initial attempt + max_retries" 3 !calls

let test_transport_not_retried () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Transport_failed "timeout"
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> Alcotest.fail "expected Error"
   | Error (R.Retry_transport_failed e) ->
     check string "transport error surfaced" "timeout" e
   | Error (R.Retry_exhausted_unparseable e) ->
     Alcotest.failf "expected transport error, got unparseable %s" e);
  check int "transport failure is not retried" 1 !calls

let test_nudge_appended_each_retry () =
  let ep = sample_episode () in
  let seen = ref [] in
  let calls = ref 0 in
  let attempt msgs =
    incr calls;
    seen := msgs :: !seen;
    if !calls < 3 then R.Unparseable "bad" else R.Parsed ep
  in
  let _ = R.run_with_parse_retries ~max_retries:3 ~attempt [] in
  (* Attempt 1 sees 0 nudges, attempt 2 sees 1, attempt 3 sees 2. *)
  let counts = List.rev_map nudge_count !seen in
  check (list int) "one nudge added per retry" [ 0; 1; 2 ] counts

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

(* [cadence_due] drives the real per-(keeper, trace) counter table (the gate
   [run_best_effort] uses). A fresh pair is due immediately, and failures are
   left due until [cadence_record_success] is called. Asserted as
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
    (* Put ka into a persistent due state without recording success. *)
    ignore (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    (* Put kb at counter 0 by recording success on its fresh due turn. *)
    ignore (R.cadence_due ~keeper_id:kb ~trace_id:tb);
    R.cadence_record_success ~keeper_id:kb ~trace_id:tb;
    (* ka remains due; kb is mid-cycle and not due. *)
    check bool "ka stays due after failed/skipped attempt" true
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

(* Tolerant parsing for real-world librarian provider drift. *)

let parse_ep raw =
  let inp = { Lib.trace_id = "tolerant-t"; generation = 0; messages = [] } in
  Lib.episode_of_output ~now:1_000_000.0 inp raw
;;

let test_parses_markdown_wrapped () =
  let raw =
    "```json\n\
     {\"episode_summary\":\"s\",\"claims\":[],\"open_items\":[],\"constraints\":[],\"preserved_tool_refs\":[]}\n\
     ```"
  in
  match parse_ep raw with
  | Some ep ->
    check string "episode_summary" "s" ep.episode_summary;
    check int "claims count" 0 (List.length ep.claims)
  | None -> Alcotest.fail "markdown-wrapped JSON should parse"
;;

let test_parses_prose_wrapped () =
  let raw =
    "Here is the episode you requested:\n\
     ```json\n\
     {\"episode_summary\":\"s\",\"claims\":[],\"open_items\":[],\"constraints\":[],\"preserved_tool_refs\":[]}\n\
     ```\n\
     Let me know if you need more."
  in
  match parse_ep raw with
  | Some ep ->
    check string "episode_summary" "s" ep.episode_summary;
    check int "claims count" 0 (List.length ep.claims)
  | None -> Alcotest.fail "prose-wrapped JSON should parse"
;;

let test_parses_json_string_wrapping () =
  let raw =
    "\"{\\\"episode_summary\\\":\\\"s\\\",\\\"claims\\\":[],\\\"open_items\\\":[],\\\"constraints\\\":[],\\\"preserved_tool_refs\\\":[]}\""
  in
  match parse_ep raw with
  | Some ep ->
    check string "episode_summary" "s" ep.episode_summary;
    check int "claims count" 0 (List.length ep.claims)
  | None -> Alcotest.fail "JSON-string-wrapped object should parse"
;;

let test_parses_string_source_turn () =
  let raw =
    {|{"episode_summary":"s","claims":[{"claim":"c","category":"fact","source_turn":"3"}],"open_items":[],"constraints":[],"preserved_tool_refs":[]}|}
  in
  match parse_ep raw with
  | Some ep ->
    check int "claims count" 1 (List.length ep.claims);
    (match ep.claims with
     | [ claim ] -> check int "source_turn coerced" 3 claim.source.turn
     | _ -> Alcotest.fail "expected exactly one claim")
  | None -> Alcotest.fail "string source_turn should coerce to int"
;;

let test_missing_lists_default_to_empty () =
  let raw =
    {|{"episode_summary":"s","claims":[{"claim":"c","category":"fact","source_turn":0}]}|}
  in
  match parse_ep raw with
  | Some ep ->
    check int "open_items empty" 0 (List.length ep.open_items);
    check int "constraints empty" 0 (List.length ep.constraints);
    check int "preserved_tool_refs empty" 0 (List.length ep.preserved_tool_refs)
  | None -> Alcotest.fail "missing optional lists should default to empty"
;;

let test_invalid_source_turn_string_rejected () =
  let raw =
    {|{"episode_summary":"s","claims":[{"claim":"c","category":"fact","source_turn":"not-a-number"}],"open_items":[],"constraints":[],"preserved_tool_refs":[]}|}
  in
  check bool "invalid source_turn rejected" true (Option.is_none (parse_ep raw))
;;

let contains_sub sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  let rec aux i =
    if i + sub_len > s_len
    then false
    else if String.equal (String.sub s i sub_len) sub
    then true
    else aux (i + 1)
  in
  aux 0
;;

let test_retry_nudge_matches_schema () =
  (* The old nudge listed "confidence" as a claim field; the parser dropped
     confidence in RFC-0247, so the nudge must no longer ask for it. *)
  check bool "nudge does not list confidence as a field" false
    (contains_sub "claim, confidence" R.parse_retry_nudge);
  check bool "nudge mentions source_turn" true (contains_sub "source_turn" R.parse_retry_nudge);
  check bool "nudge mentions source_tool_call_id" true
    (contains_sub "source_tool_call_id" R.parse_retry_nudge)
;;

let () =
  run "keeper_librarian_retry"
    [
      ( "parse_retry",
        [
          test_case "succeeds on first attempt" `Quick test_succeeds_first_attempt;
          test_case "retries then succeeds" `Quick test_retries_then_succeeds;
          test_case "bounded then fails" `Quick test_bounded_then_fails;
          test_case "transport not retried" `Quick test_transport_not_retried;
          test_case "nudge appended each retry" `Quick test_nudge_appended_each_retry;
        ] );
      ( "cadence",
        [
          test_case "fresh then every cadence" `Quick test_cadence_fresh_then_every_cadence;
          test_case "cadence 1 always due" `Quick test_cadence_one_always_due;
          test_case "step transitions" `Quick test_cadence_step_transitions;
          test_case "record success resets" `Quick test_cadence_record_success_resets;
          test_case "cadence_due fires once per period" `Quick test_cadence_due_periodic;
          test_case "cadence_due is per-keeper" `Quick test_cadence_due_independent_keepers;
          test_case "cadence_due resets on trace rollover" `Quick
            test_cadence_due_resets_on_trace_rollover;
          test_case "cadence table bounded under trace rotation" `Quick
            test_cadence_table_bounded_under_trace_rotation;
          test_case "cadence_step_keyed rollover decision" `Quick test_cadence_step_keyed;
        ] );
      ( "tolerant_parsing",
        [
          test_case "parses markdown-wrapped JSON" `Quick test_parses_markdown_wrapped;
          test_case "parses prose-wrapped JSON" `Quick test_parses_prose_wrapped;
          test_case "parses JSON-string-wrapped object" `Quick test_parses_json_string_wrapping;
          test_case "coerces string source_turn" `Quick test_parses_string_source_turn;
          test_case "missing lists default to empty" `Quick test_missing_lists_default_to_empty;
          test_case "rejects invalid source_turn string" `Quick test_invalid_source_turn_string_rejected;
          test_case "retry nudge matches schema" `Quick test_retry_nudge_matches_schema;
        ] );
    ]
