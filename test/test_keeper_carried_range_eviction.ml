(** Tests for {!Keeper_turn_driver_try_provider.carried_range_eviction_sequence}
    (RFC keeper-context-window-in-tokens §10.5): the Agent Core lane's
    same-candidate retry after a refusal that says the request outgrew its
    carrier. The policy is driven through an injected [attempt], so the
    walk, the halving fallback and the gate are checked without a provider. *)

module Try_provider = Masc.Keeper_turn_driver_try_provider
module Range = Masc.Keeper_carried_range
module Ledger = Masc.Keeper_model_input_ledger

open Alcotest

let overflow =
  Agent_core.Error.Api (Agent_core.Retry.ContextOverflow { message = "too long"; limit = None })
;;

let body_refused_by_provider =
  Agent_core.Error.Api
    (Agent_core.Retry.InvalidRequest
       { message = "too large"
       ; reason = Agent_core.Retry.Request_body_refused_by_provider { status = 413 }
       })
;;

let unrelated = Agent_core.Error.Api (Agent_core.Retry.Timeout { message = "slow"; phase = None })

let block ~first ~end_ tokens : Ledger.block =
  { block_first_atom = first; block_end_atom = end_; tokens }
;;

let ledger ?(total = Some 1_000) (blocks : Ledger.block list) : Ledger.t =
  let first_atom = match blocks with b :: _ -> b.block_first_atom | [] -> 0 in
  let atom_count = match List.rev blocks with b :: _ -> b.block_end_atom | [] -> 0 in
  { prefix_digest = "f"
  ; total_tokens = total
  ; measured_end_atom = Option.map (fun _ -> atom_count) total
  ; measured_demote_before = Option.map (fun _ -> 0) total
  ; blocks
  ; last = { prefix_digest = "f"; first_atom; atom_count; tail_bytes = 0; turn_context = false; demote_before = 0 }
  ; last_usage = None
  }
;;

let request ~first_atom ~atom_count : Ledger.request =
  { prefix_digest = "f"; first_atom; atom_count; tail_bytes = 0; turn_context = false; demote_before = 0 }
;;

type trace =
  { mutable attempts : int
  ; mutable evictions : int list  (** the fronts [evict] moved to *)
  ; mutable halvings : (int * int) list  (** (first_atom, retry) *)
  ; mutable retries : int
  }

(* [outcomes] is what the provider answers, attempt by attempt; the last one
   repeats. The ledger the policy reads is [ledger_of], indexed by attempt, so
   a test can hand back a moved ledger after an eviction. *)
let run
      ?(gate = fun () -> true)
      ?marks
      ?(last_request = fun () -> None)
      ?(last_resort = fun ~retry:_ -> false)
      ~ledger_of
      outcomes
  =
  let trace = { attempts = 0; evictions = []; halvings = []; retries = 0 } in
  let outcome =
    Try_provider.carried_range_eviction_sequence
      ~same_run_retry_authorized:gate
      ~ledger:(fun () -> ledger_of trace.attempts)
      ~last_request
      ~marks
      ~evict:(function
        | Range.Evicted { first_atom; _ } -> trace.evictions <- first_atom :: trace.evictions
        | Range.Unchanged _ -> ())
      ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
        trace.halvings <- (first_atom, retry) :: trace.halvings)
      ~last_resort
      ~on_retry:(fun ~retry _ -> trace.retries <- retry)
      ~attempt:(fun () ->
        let index = min trace.attempts (List.length outcomes - 1) in
        trace.attempts <- trace.attempts + 1;
        List.nth outcomes index)
      ()
  in
  outcome, trace
;;

let four_blocks =
  ledger
    [ block ~first:0 ~end_:10 (Some 300)
    ; block ~first:10 ~end_:20 (Some 250)
    ; block ~first:20 ~end_:30 (Some 200)
    ; block ~first:30 ~end_:40 (Some 150)
    ]
;;

let test_success_asks_once () =
  let outcome, trace = run ~ledger_of:(fun _ -> Some four_blocks) [ Ok "answer" ] in
  check (result string reject) "the answer" (Ok "answer") outcome;
  check int "one attempt" 1 trace.attempts
;;

let test_an_unrelated_error_never_retries () =
  let outcome, trace = run ~ledger_of:(fun _ -> Some four_blocks) [ Error unrelated; Ok "late" ] in
  check bool "the error stands" true (Result.is_error outcome);
  check int "one attempt" 1 trace.attempts
;;

let test_an_overflow_evicts_the_oldest_block_and_asks_again () =
  let moved = ledger [ block ~first:10 ~end_:20 (Some 250); block ~first:20 ~end_:30 (Some 200); block ~first:30 ~end_:40 (Some 150) ] in
  let outcome, trace =
    run
      (* A refusal counts no usage, so the ledger it reads is still the one
         the refused request was composed from. [moved] is what a later
         refusal would see, after [evict] applied the walk. *)
      ~ledger_of:(fun attempts -> if attempts <= 1 then Some four_blocks else Some moved)
      [ Error overflow; Ok "fits" ]
  in
  check (result string reject) "the retry answered" (Ok "fits") outcome;
  check (list int) "the front moved past the oldest block" [ 10 ] trace.evictions;
  check int "one retry" 1 trace.retries;
  check (list (pair int int)) "nothing halved" [] trace.halvings
;;

let test_with_marks_the_refusal_walks_down_to_the_low_water_mark () =
  let marks : Runtime_schema.context_marks = { high_water_tokens = 1_500; low_water_tokens = 400 } in
  let outcome, trace =
    run ~marks ~ledger_of:(fun _ -> Some four_blocks) [ Error overflow; Ok "fits" ]
  in
  check bool "answered" true (Result.is_ok outcome);
  (* 1,000 - 300 - 250 = 450, still above 400; the third block brings it to 250. *)
  check (list int) "three blocks left" [ 30 ] trace.evictions
;;

let test_a_body_refusal_evicts_like_an_overflow () =
  let _, trace = run ~ledger_of:(fun _ -> Some four_blocks) [ Error body_refused_by_provider; Ok "fits" ] in
  check (list int) "the wire's refusal moved the front" [ 10 ] trace.evictions
;;

let test_a_single_block_halves_the_last_request () =
  let one = ledger [ block ~first:0 ~end_:40 None ] in
  let _, trace =
    run
      ~ledger_of:(fun _ -> Some one)
      ~last_request:(fun () -> Some (request ~first_atom:0 ~atom_count:40))
      [ Error overflow; Ok "fits" ]
  in
  check (list int) "no block left" [] trace.evictions;
  check (list (pair int int)) "halfway to the newest atom, retry 1" [ 20, 1 ] trace.halvings
;;

(* The caller composes the next request from the halved front, so the
   request the policy reads back moves with each halving: 0 → 8 → 12 of 16. *)
let test_without_a_ledger_the_range_halves_until_it_fits () =
  let front = ref 0 in
  let trace = { attempts = 0; evictions = []; halvings = []; retries = 0 } in
  let outcomes = [ Error overflow; Error overflow; Ok "fits" ] in
  let outcome =
    Try_provider.carried_range_eviction_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~ledger:(fun () -> None)
      ~last_request:(fun () -> Some (request ~first_atom:!front ~atom_count:16))
      ~marks:None
      ~evict:(fun _ -> ())
      ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
        front := first_atom;
        trace.halvings <- (first_atom, retry) :: trace.halvings)
      ~last_resort:(fun ~retry:_ -> false)
      ~on_retry:(fun ~retry _ -> trace.retries <- retry)
      ~attempt:(fun () ->
        let index = min trace.attempts (List.length outcomes - 1) in
        trace.attempts <- trace.attempts + 1;
        List.nth outcomes index)
      ()
  in
  check (result string reject) "the third request fits" (Ok "fits") outcome;
  check int "three attempts" 3 trace.attempts;
  check (list (pair int int)) "halfway, then halfway again, newest first" [ 12, 2; 8, 1 ] trace.halvings
;;

let test_halving_ends_at_one_atom_when_every_request_is_refused () =
  let front = ref 0 in
  let attempts = ref 0 in
  let outcome =
    Try_provider.carried_range_eviction_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~ledger:(fun () -> None)
      ~last_request:(fun () -> Some (request ~first_atom:!front ~atom_count:16))
      ~marks:None
      ~evict:(fun _ -> ())
      ~halve:(fun ~first_atom ~atom_count:_ ~retry:_ -> front := first_atom)
      ~last_resort:(fun ~retry:_ -> false)
      ~on_retry:(fun ~retry:_ _ -> ())
      ~attempt:(fun () -> incr attempts; Error overflow)
      ()
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  (* 0 → 8 → 12 → 14 → 15: four halvings, five requests, then one atom. *)
  check int "five attempts" 5 !attempts;
  check int "the front ends on the newest atom" 15 !front
;;

let test_a_single_atom_ends_the_sequence_with_the_refusal () =
  let outcome, trace =
    run
      ~ledger_of:(fun _ -> None)
      ~last_request:(fun () -> Some (request ~first_atom:15 ~atom_count:16))
      [ Error overflow; Ok "never" ]
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "one attempt" 1 trace.attempts;
  check (list (pair int int)) "nothing to halve" [] trace.halvings
;;

let test_no_ledger_and_no_request_ends_the_sequence () =
  let outcome, trace = run ~ledger_of:(fun _ -> None) [ Error overflow; Ok "never" ] in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "one attempt" 1 trace.attempts
;;

let test_the_gate_blocks_a_retry_after_a_durable_checkpoint () =
  let outcome, trace =
    run ~gate:(fun () -> false) ~ledger_of:(fun _ -> Some four_blocks) [ Error overflow; Ok "never" ]
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "one attempt" 1 trace.attempts;
  check (list int) "nothing evicted" [] trace.evictions
;;

let test_a_refusal_that_survives_the_newest_block_is_returned () =
  (* Two blocks: the first refusal evicts the older; the second finds one
     block and, with no last request to halve, returns. *)
  let two = ledger [ block ~first:0 ~end_:10 (Some 300); block ~first:10 ~end_:20 (Some 250) ] in
  let one = ledger [ block ~first:10 ~end_:20 (Some 250) ] in
  let outcome, trace =
    run
      (* The first refusal reads [two] — a refusal moves nothing by itself —
         and only after [evict] applied the walk does the second refusal see
         [one]. *)
      ~ledger_of:(fun attempts -> if attempts <= 1 then Some two else Some one)
      [ Error overflow; Error overflow; Ok "never" ]
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "two attempts" 2 trace.attempts;
  check (list int) "one eviction" [ 10 ] trace.evictions
;;

(* The newest atom alone was refused: the last resort arms one more request
   and the sequence asks again. *)
let test_a_refused_single_atom_arms_the_last_resort_once () =
  let armed = ref 0 in
  let outcome, trace =
    run
      ~ledger_of:(fun _ -> None)
      ~last_request:(fun () -> Some (request ~first_atom:15 ~atom_count:16))
      ~last_resort:(fun ~retry:_ -> incr armed; !armed = 1)
      [ Error overflow; Ok "demoted and accepted" ]
  in
  check (result string reject) "the demoted request answered" (Ok "demoted and accepted") outcome;
  check int "two attempts" 2 trace.attempts;
  check int "armed once" 1 !armed
;;

let test_the_last_resort_is_used_once_then_the_refusal_stands () =
  let asked = ref 0 in
  let outcome, trace =
    run
      ~ledger_of:(fun _ -> None)
      ~last_request:(fun () -> Some (request ~first_atom:15 ~atom_count:16))
      ~last_resort:(fun ~retry:_ -> incr asked; !asked = 1)
      [ Error overflow; Error overflow; Ok "never" ]
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "two attempts" 2 trace.attempts;
  check int "asked twice, armed once" 2 !asked
;;

let test_nothing_to_demote_ends_the_sequence () =
  let outcome, trace =
    run
      ~ledger_of:(fun _ -> None)
      ~last_request:(fun () -> Some (request ~first_atom:15 ~atom_count:16))
      ~last_resort:(fun ~retry:_ -> false)
      [ Error overflow; Ok "never" ]
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "one attempt" 1 trace.attempts
;;

let () =
  Alcotest.run
    "keeper_carried_range_eviction"
    [ ( "sequence"
      , [ test_case "success asks once" `Quick test_success_asks_once
        ; test_case "unrelated error" `Quick test_an_unrelated_error_never_retries
        ; test_case "overflow evicts and asks again" `Quick
            test_an_overflow_evicts_the_oldest_block_and_asks_again
        ; test_case "marks walk to the low-water mark" `Quick
            test_with_marks_the_refusal_walks_down_to_the_low_water_mark
        ; test_case "body refusal evicts" `Quick test_a_body_refusal_evicts_like_an_overflow
        ; test_case "single block halves" `Quick test_a_single_block_halves_the_last_request
        ; test_case "no ledger halves" `Quick test_without_a_ledger_the_range_halves_until_it_fits
        ; test_case "halving ends at one atom" `Quick
            test_halving_ends_at_one_atom_when_every_request_is_refused
        ; test_case "single atom ends" `Quick test_a_single_atom_ends_the_sequence_with_the_refusal
        ; test_case "single atom arms the last resort" `Quick
            test_a_refused_single_atom_arms_the_last_resort_once
        ; test_case "last resort once" `Quick test_the_last_resort_is_used_once_then_the_refusal_stands
        ; test_case "nothing to demote" `Quick test_nothing_to_demote_ends_the_sequence
        ; test_case "nothing to move ends" `Quick test_no_ledger_and_no_request_ends_the_sequence
        ; test_case "gate" `Quick test_the_gate_blocks_a_retry_after_a_durable_checkpoint
        ; test_case "refusal past the newest block" `Quick
            test_a_refusal_that_survives_the_newest_block_is_returned
        ] )
    ]
;;
