(* A Keeper turn in its turn log (RFC librarian-call-only-proposes §5.2):
   [Keeper_turn_log_turn.around] writes the turn's [Opened] and, on every way
   out, its [Closed]. Histories are written by the checkpoint store's own
   save and the log is read back from its file. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Turn = Masc.Keeper_turn_log_turn

let mentions text part =
  let length = String.length part in
  let rec from at =
    at + length <= String.length text
    && (String.equal (String.sub text at length) part || from (at + 1))
  in
  from 0
;;

let test_the_task_of_a_turn () =
  let task_id =
    match Keeper_id.Task_id.of_string "task-7" with
    | Ok id -> id
    | Error reason -> fail reason
  in
  let goal : Masc.Keeper_turn_task_context.goal =
    { goal_id = "goal-1"
    ; phase = Goal_phase.Executing
    ; criterion =
        Goal_store.Criterion
          { revision = "r1"
          ; title = "Retain every input"
          ; measure = Goal_measure_fixture.done_when "all"
          ; procedure = "read the file"
          }
    }
  in
  check bool "no Task" true (Turn.task_evidence No_task = Log.No_task);
  check bool "a Task source that was not read" true
    (Turn.task_evidence (Task_source_unavailable "the board is down") = Log.Task_source_unavailable);
  (match Turn.task_evidence (Task { task_id; goals = Ok [ goal ] }) with
   | Task { task; goals = Some [ shown ] } ->
     check bool "the Task" true (Keeper_id.Task_id.equal task task_id);
     check string "the Goal" "goal-1" shown.goal;
     check string "its phase and criterion, as the Goal's own encoders write them"
       (Yojson.Safe.to_string
          (`Assoc
              [ "phase", Goal_phase.to_yojson goal.phase
              ; "criterion", Goal_store.criterion_to_yojson goal.criterion
              ]))
       shown.shown;
     check bool "the text names the criterion" true (mentions shown.shown "Retain every input")
   | _ -> fail "a Task with one Goal was not kept as one");
  match Turn.task_evidence (Task { task_id; goals = Error (Goal_links_unavailable "no index") }) with
  | Task { goals = None; _ } -> ()
  | _ -> fail "Goals that were not read are not kept as unread"
;;

let () =
  run "keeper_turn_log_turn_task_context"
    [ ( "values"
      , [ test_case "the Task of a turn" `Quick test_the_task_of_a_turn
        ] )
    ]
;;
