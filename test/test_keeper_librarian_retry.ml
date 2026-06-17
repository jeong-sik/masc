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
   | Error e -> Alcotest.failf "expected Ok, got Error %s" e);
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
   | Error e -> Alcotest.failf "expected Ok after retry, got %s" e);
  check int "one retry to recover" 2 !calls

let test_bounded_then_fails () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Unparseable "still bad"
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> Alcotest.fail "expected Error after exhausting retries"
   | Error e -> check string "last error surfaced" "still bad" e);
  check int "initial attempt + max_retries" 3 !calls

let test_transport_not_retried () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Transport_failed "timeout"
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> Alcotest.fail "expected Error"
   | Error e -> check string "transport error surfaced" "timeout" e);
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

(* Drive [cadence_step] sequentially from a fresh keeper (counter 0) for [turns]
   turns, collecting the [due] decision each turn. *)
let run_cadence ~cadence ~turns =
  let counter = ref 0 in
  List.init turns (fun _ ->
    let next, due = R.cadence_step ~cadence ~counter:!counter in
    counter := next;
    due)

let test_cadence_three_fires_every_third () =
  (* cadence 3: two skipped turns, then a due turn, repeating. *)
  check (list bool) "every third turn is due"
    [ false; false; true; false; false; true ]
    (run_cadence ~cadence:3 ~turns:6)

let test_cadence_one_always_due () =
  (* cadence 1 (and the floored <=1 case) restores per-turn extraction. *)
  check (list bool) "cadence 1 is due every turn"
    [ true; true; true; true ]
    (run_cadence ~cadence:1 ~turns:4);
  check (pair int bool) "cadence<=1 pins counter at 0"
    (0, true)
    (R.cadence_step ~cadence:1 ~counter:5)

let test_cadence_resets_after_due () =
  (* A due turn returns counter 0 so the next cycle starts fresh. *)
  check (pair int bool) "last turn of cycle is due and resets"
    (0, true)
    (R.cadence_step ~cadence:3 ~counter:2);
  check (pair int bool) "mid-cycle advances without firing"
    (2, false)
    (R.cadence_step ~cadence:3 ~counter:1)

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
          test_case "fires every third turn" `Quick test_cadence_three_fires_every_third;
          test_case "cadence 1 always due" `Quick test_cadence_one_always_due;
          test_case "resets after due" `Quick test_cadence_resets_after_due;
        ] );
    ]
