(** Tests for {!Keeper_turn_driver_try_provider.carried_range_eviction_sequence}
    (RFC keeper-context-window-in-tokens §10.5): the Agent Core lane's
    same-candidate retry after a refusal that says the request outgrew its
    carrier. The policy is driven through an injected [attempt], so the
    walk, the halving fallback and the gate are checked without a provider. *)

module Try_provider = Masc.Keeper_turn_driver_try_provider
module Range = Masc.Keeper_carried_range
module Ledger = Masc.Keeper_model_input_ledger
module Front = Masc.Keeper_carried_front
module Window = Runtime_model_input_tail_window
module Types = Agent_core.Types

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

let unattributed_refusal =
  Agent_core.Error.Api
    (Agent_core.Retry.InvalidRequest
       { message = "refused, reason not modelled"
       ; reason = Agent_core.Retry.Unknown_invalid_request
       })
;;

let unrelated = Agent_core.Error.Api (Agent_core.Retry.Timeout { message = "slow"; phase = None })

(* Atom [i] of the synthetic history opens with the message ["m<i>"]. *)
let opener i = Printf.sprintf "m%d" i

let ends ~first_atom ~atom_count =
  if first_atom < atom_count
  then
    Ledger.Carried_atoms
      { front_digest = opener first_atom; end_digest = opener (atom_count - 1) }
  else Ledger.No_atom_carried
;;

let block ~first ~end_ tokens : Ledger.block =
  { block_first_atom = first; block_end_atom = end_; block_first_digest = opener first; tokens }
;;

let ledger ?(total = Some 1_000) (blocks : Ledger.block list) : Ledger.t =
  let first_atom = match blocks with b :: _ -> b.block_first_atom | [] -> 0 in
  let atom_count = match List.rev blocks with b :: _ -> b.block_end_atom | [] -> 0 in
  { prefix_digest = "f"
  ; total_tokens = total
  ; measured_end_atom = Option.map (fun _ -> atom_count) total
  ; measured_demote_before = Option.map (fun _ -> 0) total
  ; blocks
  ; last =
      { prefix_digest = "f"
      ; first_atom
      ; atom_count
      ; ends = ends ~first_atom ~atom_count
      ; tail_bytes = 0
      ; turn_context = false
      ; demote_before = 0
      }
  ; last_usage = None
  }
;;

let request ~first_atom ~atom_count : Ledger.request =
  { prefix_digest = "f"
  ; first_atom
  ; atom_count
  ; ends = ends ~first_atom ~atom_count
  ; tail_bytes = 0
  ; turn_context = false
  ; demote_before = 0
  }
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
      ~hold_front:(fun _ -> ())
      ~evict:(function
        | Range.Evicted { first_atom; _ } ->
          trace.evictions <- first_atom :: trace.evictions;
          true
        | Range.Unchanged _ -> false)
      ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
        trace.halvings <- (first_atom, retry) :: trace.halvings;
        true)
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

(* A refusal agent core cannot attribute is still a refusal of this request:
   the same bytes draw the same answer, so the range shrinks. 2026-09-18:
   ollama_cloud answered a 9.5 MB request with prose the classifier leaves
   unknown, and the turn ended instead of carrying less. *)
let test_an_unattributed_refusal_shrinks_the_range () =
  let _, trace =
    run ~ledger_of:(fun _ -> Some four_blocks) [ Error unattributed_refusal; Ok "fits" ]
  in
  check (list int) "the unattributed refusal moved the front" [ 10 ] trace.evictions
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
      ~hold_front:(fun _ -> ())
      ~evict:(fun _ -> false)
      ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
        front := first_atom;
        trace.halvings <- (first_atom, retry) :: trace.halvings;
        true)
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
      ~hold_front:(fun _ -> ())
      ~evict:(fun _ -> false)
      ~halve:(fun ~first_atom ~atom_count:_ ~retry:_ ->
        front := first_atom;
        true)
      ~on_retry:(fun ~retry:_ _ -> ())
      ~attempt:(fun () -> incr attempts; Error overflow)
      ()
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  (* 0 → 8 → 12 → 14 → 15: four halvings, five requests, then one atom. *)
  check int "five attempts" 5 !attempts;
  check int "the front ends on the newest atom" 15 !front
;;

(* The halved front is named by the message that opens it in the refused
   request's history. When that history has no atom there to name, nothing
   moves, and asking again would compose the same refused request: the
   refusal stands. *)
let test_a_halving_that_cannot_name_its_front_ends_the_sequence () =
  let attempts = ref 0 in
  let outcome =
    Try_provider.carried_range_eviction_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~ledger:(fun () -> None)
      ~last_request:(fun () -> Some (request ~first_atom:0 ~atom_count:16))
      ~marks:None
      ~hold_front:(fun _ -> ())
      ~evict:(fun _ -> false)
      ~halve:(fun ~first_atom:_ ~atom_count:_ ~retry:_ -> false)
      ~on_retry:(fun ~retry:_ _ -> fail "no retry is recorded for a move that did not happen")
      ~attempt:(fun () -> incr attempts; Error overflow)
      ()
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "one attempt" 1 !attempts
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

(* An eviction that reports no move leaves the front where the refused
   request had it; asking again would send that request again. *)
let test_an_eviction_that_did_not_move_ends_the_sequence () =
  let attempts = ref 0 in
  let outcome =
    Try_provider.carried_range_eviction_sequence
      ~same_run_retry_authorized:(fun () -> !attempts < 5)
      ~ledger:(fun () -> Some four_blocks)
      ~last_request:(fun () -> None)
      ~marks:None
      ~hold_front:(fun _ -> ())
      ~evict:(fun _ -> false)
      ~halve:(fun ~first_atom:_ ~atom_count:_ ~retry:_ -> fail "nothing halves after an eviction step")
      ~on_retry:(fun ~retry:_ _ -> fail "no retry follows a move that did not happen")
      ~attempt:(fun () ->
        incr attempts;
        Error overflow)
      ()
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check int "one attempt" 1 !attempts
;;

(* [halve_front] answers whether the retry carries a strictly later front. *)
let test_a_halving_answers_whether_the_retry_moves () =
  let held = ref None in
  let lookup i = if i >= 0 && i < 16 then Some (opener i) else None in
  let halve ?(digest_at = Some lookup) move =
    held := None;
    Try_provider.For_testing.halve_front
      ~digest_at
      ~move_ledger:(fun ~first_atom:_ ~front_digest:_ -> move)
      ~hold:(fun seed -> held := Some seed)
      ~first_atom:8
      ~retry:1
  in
  check bool "no history to name the front: no retry" false
    (halve ~digest_at:None false);
  check bool "no atom at the front: no retry" false
    (halve ~digest_at:(Some (fun _ -> None)) false);
  check bool "an older ledger cannot prevent the held front moving" true (halve false);
  check bool "the turn holds the front without a ledger move" true (Option.is_some !held);
  check bool "a ledger that moved: retry" true (halve true);
  check bool "no ledger: retry from the held seed" true (halve false);
  match !held with
  | Some (seed : Front.seed) ->
    check int "held at the halved front" 8 seed.first_atom;
    check string "named by the message that opens it" (opener 8) seed.front_digest
  | None -> fail "the halved seed was not held"
;;

let text_message role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

(* Exchanges [from] to [from + n - 1], two atoms each. *)
let exchanges ~from n =
  List.concat_map
    (fun i ->
       [ text_message Types.User (Printf.sprintf "ask %d" i)
       ; text_message Types.Assistant (Printf.sprintf "answer %d" i)
       ])
    (List.init n (fun i -> from + i))
;;

let ends_from (digest_at : int -> string option) ~first_atom ~atom_count =
  match digest_at first_atom, digest_at (atom_count - 1) with
  | Some front_digest, Some end_digest -> Ledger.Carried_atoms { front_digest; end_digest }
  | None, (Some _ | None) | Some _, None -> Ledger.No_atom_carried
;;

(* The loop this replaces: the pair's ledger was measured on a history whose
   first two exchanges a purge later removed. Its front, atom 30, opens with
   another message in the history the attempt composes from, so every
   composition dropped the front and sent the whole history; the refusal was
   answered from the stale ledger, the halving picked a front behind the
   ledger's, nothing moved, and the same whole history went out again.

   The composition and the refusal path below are the turn driver's own
   ([carried_front], [compose_carried_model_input], [halve_front], the pair
   table), with the provider replaced by a refusal. The retry gate would stop
   an endless sequence at [attempt_cap]; the sequence has to end before it,
   every request after a strictly later front than the one before. *)
let test_a_ledger_the_history_does_not_hold_does_not_steer_the_retries () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "alpha" and runtime_id = "r" and session_id = "trace-1" in
  let before_purge = exchanges ~from:0 22 in
  let history = exchanges ~from:2 20 in
  let lookup_before = Window.atom_opening_digest before_purge in
  let digest_at = Window.atom_opening_digest history in
  let (_ : Ledger.observation) =
    Ledger.Table.observe
      ~keeper_name
      ~runtime_id
      ~session_id
      ~digest_at:lookup_before
      ~request:
        { Ledger.prefix_digest = "f"
        ; first_atom = 30
        ; atom_count = 44
        ; ends = ends_from lookup_before ~first_atom:30 ~atom_count:44
        ; tail_bytes = 0
        ; turn_context = false
        ; demote_before = 0
        }
      ~usage:(Some { Ledger.input_tokens = 50_000; cache_read_input_tokens = 0 })
  in
  let attempt_cap = 20 in
  let working = ref (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id) in
  let attempts = ref 0 in
  let halved = ref None in
  let last = ref None in
  let fronts = ref [] in
  let dropped = ref 0 in
  let outcome =
    Try_provider.carried_range_eviction_sequence
      ~same_run_retry_authorized:(fun () -> !attempts < attempt_cap)
      ~ledger:(fun () -> !working)
      ~last_request:(fun () -> Option.map fst !last)
      ~marks:None
      ~hold_front:(fun seed -> halved := Some seed)
      ~evict:(function
        | Range.Evicted { first_atom; front_digest; _ } ->
          Try_provider.For_testing.move_ledger_front working ~first_atom ~front_digest
        | Range.Unchanged _ -> false)
      ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
        Try_provider.For_testing.halve_front
          ~digest_at:(Option.map snd !last)
          ~move_ledger:(Try_provider.For_testing.move_ledger_front working)
          ~hold:(fun seed -> halved := Some seed)
          ~first_atom
          ~retry)
      ~on_retry:(fun ~retry:_ _ -> ())
      ~attempt:(fun () ->
        incr attempts;
        let front, stale =
          Try_provider.For_testing.carried_front
            ~ledger:working
            ~keeper_name
            ~runtime_id
            ~session_id
            ~digest_at
            ~after_refusal:!halved
            ~cold:(fun () -> None)
        in
        if Option.is_some stale then incr dropped;
        let composed =
          Try_provider.For_testing.compose_carried_model_input
            ~measure_message_bytes:(fun _ -> 1)
            ~accepted:None ~front
            ~history_digest_at:digest_at
            ~current_turn_results:Try_provider.Current_turn_verbatim
            ~base_path:""
            ~demote_before:0
            ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
            history
        in
        let first_atom = composed.Try_provider.projection.Window.dropped_atoms in
        let atom_count = composed.Try_provider.history_atom_count in
        fronts := first_atom :: !fronts;
        last
        := Some
             ( { Ledger.prefix_digest = "f"
               ; first_atom
               ; atom_count
               ; ends = ends_from digest_at ~first_atom ~atom_count
               ; tail_bytes = 0
               ; turn_context = false
               ; demote_before = 0
               }
             , digest_at );
        Error overflow)
      ()
  in
  check bool "the refusal stands" true (Result.is_error outcome);
  check bool "the sequence ended before the retry gate" true (!attempts < attempt_cap);
  check int "the stale ledger was dropped once, when it was first seen" 1 !dropped;
  check (list int) "the whole history, then each halving strictly later"
    [ 0; 20; 30; 35; 37; 38; 39 ]
    (List.rev !fronts);
  Ledger.Table.For_testing.reset ()
;;

(* A refusal moves the front on a candidate with counted usage. Its fallback
   must carry that range both with and without a ledger of its own. A second
   refusal must advance the actual request, even if the fallback's ledger
   still contains blocks behind it. *)
let test_a_refused_front_survives_candidate_changes ?(fallback_atoms = 16) ~blocks ~warm_fallback () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "lane-front" and session_id = "trace-front" in
  let history = exchanges ~from:0 8 in
  let digest_at = Window.atom_opening_digest history in
  let observe runtime_id atom_count =
    let (_ : Ledger.observation) =
      Ledger.Table.observe ~keeper_name ~runtime_id ~session_id ~digest_at
        ~request:
          { (request ~first_atom:0 ~atom_count) with
            ends = ends_from digest_at ~first_atom:0 ~atom_count }
        ~usage:(Some { Ledger.input_tokens = atom_count * 100; cache_read_input_tokens = 0 })
    in
    ()
  in
  if blocks then observe "a" 8;
  observe "a" 16;
  if warm_fallback then (
    observe "b" (fallback_atoms / 2);
    observe "b" fallback_atoms);
  let accepted_a = Ledger.Table.lookup ~keeper_name ~runtime_id:"a" ~session_id in
  let held = ref None in
  let run_candidate runtime_id final =
    let working = ref (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id) in
    let fronts = ref [] and last = ref None in
    let outcome =
      Try_provider.carried_range_eviction_sequence
        ~same_run_retry_authorized:(fun () -> true)
        ~ledger:(fun () -> !working)
        ~last_request:(fun () -> !last)
        ~marks:None
        ~hold_front:(fun seed -> held := Some seed)
        ~evict:(function
          | Range.Evicted { first_atom; front_digest; _ } ->
            Try_provider.For_testing.move_ledger_front working ~first_atom ~front_digest
          | Range.Unchanged _ -> false)
        ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
          Try_provider.For_testing.halve_front
            ~digest_at:(Some digest_at)
            ~move_ledger:(Try_provider.For_testing.move_ledger_front working)
            ~hold:(fun seed -> held := Some seed)
            ~first_atom ~retry)
          ~on_retry:(fun ~retry:_ _ -> ())
        ~attempt:(fun () ->
          let front, _ =
            Try_provider.For_testing.carried_front
              ~ledger:working
              ~keeper_name ~runtime_id ~session_id ~digest_at
              ~after_refusal:!held ~cold:(fun () -> None)
          in
          let composed =
            Try_provider.For_testing.compose_carried_model_input
              ~measure_message_bytes:(fun _ -> 1) ~accepted:None ~front
              ~history_digest_at:digest_at ~current_turn_results:Try_provider.Current_turn_verbatim
              ~base_path:"" ~demote_before:0 ~turn_boundary:(Front.Turn_boundary { end_atom = 0 }) history
          in
          let first_atom = composed.Try_provider.projection.Window.dropped_atoms in
          last := Some (request ~first_atom ~atom_count:16);
          let first = !fronts = [] in
          fronts := first_atom :: !fronts;
          if first then Error overflow else final)
        ()
    in
    outcome, List.rev !fronts
  in
  let first_result, first_fronts = run_candidate "a" (Error unrelated) in
  check bool "the first candidate failed after shrinking" true (Result.is_error first_result);
  check (list int) "the first candidate moved its front" [ 0; 8 ] first_fronts;
  check bool "a refused candidate preserves the complete accepted ledger" true
    (accepted_a = Ledger.Table.lookup ~keeper_name ~runtime_id:"a" ~session_id);
  let next_turn_front, _ =
    Try_provider.For_testing.carried_front
      ~ledger:(ref (Ledger.Table.lookup ~keeper_name ~runtime_id:"a" ~session_id))
      ~keeper_name ~runtime_id:"a" ~session_id ~digest_at
      ~after_refusal:None ~cold:(fun () -> None)
  in
  check (option int) "the next turn starts from the last accepted front" (Some 0)
    (Option.map (fun (front : Front.seed) -> front.first_atom) next_turn_front);
  let next_result, next_fronts = run_candidate "b" (Ok "answer") in
  check (result string reject) "the fallback answers" (Ok "answer") next_result;
  check (list int) "the fallback keeps the front and advances on its own refusal"
    [ 8; 12 ] next_fronts;
  held := None;
  let refused, refused_fronts = run_candidate "a" (Error unattributed_refusal) in
  check bool "every narrower request can be refused" true (Result.is_error refused);
  check (list int) "refusals reach the newest atom within their turn"
    [ 0; 8; 12; 14; 15 ] refused_fronts;
  check bool "all refusals still preserve the accepted blocks and total" true
    (accepted_a = Ledger.Table.lookup ~keeper_name ~runtime_id:"a" ~session_id);
  Ledger.Table.For_testing.reset ()
;;

let test_boundary_moves_and_cancellation_preserve_the_observed_ledger () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "boundary-front" and runtime_id = "a" and session_id = "trace-boundary" in
  let history = exchanges ~from:0 8 in
  let digest_at = Window.atom_opening_digest history in
  List.iter
    (fun atom_count ->
      ignore
        (Ledger.Table.observe ~keeper_name ~runtime_id ~session_id ~digest_at
           ~request:
             { (request ~first_atom:0 ~atom_count) with
               ends = ends_from digest_at ~first_atom:0 ~atom_count }
           ~usage:(Some { Ledger.input_tokens = atom_count * 100; cache_read_input_tokens = 0 })))
    [ 8; 16 ];
  let observed = Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id in
  let marks : Runtime_schema.context_marks =
    { high_water_tokens = 1_200; low_water_tokens = 900 }
  in
  let working = ref observed and other_candidate = ref observed in
  Try_provider.For_testing.evict_at_turn_boundary
    ~keeper_name ~runtime_id ~context_marks:(Some marks) working;
  Try_provider.For_testing.evict_at_turn_boundary
    ~keeper_name ~runtime_id:"b" ~context_marks:None other_candidate;
  let first ledger = Option.map (fun (value : Ledger.t) -> value.last.first_atom) !ledger in
  check (option int) "declared marks move this candidate" (Some 8) (first working);
  check (option int) "another candidate's marks remain independent" (Some 0) (first other_candidate);
  let cancelled =
    try
      Eio.Cancel.sub (fun cancellation ->
        let moved =
          Try_provider.For_testing.move_ledger_front working
            ~first_atom:12
            ~front_digest:(match digest_at 12 with Some digest -> digest | None -> fail "fixture atom missing")
        in
        check bool "the candidate can narrow again" true moved;
        Eio.Cancel.cancel cancellation Exit;
        Eio.Fiber.yield ());
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "the candidate's scope was cancelled" true cancelled;
  check bool "no cancellation rollback is needed for the full observed ledger" true
    (observed = Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id);
  let next_candidate = ref (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id) in
  check (option int) "next turn without marks retains the observed front" (Some 0)
    (first next_candidate);
  Try_provider.For_testing.evict_at_turn_boundary
    ~keeper_name ~runtime_id ~context_marks:(Some marks) next_candidate;
  check (option int) "same marks can intentionally narrow again next turn" (Some 8)
    (first next_candidate);
  Ledger.Table.For_testing.reset ()
;;

let test_stale_working_value_preserves_a_newer_table_observation () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "replaced-front" and runtime_id = "a" and session_id = "trace-replaced" in
  let observe digest_at =
    Ledger.Table.observe ~keeper_name ~runtime_id ~session_id ~digest_at
      ~request:
        { (request ~first_atom:0 ~atom_count:16) with
          ends = ends_from digest_at ~first_atom:0 ~atom_count:16 }
      ~usage:None
  in
  let old = observe (Window.atom_opening_digest (exchanges ~from:100 8)) in
  let working = ref (Some old.ledger) in
  let digest_at = Window.atom_opening_digest (exchanges ~from:0 8) in
  let current = observe digest_at in
  let front, dropped =
    Try_provider.For_testing.carried_front ~ledger:working
      ~keeper_name ~runtime_id ~session_id ~digest_at
      ~after_refusal:None ~cold:(fun () -> fail "the current observation is valid")
  in
  check (option int) "the valid observed front is adopted" (Some 0)
    (Option.map (fun (front : Front.seed) -> front.first_atom) front);
  check bool "the stale local value is reported" true (dropped = Some old.ledger);
  check bool "the current observation remains in the table" true
    (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id = Some current.ledger);
  check bool "the working value now follows that observation" true (!working = Some current.ledger);
  Ledger.Table.For_testing.reset ()
;;

(* A turn with no Librarian point opens on its seed (RFC
   keeper-context-window-in-tokens §13.4). When the provider refuses that
   range as too large, the turn boundary becomes the turn's front (§10.4) and
   the same candidate is asked again from it. A later candidate in the same
   turn opens there instead of on the refused range, and is not asked twice
   when it refuses the boundary too. An accepted request is what the ledger
   keeps, so the next turn opens on the boundary. [held] is the turn's slot
   ([hold_carried_front] / [carried_front_after_refusal]); the front choice
   ([carried_front]), the composition and the ledger are the turn driver's
   own; the provider accepts a request that carries at most [limit] atoms. *)
let test_a_refused_seed_moves_the_turns_front_to_the_turn_boundary () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "seed-refused" and session_id = "trace-seed" in
  let continuity = Some Try_provider.without_snapshot in
  let run_candidate ~held ~runtime_id ~limit ~boundary history =
    let digest_at = Window.atom_opening_digest history in
    let atom_count = List.length history in
    let working = ref (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id) in
    let last = ref None and sent = ref [] and resent = ref 0 in
    let outcome =
      Try_provider.turn_boundary_resend_sequence
        ~same_run_retry_authorized:(fun () -> true)
        ~refused_range:(fun () -> !last)
        ~turn_start_front:(fun () ->
          let first_atom = Front.clamp ~atom_count boundary in
          Option.map
            (fun front_digest ->
               { Front.first_atom; front_digest; source = Front.Turn_start_after_seed_refusal })
            (digest_at first_atom))
        ~hold_front:(fun seed -> held := Some seed)
        ~on_turn_start:(fun _ _ -> incr resent)
        ~attempt:(fun () ->
          let front, _ =
            Try_provider.For_testing.carried_front
              ~ledger:working ~keeper_name ~runtime_id ~session_id ~digest_at
              ~after_refusal:!held ~cold:(fun () -> None)
          in
          let composed =
            Try_provider.For_testing.compose_carried_model_input
              ?continuity ~measure_message_bytes:(fun _ -> 1) ~accepted:None ~front
              ~history_digest_at:digest_at ~current_turn_results:Try_provider.Current_turn_verbatim ~base_path:""
              ~demote_before:boundary
              ~turn_boundary:(Front.Turn_boundary { end_atom = boundary })
              history
          in
          let first_atom = composed.Try_provider.projection.Window.dropped_atoms in
          last := Some (composed.Try_provider.origin, first_atom);
          sent := first_atom :: !sent;
          if atom_count - first_atom > limit
          then Error overflow
          else (
            let (_ : Ledger.observation) =
              Ledger.Table.observe ~keeper_name ~runtime_id ~session_id ~digest_at
                ~request:
                  { (request ~first_atom ~atom_count) with
                    ends = ends_from digest_at ~first_atom ~atom_count }
                ~usage:
                  (Some
                     { Ledger.input_tokens = (atom_count - first_atom) * 100
                     ; cache_read_input_tokens = 0 })
            in
            Ok composed.Try_provider.origin))
        ()
    in
    outcome, List.rev !sent, !resent
  in
  let origin_is expected = function
    | Ok origin -> String.equal (Front.origin_to_string origin) expected
    | Error _ -> false
  in
  (* Turn 1, fresh, on [a]: no seed, the boundary at 0 carries all 8 atoms. *)
  let first, first_sent, first_resent =
    run_candidate ~held:(ref None) ~runtime_id:"a" ~limit:10 ~boundary:0 (exchanges ~from:0 4)
  in
  check bool "a fresh turn opens at its boundary" true (origin_is "turn_start" first);
  check (list int) "one request" [ 0 ] first_sent;
  check int "nothing to resend" 0 first_resent;
  (* Turn 2, 14 atoms, boundary 8. [a] opens on its ledger's front 0 and is
     refused; the boundary becomes the turn's front and [a] refuses that too. *)
  let held = ref None in
  let history = exchanges ~from:0 7 in
  let a, a_sent, a_resent = run_candidate ~held ~runtime_id:"a" ~limit:1 ~boundary:8 history in
  check bool "both of a's requests are refused" true (Result.is_error a);
  check (list int) "the seed range, then the turn boundary" [ 0; 8 ] a_sent;
  check int "a resends once" 1 a_resent;
  check (option int) "the turn holds the boundary" (Some 8)
    (Option.map (fun (seed : Front.seed) -> seed.first_atom) !held);
  (* [c] opens on the held boundary; its refusal is not answered again,
     since a resend would not shrink the range. *)
  let c, c_sent, c_resent = run_candidate ~held ~runtime_id:"c" ~limit:1 ~boundary:8 history in
  check bool "c's refusal stands" true (Result.is_error c);
  check (list int) "c opens on the turn's front, once" [ 8 ] c_sent;
  check int "c does not resend" 0 c_resent;
  (* [b] opens on the held boundary, not on the refused range, and answers. *)
  let b, b_sent, b_resent = run_candidate ~held ~runtime_id:"b" ~limit:10 ~boundary:8 history in
  check bool "b answers from the turn's front" true (origin_is "turn_start_after_seed_refusal" b);
  check (list int) "b sends one request from the boundary" [ 8 ] b_sent;
  check int "b does not resend" 0 b_resent;
  (* Turn 3 on [b]: its ledger kept that request, so the seed is 8. *)
  let third, third_sent, _ =
    run_candidate ~held:(ref None) ~runtime_id:"b" ~limit:10 ~boundary:14 (exchanges ~from:0 9)
  in
  check bool "the next turn opens on the ledger" true (origin_is "ledger" third);
  check (list int) "at the boundary the resend used" [ 8 ] third_sent;
  (* On one candidate: [a]'s ledger still opens at 0, so turn 3 on [a] is
     refused, resends from 14 and is accepted; turn 4 opens at 14. *)
  let held = ref None in
  let resend, resend_sent, resend_count =
    run_candidate ~held ~runtime_id:"a" ~limit:10 ~boundary:14 (exchanges ~from:0 9)
  in
  check bool "the resend is accepted" true (origin_is "turn_start_after_seed_refusal" resend);
  check (list int) "the seed range, then the boundary" [ 0; 14 ] resend_sent;
  check int "one resend" 1 resend_count;
  let fourth, fourth_sent, fourth_resent =
    run_candidate ~held:(ref None) ~runtime_id:"a" ~limit:10 ~boundary:18 (exchanges ~from:0 11)
  in
  check bool "the next turn opens on the ledger" true (origin_is "ledger" fourth);
  check (list int) "at the accepted boundary" [ 14 ] fourth_sent;
  check int "no resend" 0 fourth_resent;
  (* A refusal of a range that did not open on a seed is returned at once. *)
  Ledger.Table.For_testing.reset ();
  let fresh, fresh_sent, fresh_resent =
    run_candidate ~held:(ref None) ~runtime_id:"a" ~limit:1 ~boundary:0 (exchanges ~from:0 4)
  in
  check bool "a refused turn start stands" true (Result.is_error fresh);
  check (list int) "one request" [ 0 ] fresh_sent;
  check int "no resend" 0 fresh_resent;
  Ledger.Table.For_testing.reset ()
;;

(* The pair table sits behind an Eio mutex. *)
let () =
  Eio_main.run
  @@ fun _ ->
  Alcotest.run
    "keeper_carried_range_eviction"
    [ ( "sequence"
      , [ test_case "success asks once" `Quick test_success_asks_once
        ; test_case "boundary and cancellation preserve observed ledger" `Quick
            test_boundary_moves_and_cancellation_preserve_the_observed_ledger
        ; test_case "stale candidate preserves current observation" `Quick
            test_stale_working_value_preserves_a_newer_table_observation
        ; test_case "unrelated error" `Quick test_an_unrelated_error_never_retries
        ; test_case "overflow evicts and asks again" `Quick
            test_an_overflow_evicts_the_oldest_block_and_asks_again
        ; test_case "marks walk to the low-water mark" `Quick
            test_with_marks_the_refusal_walks_down_to_the_low_water_mark
        ; test_case "body refusal evicts" `Quick test_a_body_refusal_evicts_like_an_overflow
        ; test_case "an unattributed refusal shrinks the range" `Quick
            test_an_unattributed_refusal_shrinks_the_range
        ; test_case "single block halves" `Quick test_a_single_block_halves_the_last_request
        ; test_case "no ledger halves" `Quick test_without_a_ledger_the_range_halves_until_it_fits
        ; test_case "halving ends at one atom" `Quick
            test_halving_ends_at_one_atom_when_every_request_is_refused
        ; test_case "halving without a nameable front ends" `Quick
            test_a_halving_that_cannot_name_its_front_ends_the_sequence
        ; test_case "single atom ends" `Quick test_a_single_atom_ends_the_sequence_with_the_refusal
        ; test_case "nothing to move ends" `Quick test_no_ledger_and_no_request_ends_the_sequence
        ; test_case "gate" `Quick test_the_gate_blocks_a_retry_after_a_durable_checkpoint
        ; test_case "refusal past the newest block" `Quick
            test_a_refusal_that_survives_the_newest_block_is_returned
        ; test_case "an eviction that did not move ends" `Quick
            test_an_eviction_that_did_not_move_ends_the_sequence
        ; test_case "halving answers whether the retry moves" `Quick
            test_a_halving_answers_whether_the_retry_moves
        ; test_case "a stale ledger does not steer the retries" `Quick
            test_a_ledger_the_history_does_not_hold_does_not_steer_the_retries
        ; test_case "halving survives a cold fallback" `Quick
            (test_a_refused_front_survives_candidate_changes ~blocks:false ~warm_fallback:false)
        ; test_case "halving survives a warm fallback" `Quick
            (test_a_refused_front_survives_candidate_changes ~blocks:false ~warm_fallback:true)
        ; test_case "block eviction survives a cold fallback" `Quick
            (test_a_refused_front_survives_candidate_changes ~blocks:true ~warm_fallback:false)
        ; test_case "block eviction survives a warm fallback" `Quick
            (test_a_refused_front_survives_candidate_changes ~blocks:true ~warm_fallback:true)
        ; test_case "a refused seed moves the turn's front to the turn boundary" `Quick
            test_a_refused_seed_moves_the_turns_front_to_the_turn_boundary
        ; test_case "the actual request can advance beyond the fallback ledger" `Quick
            (test_a_refused_front_survives_candidate_changes
               ~fallback_atoms:8 ~blocks:true ~warm_fallback:true)
        ] )
    ]
;;
