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
  ; working_state = None
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
  let continuity = Some Try_provider.No_read_end in
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
               { Front.first_atom; front = Model_input_front.At_atom front_digest; source = Front.Turn_start_after_refusal })
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
              ?continuity ~measure_message_bytes:(fun _ -> 1) ~measure_wire_bytes:(fun _ -> None)
              ~accepted:None ~front
              ~history_digest_at:digest_at ~current_turn_results:Try_provider.Current_turn_verbatim ~base_path:""
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
  check bool "b answers from the turn's front" true (origin_is "turn_start_after_refusal" b);
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
  check bool "the resend is accepted" true (origin_is "turn_start_after_refusal" resend);
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
   The writer's read end is atom [point] of the history; the provider
   accepts at most [limit] atoms. *)

let absorbed_at ~point =
  Try_provider.Covered { Try_provider.end_atom = point; working_state = None }
;;

let librarian_turn ?(refusal = overflow) ?(refuses = fun ~atoms:_ -> false)
      ?(held = ref None) ~point ~accepted ~limit ~boundary history =
  let continuity = absorbed_at ~point in
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
             { Front.first_atom; front = Model_input_front.At_atom front_digest; source = Front.Turn_start_after_refusal })
          (digest_at first_atom))
      ~held_front:(fun () -> !held)
      ~restore_front:(fun prior -> held := prior)
      ~hold_front:(fun seed -> held := Some seed)
      ~on_turn_start:(fun _ _ -> ())
      ~attempt:(fun () ->
        let composed =
          Try_provider.For_testing.compose_carried_model_input
            ~continuity ~measure_message_bytes:(fun _ -> 1) ~measure_wire_bytes:(fun _ -> None)
            ~front:None
            ~accepted:(match !held with Some _ as held -> held | None -> accepted)
            ~history_digest_at:digest_at ~current_turn_results:Try_provider.Current_turn_verbatim
            ~base_path:""
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

(* The origin the last request of a turn reported, in its log word. *)
let reported_origin = function
  | Some (origin, (_ : int)) -> Some (Front.origin_to_string origin)
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
  check (option string) "the resend reports the front the refusal held"
    (Some "turn_start_after_refusal") (reported_origin first_last);
  let second, second_sent, _, second_last =
    librarian_turn ~point:2 ~accepted:recorded ~limit:8 ~boundary:14 (exchanges ~from:0 8)
  in
  check (result int reject) "the next turn is accepted at once" (Ok 8) second;
  check (list int) "one request, from the accepted start" [ 8 ] second_sent;
  check (option string) "the next turn reports the turn record of the accepted start"
    (Some "turn_record#1") (reported_origin second_last)
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

let accepted_at ?(source = Front.Turn_record { turn = 1 }) history first_atom : Front.seed =
  { first_atom
  ; front = Model_input_front.At_atom (Option.get (Window.atom_opening_digest history first_atom))
  ; source
  }
;;

let past_point_start = function
  | Try_provider.Past_librarian_point { accepted; _ } -> Some accepted.Front.first_atom
  | Try_provider.From_covered _
  | Try_provider.From_seed _ | Try_provider.From_turn_boundary _ -> None
;;

(* Rule 7: an accepted start opens at most at the turn boundary, so the
   atoms since the last completed turn ride. A turn saved atoms 8 to 13 and
   failed, so it wrote no end line: the turn boundary is 8 and this turn
   began at 14. The Librarian stands at 2. A start a turn record or a ledger
   names is bounded by the boundary even when it lies before this turn's
   start; only a front rule 8 moved to where this turn began keeps its place
   past the boundary, and is bounded by where this turn began. *)
(* B10 of RFC librarian-lifecycle §4.10: where this turn began is read only
   when this run wrote its [Opened] before the turn's input. A resumed
   checkpoint already holds the input and maybe the turn's progress, so its
   run's [Opened] names no start. *)
let test_a_resumed_turn_names_no_start () =
  let opening =
    testable
      (fun fmt (opening : Try_provider.this_turn_opening) ->
         Format.pp_print_string fmt
           (match opening with
            | Try_provider.Opened_before_its_input -> "opened before its input"
            | Try_provider.Opened_after_its_input -> "opened after its input"))
      ( = )
  in
  check opening "a turn that records its input opened before it"
    Try_provider.Opened_before_its_input
    (Masc.Keeper_run_prompt.this_turn_opening Masc.Keeper_run_prompt.Record_user_turn);
  check opening "a resumed checkpoint's turn opened after it"
    Try_provider.Opened_after_its_input
    (Masc.Keeper_run_prompt.this_turn_opening
       Masc.Keeper_run_prompt.Skip_already_checkpointed_user_turn)
;;

let test_an_accepted_start_is_bounded_by_the_turn_boundary () =
  let history = exchanges ~from:0 10 in
  let continuity = absorbed_at ~point:2 in
  let start ?source ~this_turn_start accepted =
    (Try_provider.choose_range_start ~past_max_context:None ~held_window:None
       ~continuity:(Some continuity) ~front:None
       ~accepted:(Some (accepted_at ?source history accepted))
       ~history_digest_at:(Window.atom_opening_digest history)
       ~turn_boundary:(Front.Turn_boundary { end_atom = 8 }) ~this_turn_start)
      .Try_provider.start
    |> past_point_start
  in
  let began_at_14 = Some 14 in
  check (option int) "a recorded start past the boundary moves back to it" (Some 8)
    (start ~this_turn_start:began_at_14 12);
  check (option int) "a recorded start where this turn began moves back to the boundary" (Some 8)
    (start ~this_turn_start:began_at_14 14);
  check (option int) "a recorded start before the boundary stays" (Some 6)
    (start ~this_turn_start:began_at_14 6);
  check (option int) "a ledger start past the boundary moves back to it" (Some 8)
    (start ~source:Front.Ledger ~this_turn_start:began_at_14 12);
  check (option int) "a rule-1 front past the boundary moves back to it" (Some 8)
    (start ~source:Front.Turn_start_after_refusal ~this_turn_start:began_at_14 12);
  let this_turn = Front.This_turn_start_after_refusal in
  check (option int) "a rule-8 front past the boundary and before this turn stays" (Some 12)
    (start ~source:this_turn ~this_turn_start:began_at_14 12);
  check (option int) "a rule-8 front where this turn began stays" (Some 14)
    (start ~source:this_turn ~this_turn_start:began_at_14 14);
  check (option int) "a rule-8 front inside this turn moves back to where it began" (Some 14)
    (start ~source:this_turn ~this_turn_start:began_at_14 16);
  check (option int) "with no known start the boundary bounds a rule-8 front" (Some 8)
    (start ~source:this_turn ~this_turn_start:None 12);
  check (option int) "a start state behind the boundary does not lower the bound" (Some 8)
    (start ~source:this_turn ~this_turn_start:(Some 6) 12)
;;

(* Rule 8 over injected rungs: [first] stands for rules 1 and 6, and the
   front rule 1 held is at the turn boundary 8. This turn began at 14. *)
let entry_rung ?(authorized = true) ?(refused = Some 8) ?(this_turn = Some 14)
      ?(held = ref (Some (accepted_at (exchanges ~from:0 10) 8)))
      ~first ~resend () =
  let resends = ref 0 and told = ref 0 in
  let outcome =
    Try_provider.this_turn_start_resend_sequence
      ~same_run_retry_authorized:(fun () -> authorized)
      ~refused_first_atom:(fun () -> refused)
      ~this_turn_front:(fun () -> Option.map (accepted_at (exchanges ~from:0 10)) this_turn)
      ~held_front:(fun () -> !held)
      ~restore_front:(fun prior -> held := prior)
      ~hold_front:(fun seed -> held := Some seed)
      ~on_this_turn_start:(fun _ _ -> incr told)
      ~first
      ~attempt:(fun () -> incr resends; resend ())
      ()
  in
  outcome, !resends, !told, Option.map (fun (seed : Front.seed) -> seed.first_atom) !held
;;

let test_a_refused_ladder_resends_from_where_this_turn_began () =
  let outcome, resends, told, held =
    entry_rung ~first:(fun () -> Error overflow) ~resend:(fun () -> Ok 14) ()
  in
  check (result int reject) "the resend's answer is the turn's" (Ok 14) outcome;
  check int "one resend" 1 resends;
  check int "the move is told once" 1 told;
  check (option int) "the front is held where this turn began" (Some 14) held
;;

let test_an_accepted_ladder_asks_nothing_more () =
  let outcome, resends, told, held =
    entry_rung ~first:(fun () -> Ok 8) ~resend:(fun () -> fail "an accepted request was resent") ()
  in
  check (result int reject) "the ladder's answer is the turn's" (Ok 8) outcome;
  check int "no resend" 0 resends;
  check int "nothing is told" 0 told;
  check (option int) "the front stays at the boundary" (Some 8) held
;;

(* Rule 8 has no later start to try when this turn began where the refused
   request opened, when its start is not known, or when nothing was sent. *)
let test_no_resend_without_a_start_after_the_refused_one () =
  List.iter
    (fun (name, refused, this_turn) ->
       let outcome, resends, told, held =
         entry_rung ~refused ~this_turn ~first:(fun () -> Error overflow)
           ~resend:(fun () -> fail "rule 8 resent without a later start") ()
       in
       check bool (name ^ ": the refusal is the turn's error") true (outcome = Error overflow);
       check int (name ^ ": no resend") 0 resends;
       check int (name ^ ": nothing is told") 0 told;
       check (option int) (name ^ ": the front stays at the boundary") (Some 8) held)
    [ "this turn began at the refused start", Some 14, Some 14
    ; "this turn began before the refused start", Some 14, Some 8
    ; "where this turn began is not known", Some 8, None
    ; "no request was sent", None, Some 14
    ]
;;

(* Only a size refusal the lane may answer on the same run moves the front. *)
let test_no_resend_after_a_refusal_not_about_size () =
  List.iter
    (fun (name, authorized, error) ->
       let outcome, resends, _, held =
         entry_rung ~authorized ~first:(fun () -> Error error)
           ~resend:(fun () -> fail "rule 8 answered a refusal it does not answer") ()
       in
       check bool (name ^ ": the refusal is the turn's error") true (outcome = Error error);
       check int (name ^ ": no resend") 0 resends;
       check (option int) (name ^ ": the front stays at the boundary") (Some 8) held)
    [ "a refusal not about size", true, unattributed_refusal
    ; "a run that may not retry", false, overflow
    ]
;;

(* A refused resend keeps the smaller front only when the refusal was about
   size, as rule 1 does. *)
let test_a_refused_resend_gives_the_front_back_only_when_not_about_size () =
  let outcome, resends, _, held =
    entry_rung ~first:(fun () -> Error overflow) ~resend:(fun () -> Error unattributed_refusal) ()
  in
  check bool "the resend's refusal is the turn's error" true (outcome = Error unattributed_refusal);
  check int "one resend" 1 resends;
  check (option int) "the front goes back to the boundary" (Some 8) held;
  let outcome, resends, _, held =
    entry_rung ~first:(fun () -> Error overflow) ~resend:(fun () -> Error overflow) ()
  in
  check bool "the size refusal is the turn's error" true (outcome = Error overflow);
  check int "one resend, and nothing after" 1 resends;
  check (option int) "the front stays where this turn began" (Some 14) held
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
      ~refused_range:(fun () -> Some (Front.Covered { end_atom = 2 }, 2))
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

(* The size signal, as rules from what a turn's first request reads to
   where its range opens.
   The pair's ledger last carried a window that opened at atom 4; the last
   completed turn ended at atom 8. Under that window the second turn grew
   from 1,500 to 2,400, so the next turn is expected at 2,400 + 900. *)
let window_ledger ?(demote_before = 0) ~history ~first_atom counts =
  let atom_count, digest_at = Window.atom_opening_index history in
  List.fold_left
    (fun ledger (turn_context, input_tokens) ->
       let request =
         { (request ~digest_at ~first_atom ~atom_count) with turn_context; demote_before }
       in
       Some
         (Ledger.observe ~digest_at ledger request
            (Ledger.usage_of_counts ~input_tokens ~cache_read_input_tokens:0))
           .ledger)
    None counts
;;

let grown_turns = [ true, 1_000; false, 1_500; true, 1_600; false, 2_400 ]
let boundary_8 = Front.Turn_boundary { end_atom = 8 }

let input_limit_of ?(kind = Llm_provider.Provider_config.OpenAI_compat) ?max_tokens
      max_context =
  Option.bind max_context (fun max_context ->
    let cfg =
      Llm_provider.Provider_config.make
        ~kind
        ~model_id:"eviction-test"
        ~base_url:"https://api.example.test"
        ~max_context
        ?max_tokens
        ()
    in
    Try_provider.input_limit_of_provider_config cfg)
;;

let signal_over ?(input_limit = input_limit_of (Some 3_000)) ?(turn_boundary = boundary_8)
      ?continuity ~history ledger =
  Try_provider.past_max_context ~input_limit ~continuity
    ~history_digest_at:(Window.atom_opening_digest history) ~turn_boundary ledger
;;

let test_the_size_signal_reads_the_ledger_and_the_declaration () =
  let history = exchanges ~from:0 10 in
  let ledger = window_ledger ~history ~first_atom:4 grown_turns in
  (match signal_over ~history ledger with
   | Some signal ->
     check int "it moves the window that opened at 4" 4 signal.window_first_atom;
     check int "to the turn boundary" 8 signal.moved_to.Front.first_atom;
     check int "the next turn's expected count" 3_300 signal.next_turn_peak;
     check string "named for the signal" "turn_start_at_max_context"
       (Front.source_to_string signal.moved_to.Front.source)
   | None -> fail "a next turn past input limit moves the window");
  let none label signal = check bool label true (Option.is_none signal) in
  none "a next turn at input limit stays"
    (signal_over ~input_limit:(input_limit_of (Some 3_300)) ~history ledger);
  none "no derived input limit, no signal" (signal_over ~input_limit:None ~history ledger);
  none "no ledger, no signal" (signal_over ~history None);
  none "an unknown boundary names nowhere to move"
    (signal_over ~turn_boundary:(Front.Turn_boundary_unknown { reason = "test" }) ~history ledger);
  none "a boundary at the window's start is not past it"
    (signal_over ~turn_boundary:(Front.Turn_boundary { end_atom = 4 }) ~history ledger);
  none "a window no turn has opened under yet has no growth"
    (signal_over ~history (window_ledger ~history ~first_atom:4 [ true, 1_000; false, 2_900 ]));
  none "without turn growth, a count equal to input_limit stays"
    (signal_over ~history (window_ledger ~history ~first_atom:4 [ true, 3_000 ]));
  (match signal_over ~history (window_ledger ~history ~first_atom:4 [ true, 3_100 ]) with
   | Some signal ->
     check int "already-over-limit first window moves from 4" 4 signal.window_first_atom;
     check int "already-over-limit moves to turn boundary" 8 signal.moved_to.Front.first_atom;
     check int "uses provider-counted last_input_tokens as lower bound" 3_100 signal.next_turn_peak;
     check string "turn_start_at_max_context source" "turn_start_at_max_context"
       (Front.source_to_string signal.moved_to.Front.source)
   | None -> fail "last_input_tokens > input_limit must fire even before turn growth is measured");
  (match
     signal_over
       ~continuity:(absorbed_at ~point:6)
       ~history
       (window_ledger ~history ~first_atom:4 [ true, 1_000; false, 3_200 ])
   with
   | Some signal ->
     check int "already-over-limit with Librarian continuity moves to point 6" 6
       signal.moved_to.Front.first_atom;
     check int "lower-bound peak uses latest provider count" 3_200 signal.next_turn_peak;
     check string "librarian_point_at_max_context source" "librarian_point_at_max_context"
       (Front.source_to_string signal.moved_to.Front.source)
   | None -> fail "already-over-limit window with Librarian continuity must move to point 6");
  none "a ledger this history does not hold moves nothing"
    (signal_over ~history:(exchanges ~from:100 10) ledger);
  (* Issue #53504: window = 400_000, reserved output = 128_000 -> input_limit = 272_000.
     A next_turn_peak of 272_780 passes 272_000 and must move, whereas omitting
     max_tokens leaves input_limit = 400_000 and stays. *)
  let ledger_53504 =
    window_ledger ~history ~first_atom:4
      [ true, 150_000; false, 180_000; true, 185_000; false, 226_390 ]
  in
  let reserved_limit =
    input_limit_of ~max_tokens:128_000 (Some 400_000)
  in
  (match reserved_limit with
   | Some l -> check int "#53504 input_limit" 272_000 (l :> int)
   | None -> fail "expected #53504 input_limit");
  (match signal_over ~input_limit:reserved_limit ~history ledger_53504 with
   | Some signal ->
     check int "#53504 peak" 272_780 signal.next_turn_peak;
     check int "#53504 signal input_limit" 272_000 (signal.input_limit :> int)
   | None -> fail "#53504 next_turn_peak 272_780 must pass input_limit 272_000");
  none "#53504 omitted optional reservation stays under 400_000"
    (signal_over ~input_limit:(input_limit_of (Some 400_000)) ~history ledger_53504);
  none "reserved >= window yields None input_limit so signal stays off"
    (signal_over ~input_limit:(input_limit_of ~max_tokens:400_000 (Some 400_000))
       ~history ledger_53504)
;;

let opens = function
  | Try_provider.From_seed seed -> seed.Front.first_atom
  | Try_provider.Past_librarian_point { accepted; _ } -> accepted.Front.first_atom
  | Try_provider.From_covered { Try_provider.end_atom; _ } -> end_atom
  | Try_provider.From_turn_boundary (Front.Turn_boundary { end_atom }) -> end_atom
  | Try_provider.From_turn_boundary (Front.Turn_boundary_unknown _) -> -1
;;

let test_the_size_signal_moves_only_a_window_that_stays () =
  let history = exchanges ~from:0 10 in
  let digest_at = Window.atom_opening_digest history in
  let signal = signal_over ~history (window_ledger ~history ~first_atom:4 grown_turns) in
  check bool "the signal is on" true (Option.is_some signal);
  let start ?continuity ?front ?accepted past_max_context =
    let { Try_provider.start; _ } =
      Try_provider.choose_range_start ~past_max_context ~held_window:None
        ~continuity:(Option.map (fun point -> absorbed_at ~point) continuity)
        ~front ~accepted ~history_digest_at:digest_at ~turn_boundary:boundary_8
        ~this_turn_start:None
    in
    opens start, Front.origin_to_string (Try_provider.range_start_origin start)
  in
  let at = pair int string in
  let ledger_4 = accepted_at ~source:Front.Ledger history 4 in
  let record_4 = accepted_at history 4 in
  check at "no point: the window at the ledger's front moves to the boundary"
    (8, "turn_start_at_max_context") (start ~front:ledger_4 signal);
  check at "no point, no signal: it stays" (4, "ledger") (start ~front:ledger_4 None);
  check at "a point behind the window: the accepted start moves to the boundary"
    (8, "turn_start_at_max_context")
    (start ~continuity:2 ~accepted:record_4 signal);
  check at "a point behind the window, no signal: it stays"
    (4, "turn_record#1") (start ~continuity:2 ~accepted:record_4 None);
  check at "a window that opened at the point moves past it"
    (8, "turn_start_at_max_context") (start ~continuity:4 signal);
  check at "a point past the window moved it already" (6, "covered")
    (start ~continuity:6 ~accepted:record_4 signal);
  check at "a front a refusal held past the window moved it already"
    (10, "this_turn_start_after_refusal")
    (start ~front:(accepted_at ~source:Front.This_turn_start_after_refusal history 10) signal);
  (* A later request of the same turn reads no signal; the front the first
     request moved is held, and the point yields to it. *)
  let held = Option.map (fun (s : Try_provider.past_max_context) -> s.moved_to) signal in
  check at "the rest of the turn opens at the held front"
    (8, "turn_start_at_max_context")
    (start ~continuity:2 ?accepted:held None);
  (* The forecast asks the same rule and counts nothing for the moved range. *)
  let forecast =
    Masc.Keeper_next_request_forecast.carry ?past_max_context:signal
      ~measure:(Masc.Keeper_context_core.message_measurer ())
      ~continuity:(Some Try_provider.No_read_end) ~front:(Some ledger_4) ~accepted:None
      ~turn_start:boundary_8 ~this_turn_start:None
      ~counted_tokens:(Some 2_400) history
  in
  check int "the forecast opens where the request will" 8 forecast.first_atom;
  check (option int) "and the window's count does not ride along" None forecast.counted_tokens
;;

(* With a Librarian point, a window that stays holds at the start the
   provider last accepted, even after the Librarian read past it: the
   point moves the window only when the window moves. A window not held
   there follows the point. *)
let test_a_window_that_stays_holds_behind_the_librarian_point () =
  let history = exchanges ~from:0 10 in
  let held at =
    Some { Try_provider.window_opened_at = at; markers_before = 0; working_state = None }
  in
  let start ~held_window ~point accepted =
    let { Try_provider.start; _ } =
      Try_provider.choose_range_start ~past_max_context:None ~held_window
        ~continuity:(Some (absorbed_at ~point)) ~front:None
        ~accepted:(Some (accepted_at history accepted))
        ~history_digest_at:(Window.atom_opening_digest history) ~turn_boundary:boundary_8
        ~this_turn_start:None
    in
    opens start, Front.origin_to_string (Try_provider.range_start_origin start)
  in
  let at = pair int string in
  check at "a window held at the accepted start stays behind the point"
    (4, "turn_record#1") (start ~held_window:(held 4) ~point:6 4);
  check at "a window not held follows the point" (6, "covered")
    (start ~held_window:None ~point:6 4);
  check at "a window held elsewhere follows the point" (6, "covered")
    (start ~held_window:(held 2) ~point:6 4);
  check at "a start past the point opens there, held or not"
    (7, "turn_record#1") (start ~held_window:None ~point:6 7)
;;

(* The signal moves a window that stays to the end of what the Librarian
   read when that lies past the window, so the atoms it drops are in memory;
   a point at or behind the window leaves the turn boundary. The rest of
   the turn holds the moved front, even when the Librarian reads on. *)
let test_the_size_signal_moves_to_the_librarian_point () =
  let history = exchanges ~from:0 10 in
  let ledger = window_ledger ~history ~first_atom:4 grown_turns in
  let target ~point =
    Option.map
      (fun (signal : Try_provider.past_max_context) ->
         signal.moved_to.Front.first_atom, Front.source_to_string signal.moved_to.Front.source)
      (signal_over ~continuity:(absorbed_at ~point) ~history ledger)
  in
  let to_ = option (pair int string) in
  check to_ "a point past the window" (Some (6, "librarian_point_at_max_context"))
    (target ~point:6);
  check to_ "a point at the window" (Some (8, "turn_start_at_max_context")) (target ~point:4);
  check to_ "a point behind the window" (Some (8, "turn_start_at_max_context"))
    (target ~point:2);
  let choose ?past_max_context ~held_at ~point accepted =
    let choice =
      Try_provider.choose_range_start ~past_max_context
        ~held_window:
          (Some
             { Try_provider.window_opened_at = held_at; markers_before = 0; working_state = None })
        ~continuity:(Some (absorbed_at ~point)) ~front:None ~accepted:(Some accepted)
        ~history_digest_at:(Window.atom_opening_digest history) ~turn_boundary:boundary_8
        ~this_turn_start:None
    in
    ( opens choice.Try_provider.start
    , Option.map (fun (seed : Front.seed) -> seed.first_atom) choice.moved_at_max_context )
  in
  let moved = pair int (option int) in
  let signal = signal_over ~continuity:(absorbed_at ~point:6) ~history ledger in
  check moved "the turn's first request opens at the point and names it to hold" (6, Some 6)
    (choose ?past_max_context:signal ~held_at:4 ~point:6 (accepted_at history 4));
  let held_front = (Option.get signal).Try_provider.moved_to in
  check moved "the rest of the turn opens there while the Librarian reads on" (6, None)
    (choose ~held_at:6 ~point:7 held_front)
;;

(* Markers wait for the window to move only while the size signal watches
   it. *)
let test_markers_wait_only_while_the_size_signal_watches () =
  let history = exchanges ~from:0 10 in
  let held ?(opens_turn = true) ?(input_limit = input_limit_of (Some 400_000)) ledger =
    Option.map
      (fun (held : Try_provider.held_window) -> held.window_opened_at, held.markers_before)
      (Try_provider.held_window ~opens_turn ~input_limit
         ~history_digest_at:(Window.atom_opening_digest history) ledger)
  in
  let at = option (pair int int) in
  let grown = window_ledger ~demote_before:6 ~history ~first_atom:4 grown_turns in
  check at "the signal watches: the markers stay where the window sent them" (Some (4, 6))
    (held grown);
  check at "no derived input limit: a turn's first request demotes the ended turns" None
    (held ~input_limit:None grown);
  let unmeasured =
    window_ledger ~demote_before:6 ~history ~first_atom:4 [ true, 1_000; false, 2_900 ]
  in
  check at "no turn has grown under the ledger yet: the same" None (held unmeasured);
  check at "later in the turn they stay where its first request put them" (Some (4, 6))
    (held ~opens_turn:false ~input_limit:None unmeasured);
  check at "no ledger holds nothing" None (held ~opens_turn:false None);
  check at "a ledger this history does not hold holds nothing" None
    (held ~opens_turn:false
       (window_ledger ~history:(exchanges ~from:100 10) ~first_atom:4 grown_turns))
;;

(* P0-1b: Mid-turn current-turn tool demotion, deterministic preview fallback
   without keeper_artifact_read, and oldest closed round drop + compaction
   anchor projection. *)
let test_p0_1b_current_turn_tool_demotion_preview_and_round_drop () =
  let measure = Masc.Keeper_context_core.message_measurer () in
  let wire_measure m = Some (measure m) in
  let big_payload tag = tag ^ ":" ^ String.make 8192 'A' in
  let tool_round idx =
    let id = Printf.sprintf "call-%d" idx in
    [ { Types.origin = Llm_provider.Types.Conversation
      ; role = Types.Assistant
      ; content =
          [ Types.ToolUse
              { id
              ; name = "masc_probe"
              ; input = `Assoc [ "payload", `String (big_payload (Printf.sprintf "arg-%d" idx)) ]
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { Types.origin = Llm_provider.Types.Conversation
      ; role = Types.Tool
      ; content =
          [ Types.ToolResult
              { tool_use_id = id
              ; content = big_payload (Printf.sprintf "res-%d" idx)
              ; outcome = Types.Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = Some id
      ; metadata = []
      }
    ]
  in
  let open_suffix =
    { Types.origin = Llm_provider.Types.Conversation
    ; role = Types.Assistant
    ; content =
        [ Types.ToolUse
            { id = "call-open"
            ; name = "masc_probe"
            ; input = `Assoc [ "payload", `String (big_payload "open-arg") ]
            }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let messages =
    [ text_message Types.User "current turn goal" ]
    @ tool_round 1
    @ tool_round 2
    @ tool_round 3
    @ [ open_suffix ]
  in
  (* 1. bind_closed_arguments_in_messages binds closed ToolUses and excludes open suffix. *)
  let bound =
    match Masc.Keeper_model_input_demotion.bind_closed_arguments_in_messages messages with
    | Ok bound -> bound
    | Error _ -> fail "bind_closed_arguments_in_messages rejected valid transcript"
  in
  let planned =
    Masc.Keeper_model_input_demotion.plan
      ~completed_arguments:bound
      ~measure_message_bytes:measure
      ~measure_wire_bytes:wire_measure
      ~demote_before:(List.length messages)
      messages
  in
  check bool "planned demotion shrinks closed ToolUses and ToolResults" true
    (planned.pending <> []);
  let last_planned = List.hd (List.rev planned.messages) in
  check bool "open suffix ToolUse stays verbatim" true (last_planned = open_suffix);
  (* 2. Deterministic head+tail preview fallback works even without keeper_artifact_read. *)
  let total_bytes msgs = List.fold_left (fun acc m -> acc + measure m) 0 msgs in
  let previewed, changed =
    Masc.Keeper_model_input_demotion.preview_fallback_closed_tool_bodies
      ~measure_message_bytes:measure
      messages
  in
  check bool "preview fallback reports change on oversized closed tools" true changed;
  check bool "preview fallback strictly reduces encoded bytes" true
    (total_bytes previewed < total_bytes messages);
  check bool "preview fallback never mutates open ToolUse suffix" true
    (List.hd (List.rev previewed) = open_suffix);
  let _, changed_again =
    Masc.Keeper_model_input_demotion.preview_fallback_closed_tool_bodies
      ~measure_message_bytes:measure
      previewed
  in
  check bool "preview fallback is idempotent" false changed_again;
  (* 3. compose_carried_model_input supports both in-turn demotion modes. *)
  let closed_messages =
    [ text_message Types.User "current turn goal" ] @ tool_round 1 @ tool_round 2 @ tool_round 3
  in
  let digest_at = Window.atom_opening_digest closed_messages in
  let base_path = Filename.temp_dir "masc-p0-1b-demotion-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       let baseline =
         Try_provider.For_testing.compose_carried_model_input
           ~measure_message_bytes:measure
           ~measure_wire_bytes:wire_measure
           ~front:None
           ~accepted:None
           ~history_digest_at:digest_at
           ~current_turn_results:Try_provider.Current_turn_verbatim
           ~base_path
           ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
           closed_messages
       in
       let with_blob_demotion =
         Try_provider.For_testing.compose_carried_model_input
           ~in_turn_demotion:Try_provider.For_testing.Demote_closed_current_turn_tools
           ~measure_message_bytes:measure
           ~measure_wire_bytes:wire_measure
           ~front:None
           ~accepted:None
           ~history_digest_at:digest_at
           ~current_turn_results:Try_provider.Current_turn_verbatim
           ~base_path
           ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
           closed_messages
       in
       let with_preview_fallback =
         Try_provider.For_testing.compose_carried_model_input
           ~in_turn_demotion:Try_provider.For_testing.Demote_and_preview_closed_current_turn_tools
           ~measure_message_bytes:measure
           ~measure_wire_bytes:wire_measure
           ~front:None
           ~accepted:None
           ~history_digest_at:digest_at
           ~current_turn_results:Try_provider.Current_turn_verbatim
           ~base_path:""
           ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
           closed_messages
       in
       check bool "in-turn blob demotion strictly shrinks carried bytes" true
         (with_blob_demotion.transmitted_bytes < baseline.transmitted_bytes);
       check bool "in-turn preview fallback shrinks carried bytes even with base_path=\"\"" true
         (with_preview_fallback.transmitted_bytes < baseline.transmitted_bytes);
       (* 4. droppable_current_turn_tool_atoms selects oldest closed tool rounds
          and commits/attaches a compaction anchor even when first_atom = 0. *)
       let droppable =
         Try_provider.For_testing.droppable_current_turn_tool_atoms
           ~first_atom:0
           ~already_dropped:[]
           closed_messages
       in
       check bool "droppable selects at least one closed round" true (droppable <> []);
       check bool "droppable never drops atom 0 (User goal)" false (List.mem 0 droppable);
       let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
       let anchor =
         match
           Masc.Keeper_compaction.compact_evicted_messages
             ~keepers_dir
             ~keeper_id:"p0-1b-keeper"
             ~trigger:(Masc.Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
             ~evicted_messages:(tool_round 1)
             ()
         with
         | Ok (Some anchor) -> anchor
         | Ok None -> fail "expected committed compaction anchor"
         | Error err -> fail (Masc.Keeper_compaction.store_error_to_string err)
       in
       let dropped_composed =
         Try_provider.For_testing.compose_carried_model_input
           ~compaction_anchor:anchor
           ~dropped_current_turn_atoms:droppable
           ~measure_message_bytes:measure
           ~measure_wire_bytes:wire_measure
           ~front:None
           ~accepted:None
           ~history_digest_at:digest_at
           ~current_turn_results:Try_provider.Current_turn_verbatim
           ~base_path
           ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
           closed_messages
       in
       check bool "dropped current-turn rounds strictly shrink message count" true
         (List.length dropped_composed.projection.Window.messages < List.length closed_messages + 1);
       check bool "compaction anchor is injected when current-turn atoms were dropped" true
         (List.exists Window.is_compaction_anchor dropped_composed.projection.Window.messages))
;;

(* P1-6: token-vs-byte conversion helper + mixed-size first failover jumping to
   From_turn_boundary commits a durable Keeper_compaction anchor and projects it. *)
let test_p1_6_token_to_byte_conversion_and_mixed_size_first_failover_anchor () =
  check int "zero tokens -> 0 bytes" 0 (Try_provider.For_testing.compaction_bytes_of_tokens 0);
  check int "negative tokens clamp to 0" 0 (Try_provider.For_testing.compaction_bytes_of_tokens (-42));
  check int "128k tokens -> 512k bytes" 512_000
    (Try_provider.For_testing.compaction_bytes_of_tokens 128_000);
  check int "max_int saturates without wraparound" max_int
    (Try_provider.For_testing.compaction_bytes_of_tokens max_int);
  let history = exchanges ~from:0 10 in
  let digest_at = Window.atom_opening_digest history in
  let base_path = Filename.temp_dir "masc-p1-6-failover-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
       let keeper_id = "p1-6-mixed-failover" in
       let anchor =
         match
           Masc.Keeper_compaction.compact_evicted_messages
             ~keepers_dir
             ~keeper_id
             ~trigger:(Masc.Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
             ~evicted_messages:(List.filteri (fun i _ -> i < 6) history)
             ()
         with
         | Ok (Some anchor) -> anchor
         | Ok None -> fail "expected committed anchor for mixed-size failover"
         | Error err -> fail (Masc.Keeper_compaction.store_error_to_string err)
       in
       let persisted =
         match Masc.Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id with
         | Ok (Some latest) -> latest
         | Ok None -> fail "committed anchor not persisted in SQLite"
         | Error err -> fail (Masc.Keeper_compaction.store_error_to_string err)
       in
       check int "persisted anchor epoch matches" anchor.epoch_id persisted.epoch_id;
       let composed =
         Try_provider.For_testing.compose_carried_model_input
           ~compaction_anchor:persisted
           ~measure_message_bytes:(Masc.Keeper_context_core.message_measurer ())
           ~measure_wire_bytes:(fun _ -> None)
           ~front:None
           ~accepted:None
           ~history_digest_at:digest_at
           ~current_turn_results:Try_provider.Current_turn_verbatim
           ~base_path
           ~turn_boundary:(Front.Turn_boundary { end_atom = 6 })
           history
       in
       check int "From_turn_boundary drops atoms before turn boundary" 6
         composed.projection.Window.dropped_atoms;
       check bool "mixed-size failover projects compaction anchor ahead of carried suffix" true
         (List.exists Window.is_compaction_anchor composed.projection.Window.messages))
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
        ; test_case "P0-1b current-turn tool demotion, preview fallback, and round drop" `Quick
            test_p0_1b_current_turn_tool_demotion_preview_and_round_drop
        ; test_case "P1-6 token-to-byte conversion and mixed-size failover anchor" `Quick
            test_p1_6_token_to_byte_conversion_and_mixed_size_first_failover_anchor
        ] )
    ; ( "this turn's start"
      , [ test_case "a resumed turn names no start" `Quick test_a_resumed_turn_names_no_start
        ; test_case "an accepted start is bounded by the turn boundary" `Quick
            test_an_accepted_start_is_bounded_by_the_turn_boundary
        ; test_case "a refused ladder resends from where this turn began" `Quick
            test_a_refused_ladder_resends_from_where_this_turn_began
        ; test_case "an accepted ladder asks nothing more" `Quick
            test_an_accepted_ladder_asks_nothing_more
        ; test_case "no resend without a start after the refused one" `Quick
            test_no_resend_without_a_start_after_the_refused_one
        ; test_case "no resend after a refusal not about size" `Quick
            test_no_resend_after_a_refusal_not_about_size
        ; test_case "a refused resend gives the front back only when not about size" `Quick
            test_a_refused_resend_gives_the_front_back_only_when_not_about_size
        ] )
    ; ( "size signal"
      , [ test_case "it reads the ledger and the declaration" `Quick
            test_the_size_signal_reads_the_ledger_and_the_declaration
        ; test_case "it moves only a window that stays" `Quick
            test_the_size_signal_moves_only_a_window_that_stays
        ] )
    ; ( "held markers"
      , [ test_case "they wait only while the size signal watches" `Quick
            test_markers_wait_only_while_the_size_signal_watches
        ] )
    ; ( "held window"
      , [ test_case "it stays behind the Librarian point" `Quick
            test_a_window_that_stays_holds_behind_the_librarian_point
        ; test_case "the signal moves it to the Librarian point" `Quick
            test_the_size_signal_moves_to_the_librarian_point
        ] )
    ]
;;
