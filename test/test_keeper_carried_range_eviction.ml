(** Keeper-history carried-range recovery: accepted ledger fronts,
    one boundary resend after a size refusal, and memory receipt fences.
    The tests inject provider outcomes while using the live composition and
    recovery policies; they do not execute a provider transport. *)

module Try_provider = Masc.Keeper_turn_driver_try_provider
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

let text_message role text : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
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

let request ~digest_at ~first_atom ~atom_count : Ledger.request =
  { prefix_digest = "f"
  ; first_atom
  ; atom_count
  ; ends = ends_from digest_at ~first_atom ~atom_count
  ; tail_bytes = 0
  ; turn_context = false
  ; demote_before = 0
  }
;;

let test_stale_working_value_preserves_a_newer_table_observation () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "replaced-front" and runtime_id = "a" and session_id = "trace-replaced" in
  let observe digest_at =
    Ledger.Table.observe ~keeper_name ~runtime_id ~session_id ~digest_at
      ~request:
        (request ~digest_at ~first_atom:0 ~atom_count:16)
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
               { Front.first_atom; front = Model_input_front.At_atom front_digest; source = Front.Turn_start_after_seed_refusal })
            (digest_at first_atom))
        ~held_front:(fun () -> !held)
        ~restore_front:(fun prior -> held := prior)
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
                  (request ~digest_at ~first_atom ~atom_count)
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

(* RFC librarian-lifecycle §4.10: a Librarian point that stands behind lets
   the request grow every turn until the provider refuses it. The driver's
   own pieces run here: [turn_boundary_resend_sequence] answers the refusal,
   and [compose_carried_model_input] composes every request with the turn's
   held front or, without one, the accepted start the turn record keeps.
   [trace_id] and the Librarian's read position name atom [point] of the
   history; the provider accepts at most [limit] atoms. *)
let librarian_trace = "librarian-behind"

let absorbed_at ~point history =
  let digest_at = Window.atom_opening_digest history in
  let progress : Masc.Keeper_librarian_progress.t =
    { position =
        { trace_id = librarian_trace
        ; end_atom = point
        ; last_atom_digest = Option.get (digest_at (point - 1))
        }
    ; boundary_lines_seen = 1
    }
  in
  match Try_provider.absorbed_history ~trace_id:librarian_trace ~messages:history progress with
  | Some (_, continuity) -> continuity
  | None -> fail "the read position does not name an atom of this history"
;;

let librarian_turn ?(refusal = overflow) ?(refuses = fun ~atoms:_ -> false)
      ?(held = ref None) ~point ~accepted ~limit ~boundary history =
  let continuity = absorbed_at ~point history in
  let digest_at = Window.atom_opening_digest history in
  let atom_count = List.length history in
  let last = ref None and sent = ref [] in
  let outcome =
    Try_provider.turn_boundary_resend_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~refused_range:(fun () -> !last)
      ~turn_start_front:(fun () ->
        let first_atom = Front.clamp ~atom_count boundary in
        Option.map
          (fun front_digest ->
             { Front.first_atom; front = Model_input_front.At_atom front_digest; source = Front.Turn_start_after_librarian_refusal })
          (digest_at first_atom))
      ~held_front:(fun () -> !held)
      ~restore_front:(fun prior -> held := prior)
      ~hold_front:(fun seed -> held := Some seed)
      ~on_turn_start:(fun _ _ -> ())
      ~attempt:(fun () ->
        let composed =
          Try_provider.For_testing.compose_carried_model_input
            ~continuity ~measure_message_bytes:(fun _ -> 1) ~front:None
            ~accepted:(match !held with Some _ as held -> held | None -> accepted)
            ~history_digest_at:digest_at ~current_turn_results:Try_provider.Current_turn_verbatim
            ~base_path:"" ~demote_before:boundary
            ~turn_boundary:(Front.Turn_boundary { end_atom = boundary })
            history
        in
        let first_atom = composed.Try_provider.projection.Window.dropped_atoms in
        last := Some (composed.Try_provider.origin, first_atom);
        sent := first_atom :: !sent;
        let atoms = atom_count - first_atom in
        if atoms > limit || refuses ~atoms then Error refusal else Ok first_atom)
      ()
  in
  (* What the turn record keeps of an accepted request: its first atom, named
     by the message that opens it ([Keeper_carried_front.of_records]). *)
  let recorded =
    Result.to_option outcome
    |> Option.map (fun first_atom ->
      { Front.first_atom
      ; front = Model_input_front.At_atom (Option.get (digest_at first_atom))
      ; source = Front.Turn_record { turn = 1 }
      })
  in
  outcome, List.rev !sent, recorded, !last
;;

let opened_past_the_point = function
  | Some (Front.Past_librarian_point { librarian_end_atom; _ }, _) -> Some librarian_end_atom
  | Some
      ( ( Front.Carried _ | Front.Librarian_snapshot _ | Front.Librarian_progress _
        | Front.Turn_start _ | Front.Turn_start_unknown _ )
      , _ )
  | None -> None
;;

(* Tick 1: the Librarian stands at atom 2 of 14 and the provider takes 8
   atoms. The request from the point is refused, the turn boundary 8 is
   held, and the resend from it is accepted. Tick 2: the history is 16
   atoms and the Librarian has not moved. The turn opens at the accepted
   start 8, not at the point, and the provider takes it on the first
   request instead of refusing the grown range again. *)
let test_a_librarian_behind_turn_resends_from_the_boundary () =
  let first, first_sent, recorded, first_last =
    librarian_turn ~point:2 ~accepted:None ~limit:8 ~boundary:8 (exchanges ~from:0 7)
  in
  check (result int reject) "the boundary resend is accepted" (Ok 8) first;
  check (list int) "the point, then the turn boundary" [ 2; 8 ] first_sent;
  check (option int) "the resend opened past the Librarian point" (Some 2)
    (opened_past_the_point first_last);
  let second, second_sent, _, second_last =
    librarian_turn ~point:2 ~accepted:recorded ~limit:8 ~boundary:14 (exchanges ~from:0 8)
  in
  check (result int reject) "the next turn is accepted at once" (Ok 8) second;
  check (list int) "one request, from the accepted start" [ 8 ] second_sent;
  check (option int) "the gap still opens at the point" (Some 2)
    (opened_past_the_point second_last)
;;

(* A provider 400 can carry [Unknown_invalid_request] without a typed
   size code (RFC librarian-lifecycle §4.10 lists the measured wires).
   [boundary_resend_on] permits one resend from the known turn boundary for
   that refusal. Memory reprojection and current-turn tool-result demotion
   require [is_size_refusal], so neither infers a size failure from this
   unclassified response (#38286). *)
let test_an_unattributed_size_refusal_resends_from_the_boundary () =
  let outcome, sent, recorded, _ =
    librarian_turn ~refusal:unattributed_refusal ~point:2 ~accepted:None ~limit:8 ~boundary:8
      (exchanges ~from:0 7)
  in
  check (result int reject) "the boundary resend is accepted" (Ok 8) outcome;
  check (list int) "the point, then the turn boundary" [ 2; 8 ] sent;
  check (option int) "the accepted start is recorded" (Some 8)
    (Option.map (fun (seed : Front.seed) -> seed.first_atom) recorded)
;;

(* A 400 that was not about size draws the same refusal from the boundary:
   one more request, no accepted start, and the turn ends on that refusal. *)
let test_a_refusal_not_about_size_ends_the_turn_after_one_resend () =
  let held = ref None in
  let outcome, sent, recorded, _ =
    librarian_turn ~held ~refusal:unattributed_refusal ~refuses:(fun ~atoms:_ -> true)
      ~point:2 ~accepted:None ~limit:100 ~boundary:8 (exchanges ~from:0 7)
  in
  check bool "the refusal is the turn's error" true (outcome = Error unattributed_refusal);
  check (list int) "one resend from the boundary, and nothing after" [ 2; 8 ] sent;
  check bool "no accepted start is recorded" true (Option.is_none recorded);
  (* The front belongs to the turn: the declared-lane walk asks the next
     candidate with it. The boundary did not answer a refusal that named no
     size, so the next candidate must open on the range the turn started
     with, not at the boundary a success would then record for every later
     turn. *)
  check bool "the boundary front is given back" true (Option.is_none !held);
  let next_outcome, next_sent, next_recorded, _ =
    librarian_turn ~held ~point:2 ~accepted:None ~limit:100 ~boundary:8
      (exchanges ~from:0 7)
  in
  check bool "the next candidate is accepted" true (Result.is_ok next_outcome);
  check (list int) "and opens at the Librarian point, not the boundary" [ 2 ] next_sent;
  check (option int) "so the accepted start stays at the point" (Some 2)
    (Option.map (fun (seed : Front.seed) -> seed.first_atom) next_recorded)
;;

(* A typed size refusal of the boundary request keeps the front: the
   boundary is smaller than the refused range, and giving it back would send
   the larger range again. *)
let test_a_size_refused_boundary_keeps_the_front () =
  let held = ref None in
  let outcome, _, _, _ =
    librarian_turn ~held ~point:2 ~accepted:None ~limit:3 ~boundary:8 (exchanges ~from:0 7)
  in
  check bool "the size refusal is the turn's error" true (outcome = Error overflow);
  check (option int) "the boundary front stays held" (Some 8)
    (Option.map (fun (seed : Front.seed) -> seed.first_atom) !held)
;;

(* Rules 6 and 7: the resend carries this turn's input and never less. When
   the pinned part and this turn alone outgrow the provider, the resend is
   refused too and that refusal ends the sequence; no third request narrows
   into the turn. *)
let test_a_refused_boundary_resend_ends_the_turn () =
  let outcome, sent, recorded, _ =
    librarian_turn ~point:2 ~accepted:None ~limit:3 ~boundary:8 (exchanges ~from:0 7)
  in
  check bool "the refusal is the turn's error" true (outcome = Error overflow);
  check (list int) "the point, then the turn boundary, and nothing after" [ 2; 8 ] sent;
  check bool "no accepted start is recorded" true (Option.is_none recorded)
;;

(* The pair table sits behind an Eio mutex. *)
let test_memory_feedback_precedes_history_recovery () =
  List.iter (fun error ->
    let calls = ref 0 and reductions = ref 0 in
    let attempt () = incr calls; if !calls=1 then Error error else Ok "reduced evidence" in
    let result = Try_provider.memory_capacity_retry_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~on_memory_capacity_refusal:(fun ~refusal ->
        check bool "the exact typed refusal reaches the memory producer" true (refusal=error);
        incr reductions; Ok Masc.Keeper_memory_delivery_reprojection.Reprojected)
      ~on_projection_failure:(fun () -> fail "successful receipt reported failure")
      ~attempt () in
    check bool "smaller memory completes without range eviction" true (result=Ok "reduced evidence");
    check int "only refused and reduced requests are attempted" 2 !calls;
    check int "one provider-refused memory projection" 1 !reductions)
    [overflow;body_refused_by_provider];
  List.iter (fun (authorized,error) ->
    let calls = ref 0 in
    let result = Try_provider.memory_capacity_retry_sequence
      ~same_run_retry_authorized:(fun () -> authorized)
      ~on_memory_capacity_refusal:(fun ~refusal:_ -> fail "unauthorized memory retry")
      ~on_projection_failure:(fun () -> fail "no projection was attempted")
      ~attempt:(fun () -> incr calls; Error error) () in
    check bool "original refusal preserved" true (result=Error error);
    check int "no retry after effects or an unclassified failure" 1 !calls)
    [false,overflow;false,body_refused_by_provider;true,unattributed_refusal]
;;

let test_memory_receipt_failure_fences_enclosing_recovery () =
  List.iter (fun error ->
    let projection_failed = ref false and attempts = ref 0 and notifications = ref 0 in
    let authorized () = not !projection_failed in
    let attempt () : (string, Agent_core.Error.t) result =
      Try_provider.memory_capacity_retry_sequence
        ~same_run_retry_authorized:authorized
        ~on_memory_capacity_refusal:(fun ~refusal ->
          incr notifications;
          check bool "the exact size refusal reaches the memory producer" true (refusal = error);
          Error "receipt unavailable")
        ~on_projection_failure:(fun () -> projection_failed := true)
        ~attempt:(fun () -> incr attempts; Error error) () in
    let boundary_resend () = Try_provider.turn_boundary_resend_sequence
      ~same_run_retry_authorized:authorized
      ~refused_range:(fun () -> Some (Front.Librarian_progress { end_atom = 2 }, 2))
      ~turn_start_front:(fun () -> fail "receipt failure reached boundary selection")
      ~held_front:(fun () -> fail "receipt failure read a retry front")
      ~restore_front:(fun _ -> fail "receipt failure restored a retry front")
      ~hold_front:(fun _ -> fail "receipt failure mutated a retry front")
      ~on_turn_start:(fun _ _ -> fail "receipt failure announced a boundary resend")
      ~attempt () in
    let result = Try_provider.current_turn_demotion_sequence
      ~same_run_retry_authorized:authorized
      ~demotable:(fun () -> fail "receipt failure reached current-turn demotion")
      ~demote:(fun _ ~refused_atom_count:_ -> fail "receipt failure demoted current tool results")
      ~first:boundary_resend
      ~resend:(fun () -> fail "receipt failure retried the provider") () in
    (match result with
     | Error retained -> check bool "receipt failure preserves the exact original provider error" true (retained == error)
     | Ok _ -> fail "receipt failure became a successful recovery");
    check int "only the original provider attempt runs" 1 !attempts;
    check int "one refused memory reprojection" 1 !notifications;
    check bool "both enclosing recovery layers lose retry admission" false (authorized ()))
    [overflow; body_refused_by_provider]
;;

let () =
  Eio_main.run
  @@ fun _ ->
  Alcotest.run
    "keeper_carried_range_recovery"
    [ ( "live recovery"
      , [ test_case "stale candidate preserves current observation" `Quick
            test_stale_working_value_preserves_a_newer_table_observation
        ; test_case "memory feedback preserves effect and refusal authority" `Quick
            test_memory_feedback_precedes_history_recovery
        ; test_case "memory receipt failure fences boundary resend and current-turn demotion" `Quick
            test_memory_receipt_failure_fences_enclosing_recovery
        ; test_case "a refused seed moves the turn's front to the turn boundary" `Quick
            test_a_refused_seed_moves_the_turns_front_to_the_turn_boundary
        ; test_case "a Librarian-behind turn resends from the turn boundary" `Quick
            test_a_librarian_behind_turn_resends_from_the_boundary
        ; test_case "a refused boundary resend ends the turn" `Quick
            test_a_refused_boundary_resend_ends_the_turn
        ; test_case "an unattributed size refusal resends from the boundary" `Quick
            test_an_unattributed_size_refusal_resends_from_the_boundary
        ; test_case "a refusal not about size ends the turn after one resend" `Quick
            test_a_refusal_not_about_size_ends_the_turn_after_one_resend
        ; test_case "a size-refused boundary keeps the front" `Quick
            test_a_size_refused_boundary_keeps_the_front
        ] )
    ]
;;
