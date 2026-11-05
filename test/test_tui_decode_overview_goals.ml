(* Decoding of the goal tree the TUI reads from GET /api/v1/dashboard/goals.
   A tree the decoder cannot trust is refused: a goal without its children
   field, a phase no Goal_phase spells, and a measurement recorded against a
   criterion revision other than the goal's current one. *)

open Alcotest
module Tui_decode = Masc.Tui_decode

let test_a_goal_without_children_is_refused () =
  let json =
    Yojson.Safe.from_string
      {|{"tree":[{"id":"goal-x","title":"x","phase":"executing","priority":1,
          "due_date":null,"task_count":0,"task_done_count":0,
          "stagnation_seconds":null,"tasks":[]}]}|}
  in
  match Tui_decode.decode_overview_goals json with
  | Error (Tui_decode.Overview_goals_malformed _) -> ()
  | Error other ->
      failf "refused for another reason: %s"
        (Tui_decode.overview_goals_error_to_string other)
  | Ok _ -> fail "a goal with no children field decoded"

let test_an_unknown_phase_is_refused () =
  (* #41151 restored paused/blocked as suspended phases, so "paused" is no
     longer unknown: it is refused for its missing resume_phase instead.
     The fixture needs a phase name no Goal_phase.Kind spells. *)
  let json =
    Yojson.Safe.from_string
      {|{"tree":[{"id":"goal-x","title":"x","phase":"hibernating","priority":1,
          "due_date":null,"task_count":0,"task_done_count":0,
          "stagnation_seconds":null,"tasks":[],"children":[]}]}|}
  in
  match Tui_decode.decode_overview_goals json with
  | Error (Tui_decode.Overview_goal_phase_unknown { goal_id; phase }) ->
      check string "the refused goal" "goal-x" goal_id;
      check string "the refused phase" "hibernating" phase
  | Error other ->
      failf "refused for another reason: %s"
        (Tui_decode.overview_goals_error_to_string other)
  | Ok _ -> fail "an unknown phase decoded"

let test_explicit_measurement_requires_the_current_criterion () =
  let document revision =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"tree":[{"id":"goal-x","title":"x","phase":"executing","priority":1,
            "criterion_revision":"r2","metric":"passing checks","target_value":"5",
            "measurement":{"state":"reported","record":{"goal_id":"goal-x",
              "criterion_revision":"%s","observed_value":"3","evidence":"artifact:checks",
              "actor":"planner","recorded_at":"2026-09-24T00:00:00Z"}},
            "due_date":null,"task_count":0,"task_done_count":0,
            "stagnation_seconds":null,"tasks":[],"children":[]}]}|}
         revision)
  in
  (match Tui_decode.decode_overview_goals (document "r2") with
   | Ok [ { og_measurement = Tui_decode.Goal_measurement_reported { value; _ }; _ } ] ->
       check string "value is reported, not inferred" "3" value
   | Ok _ | Error _ -> fail "current explicit observation was not decoded");
  (match Tui_decode.decode_overview_goals (document "r1") with
   | Error (Tui_decode.Overview_goals_malformed _) -> ()
   | Ok _ | Error _ -> fail "stale criterion was accepted")

let () =
  run "tui_decode_overview_goals"
    [ ( "overview goals decoding"
      , [ test_case "a goal without children is refused" `Quick
            test_a_goal_without_children_is_refused
        ; test_case "an unknown phase is refused" `Quick
            test_an_unknown_phase_is_refused
        ; test_case "measurement is bound to the current criterion" `Quick
            test_explicit_measurement_requires_the_current_criterion
        ] )
    ]
