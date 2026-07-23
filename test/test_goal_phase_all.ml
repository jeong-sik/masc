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
    ]
