(** The parity guard [turn_fsm.mli] says verifies parity.

    Its header states that the [@tla.*] annotations "bind states + the
    transition matrix to that spec" and that [test_keeper_turn_fsm_tla_parity]
    verifies it. No such module existed. What did exist —
    [test_keeper_turn_fsm_emit]'s [test_transition_actions_cover_tla_next] —
    hand-lists transitions and checks each produces the expected label; it never
    opens the [.tla]. [scripts/tla-check.sh] runs TLC over the spec, which
    checks the spec against its own invariants, not against OCaml.

    So nothing compared the two vocabularies. This does: it reads the [Next]
    disjunction out of the spec and requires every action named there to exist
    as a [transition_action].

    The reverse does not hold and is not asserted as equality. Five OCaml
    actions have no counterpart in [Next] — the phase gate pair, the two
    routing failures, and the generic failure. They are listed below rather
    than tolerated silently, so a sixth has to be looked at. *)

open Alcotest

module F = Turn_fsm

(* The runtest action runs in the test directory; the dune stanza stages the
   spec beside it under the build root. *)
let spec_path = "../specs/keeper-turn-fsm/KeeperTurnFSM.tla"

(* Actions the spec's Next disjunction admits. Lines look like "    \/ Name". *)
let tla_next_actions () =
  let contents =
    let ic = open_in spec_path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  let lines = String.split_on_char '\n' contents in
  let rec collect acc in_next = function
    | [] -> List.rev acc
    | line :: rest ->
      let trimmed = String.trim line in
      if (not in_next) && String.equal trimmed "Next =="
      then collect acc true rest
      else if in_next
      then
        if String.length trimmed > 3 && String.starts_with ~prefix:"\\/" trimmed
        then collect (String.trim (String.sub trimmed 2 (String.length trimmed - 2)) :: acc) true rest
        else if String.equal trimmed ""
        then collect acc true rest
        else List.rev acc (* Next block ended *)
      else collect acc false rest
  in
  collect [] false lines
;;

let ocaml_action_labels () =
  List.map F.transition_action_label F.all_transition_actions
;;

(* A guard that reads nothing passes for the wrong reason. *)
let test_spec_is_readable_and_names_actions () =
  let actions = tla_next_actions () in
  check bool
    (Printf.sprintf "%s yields a non-empty Next disjunction" spec_path)
    true
    (actions <> []);
  check bool "Next names StartTurn" true (List.mem "StartTurn" actions)
;;

let test_every_spec_action_exists_in_ocaml () =
  let labels = ocaml_action_labels () in
  List.iter
    (fun action ->
      check bool
        (Printf.sprintf "spec action %s has a transition_action" action)
        true
        (List.mem action labels))
    (tla_next_actions ())
;;

(* The five below are OCaml-side refinements the spec does not model. Pinning
   the set means adding a sixth fails here instead of widening the gap
   quietly. *)
let expected_ocaml_only =
  [ "GenericFail"
  ; "NoToolCapableProvider"
  ; "PhaseGateOk"
  ; "PhaseGateSkip"
  ; "ProviderError"
  ]
;;

let test_ocaml_only_actions_are_the_listed_ones () =
  let spec = tla_next_actions () in
  let extra =
    ocaml_action_labels ()
    |> List.filter (fun label -> not (List.mem label spec))
    |> List.sort String.compare
  in
  check (list string) "OCaml actions absent from the spec's Next" expected_ocaml_only extra
;;

let test_labels_are_distinct () =
  let labels = ocaml_action_labels () in
  check int
    "every transition_action has its own label"
    (List.length labels)
    (List.length (List.sort_uniq String.compare labels))
;;

let () =
  Alcotest.run
    "Keeper turn FSM TLA parity"
    [ ( "spec"
      , [ test_case "is readable and names actions" `Quick
            test_spec_is_readable_and_names_actions
        ] )
    ; ( "parity"
      , [ test_case "every spec action exists in OCaml" `Quick
            test_every_spec_action_exists_in_ocaml
        ; test_case "OCaml-only actions are the listed ones" `Quick
            test_ocaml_only_actions_are_the_listed_ones
        ; test_case "labels are distinct" `Quick test_labels_are_distinct
        ] )
    ]
;;
