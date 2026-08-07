(* RFC-0089 — Goal_phase.all / all_actions are the SSOT for the MCP goal schema
   enums and the workspace_goals validator, both built as
   [List.map to_string all]. This guards those lists: every entry round-trips
   through of_string, the derived string set has no duplicates, and it matches
   the expected set AND order (so deriving does not silently change the
   advertised enum order). to_string / action_to_string are the exhaustive
   compile-time witnesses; this test guards the [all] / [all_actions] lists. *)

module GP = Goal_phase
open Alcotest

let test_phase_roundtrip () =
  List.iter
    (fun p ->
      check bool
        (Printf.sprintf "phase %s round-trips" (GP.to_string p))
        true
        (GP.of_string (GP.to_string p) = Some p))
    GP.all

let test_phase_set () =
  let strs = List.map GP.to_string GP.all in
  check int "phase count" 5 (List.length GP.all);
  check int "no duplicate phase strings"
    (List.length strs)
    (List.length (List.sort_uniq String.compare strs));
  check (list string) "phase set and order"
    [
      "executing";
      "blocked";
      "paused";
      "completed";
      "dropped";
    ]
    strs

let test_action_roundtrip () =
  List.iter
    (fun a ->
      check bool
        (Printf.sprintf "action %s round-trips" (GP.action_to_string a))
        true
        (GP.action_of_string (GP.action_to_string a) = Some a))
    GP.all_actions

let test_action_set () =
  let strs = List.map GP.action_to_string GP.all_actions in
  check int "action count" 7 (List.length GP.all_actions);
  check int "no duplicate action strings"
    (List.length strs)
    (List.length (List.sort_uniq String.compare strs));
  check (list string) "action set and order"
    [
      "request_complete";
      "pause";
      "resume";
      "block";
      "unblock";
      "drop";
      "reopen";
    ]
    strs

(* The 5x7 matrix in [decide_transition] had no behavioural test. Its comment
   says the compiler "refuses a matrix with a hole in it", and that is true --
   but exhaustiveness proves each pair has an arm, not that the arm gives the
   right answer. Every pair is stated here as a literal, so a matrix edit shows
   up as a diff in expectations rather than as a silently different answer. *)

let outcome_label = function
  | Ok (GP.Move_to phase) -> "move_to:" ^ GP.to_string phase
  | Ok (GP.Already phase) -> "already:" ^ GP.to_string phase
  | Error _ -> "invalid"

(* phase, action, expected outcome. Read down a column to see one action across
   all phases; the diagonal (target phase = current phase) is "already:*". *)
let matrix =
  [
    (GP.Executing, GP.Request_complete, "move_to:completed");
    (GP.Executing, GP.Pause, "move_to:paused");
    (GP.Executing, GP.Resume, "already:executing");
    (GP.Executing, GP.Block, "move_to:blocked");
    (GP.Executing, GP.Unblock, "already:executing");
    (GP.Executing, GP.Drop, "move_to:dropped");
    (GP.Executing, GP.Reopen, "already:executing");
    (GP.Blocked, GP.Request_complete, "invalid");
    (GP.Blocked, GP.Pause, "invalid");
    (GP.Blocked, GP.Resume, "invalid");
    (GP.Blocked, GP.Block, "already:blocked");
    (GP.Blocked, GP.Unblock, "move_to:executing");
    (GP.Blocked, GP.Drop, "move_to:dropped");
    (GP.Blocked, GP.Reopen, "invalid");
    (GP.Paused, GP.Request_complete, "invalid");
    (GP.Paused, GP.Pause, "already:paused");
    (GP.Paused, GP.Resume, "move_to:executing");
    (GP.Paused, GP.Block, "invalid");
    (GP.Paused, GP.Unblock, "invalid");
    (GP.Paused, GP.Drop, "move_to:dropped");
    (GP.Paused, GP.Reopen, "invalid");
    (GP.Completed, GP.Request_complete, "already:completed");
    (GP.Completed, GP.Pause, "invalid");
    (GP.Completed, GP.Resume, "invalid");
    (GP.Completed, GP.Block, "invalid");
    (GP.Completed, GP.Unblock, "invalid");
    (GP.Completed, GP.Drop, "move_to:dropped");
    (GP.Completed, GP.Reopen, "move_to:executing");
    (GP.Dropped, GP.Request_complete, "invalid");
    (GP.Dropped, GP.Pause, "invalid");
    (GP.Dropped, GP.Resume, "invalid");
    (GP.Dropped, GP.Block, "invalid");
    (GP.Dropped, GP.Unblock, "invalid");
    (GP.Dropped, GP.Drop, "already:dropped");
    (GP.Dropped, GP.Reopen, "move_to:executing");
  ]

let test_matrix_is_total () =
  check int "every phase/action pair is stated once"
    (List.length GP.all * List.length GP.all_actions)
    (List.length matrix);
  let keys =
    List.map
      (fun (p, a, _) -> GP.to_string p ^ "/" ^ GP.action_to_string a)
      matrix
  in
  check int "no duplicate pair" (List.length keys)
    (List.length (List.sort_uniq String.compare keys))

let test_matrix_outcomes () =
  List.iter
    (fun (phase, action, expected) ->
      check string
        (Printf.sprintf "%s + %s" (GP.to_string phase)
           (GP.action_to_string action))
        expected
        (outcome_label (GP.decide_transition ~phase ~action)))
    matrix

(* An [Already] never names a phase other than the one asked about: that is what
   lets the tool answer from the goal it already read instead of writing. *)
let test_already_is_the_current_phase () =
  List.iter
    (fun phase ->
      List.iter
        (fun action ->
          match GP.decide_transition ~phase ~action with
          | Ok (GP.Already reported) ->
            check string
              (Printf.sprintf "%s + %s reports its own phase"
                 (GP.to_string phase) (GP.action_to_string action))
              (GP.to_string phase) (GP.to_string reported)
          | Ok (GP.Move_to _) | Error _ -> ())
        GP.all_actions)
    GP.all

(* The Task FSM answers the same shape with the status unchanged. This pins the
   agreement so the two domains cannot drift apart again unnoticed. *)
let test_agrees_with_task_fsm_on_restating_a_terminal_state () =
  check string "completed + request_complete" "already:completed"
    (outcome_label
       (GP.decide_transition ~phase:GP.Completed ~action:GP.Request_complete));
  check string "dropped + drop" "already:dropped"
    (outcome_label (GP.decide_transition ~phase:GP.Dropped ~action:GP.Drop));
  (* Not on the diagonal: completion is not the phase a dropped goal is in, so
     this stays a real request for a state change and is refused. *)
  check string "dropped + request_complete stays invalid" "invalid"
    (outcome_label
       (GP.decide_transition ~phase:GP.Dropped ~action:GP.Request_complete))

let () =
  run "goal_phase_all"
    [
      ( "phase",
        [
          test_case "round-trip" `Quick test_phase_roundtrip;
          test_case "set and order" `Quick test_phase_set;
        ] );
      ( "action",
        [
          test_case "round-trip" `Quick test_action_roundtrip;
          test_case "set and order" `Quick test_action_set;
        ] );
      ( "transition matrix",
        [
          test_case "every pair stated once" `Quick test_matrix_is_total;
          test_case "outcomes" `Quick test_matrix_outcomes;
          test_case "already reports the current phase" `Quick
            test_already_is_the_current_phase;
          test_case "agrees with the Task FSM on restating a terminal state"
            `Quick test_agrees_with_task_fsm_on_restating_a_terminal_state;
        ] );
    ]
