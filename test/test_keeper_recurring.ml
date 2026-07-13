(** Tests for Keeper_recurring — in-memory recurring task registry. *)

open Alcotest
module Rec = Masc.Keeper_recurring
module Rec_tool = Masc.Keeper_recurring_tool
module J = Yojson.Safe.Util

let check = Alcotest.check

let task_by_label label =
  List.find (fun (task : Rec.recurring_task) -> String.equal task.label label)
;;

let dispatch_tool ~agent_name ~name ~args =
  match Rec_tool.dispatch ~agent_name ~name ~args with
  | Some result -> result
  | None -> fail (Printf.sprintf "%s returned None" name)
;;

let check_tool_success label result =
  check bool label true (Tool_result.is_success result)
;;

let check_tool_failure label result =
  check bool label false (Tool_result.is_success result)
;;

let test_add_and_list () =
  Rec.clear ();
  let _t =
    Rec.add ~keeper_name:"k1" ~label:"status" ~interval_sec:60 (Rec.Broadcast "hello")
  in
  let tasks = Rec.list ~keeper_name:"k1" in
  check int "1 task" 1 (List.length tasks);
  let t = List.hd tasks in
  check string "label" "status" t.label;
  check int "interval" 60 t.interval_sec;
  check bool "enabled" true t.enabled;
  check int "run_count" 0 t.run_count
;;

let test_list_filters_by_keeper () =
  Rec.clear ();
  let _t1 = Rec.add ~keeper_name:"k1" ~label:"a" ~interval_sec:60 (Rec.Broadcast "a") in
  let _t2 = Rec.add ~keeper_name:"k2" ~label:"b" ~interval_sec:60 (Rec.Broadcast "b") in
  check int "k1 tasks" 1 (List.length (Rec.list ~keeper_name:"k1"));
  check int "k2 tasks" 1 (List.length (Rec.list ~keeper_name:"k2"));
  check int "all tasks" 2 (List.length (Rec.list_all ()))
;;

let test_remove () =
  Rec.clear ();
  let t = Rec.add ~keeper_name:"k1" ~label:"x" ~interval_sec:60 (Rec.Broadcast "x") in
  check bool "remove existing" true (Rec.remove ~id:t.id);
  check bool "remove again" false (Rec.remove ~id:t.id);
  check int "empty" 0 (List.length (Rec.list ~keeper_name:"k1"))
;;

let test_tool_dispatch_contract () =
  Rec.clear ();
  let add_result =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_add"
      ~args:(`Assoc [ "label", `String "heartbeat"; "interval_sec", `Int 30 ])
  in
  check_tool_success "add succeeds" add_result;
  let add_data = Tool_result.data add_result in
  let task_id = add_data |> J.member "id" |> J.to_string in
  check string "add label" "heartbeat" (add_data |> J.member "label" |> J.to_string);
  check int "add interval" 30 (add_data |> J.member "interval_sec" |> J.to_int);
  check int "registered one task" 1 (List.length (Rec.list ~keeper_name:"keeper-a"));
  let duplicate_result =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_add"
      ~args:(`Assoc [ "label", `String "heartbeat"; "interval_sec", `Int 30 ])
  in
  check_tool_failure "duplicate fails" duplicate_result;
  check int "duplicate not added" 1 (List.length (Rec.list ~keeper_name:"keeper-a"));
  let list_result =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_list"
      ~args:(`Assoc [])
  in
  check_tool_success "list succeeds" list_result;
  let tasks = list_result |> Tool_result.data |> J.member "tasks" |> J.to_list in
  check int "list returns one task" 1 (List.length tasks);
  let foreign_add =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_add"
      ~args:
        (`Assoc
          [
            "keeper_name", `String "keeper-b";
            "label", `String "foreign-write";
            "interval_sec", `Int 30;
          ])
  in
  check_tool_failure "foreign add override fails" foreign_add;
  check int "foreign add writes no caller task" 1 (List.length (Rec.list ~keeper_name:"keeper-a"));
  check int "foreign add writes no target task" 0 (List.length (Rec.list ~keeper_name:"keeper-b"));
  let other_task =
    Rec.add
      ~keeper_name:"keeper-b"
      ~label:"foreign"
      ~interval_sec:60
      (Rec.Broadcast "foreign")
  in
  let foreign_list =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_list"
      ~args:(`Assoc [ "keeper_name", `String "keeper-b" ])
  in
  check_tool_failure "foreign list override fails" foreign_list;
  let foreign_remove =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_remove"
      ~args:(`Assoc [ "id", `String other_task.id ])
  in
  check_tool_failure "foreign remove fails" foreign_remove;
  check int "foreign task kept" 1 (List.length (Rec.list ~keeper_name:"keeper-b"));
  let remove_result =
    dispatch_tool
      ~agent_name:"keeper-a"
      ~name:"masc_recurring_remove"
      ~args:(`Assoc [ "id", `String task_id ])
  in
  check_tool_success "remove succeeds" remove_result;
  check int "own task removed" 0 (List.length (Rec.list ~keeper_name:"keeper-a"))
;;

let test_dispatch_due () =
  Rec.clear ();
  let _t =
    Rec.add ~keeper_name:"k1" ~label:"tick" ~interval_sec:60 (Rec.Broadcast "tick msg")
  in
  (* Not due yet at t=30 *)
  let dispatched_early =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:30.0 ~dispatch:(fun _task _action -> Ok ())
  in
  check int "too early" 0 dispatched_early;
  (* Due at t=100 (100 - 0 = 100 >= 60) *)
  let dispatched = ref 0 in
  let count =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:100.0 ~dispatch:(fun _task action ->
      (match action with
       | Rec.Broadcast msg -> check string "broadcast msg" "tick msg" msg);
      incr dispatched;
      Ok ())
  in
  check int "dispatched 1" 1 count;
  check int "callback called" 1 !dispatched;
  (* Not due again immediately *)
  let count2 =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:110.0 ~dispatch:(fun _task _action ->
      Ok ())
  in
  check int "not due yet" 0 count2;
  (* Due again after interval *)
  let count3 =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:200.0 ~dispatch:(fun _task _action ->
      Ok ())
  in
  check int "due again" 1 count3
;;

let test_failure_never_disables () =
  Rec.clear ();
  let _t =
    Rec.add
      ~keeper_name:"k1"
      ~label:"fail"
      ~interval_sec:30
      (Rec.Broadcast "oops")
  in
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:100.0 ~dispatch:(fun _task _action ->
      Error "boom")
  in
  let tasks = Rec.list ~keeper_name:"k1" in
  let task = List.hd tasks in
  check int "failure 1" 1 task.failure_count;
  check bool "still enabled" true task.enabled;
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:200.0 ~dispatch:(fun _task _action ->
      Error "boom again")
  in
  let tasks2 = Rec.list ~keeper_name:"k1" in
  let task2 = List.hd tasks2 in
  check int "failure 2" 2 task2.failure_count;
  check bool "still enabled after repeated failures" true task2.enabled;
  let count =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:300.0 ~dispatch:(fun _task _action ->
      Ok ())
  in
  check int "later dispatch still runs" 1 count
;;

let test_failure_does_not_update_last_run_ts () =
  Rec.clear ();
  let _t =
    Rec.add
      ~keeper_name:"k1"
      ~label:"fail"
      ~interval_sec:10
      (Rec.Broadcast "msg")
  in
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:10.0 ~dispatch:(fun _ _ ->
      Error "transient")
  in
  let task = List.hd (Rec.list ~keeper_name:"k1") in
  check int "failure_count" 1 task.failure_count;
  check (float 0.001) "last_run_ts unchanged" 0.0 task.last_run_ts;
  check bool "still enabled" true task.enabled
;;

let test_multiple_tasks_preserve_partial_failure () =
  Rec.clear ();
  let _a =
    Rec.add
      ~keeper_name:"k1"
      ~label:"task-a"
      ~interval_sec:10
      (Rec.Broadcast "a")
  in
  let _b =
    Rec.add
      ~keeper_name:"k1"
      ~label:"task-b"
      ~interval_sec:10
      (Rec.Broadcast "b")
  in
  let fail_all _task _action = Error "initial failure" in
  let _ = Rec.dispatch_due ~keeper_name:"k1" ~now_ts:10.0 ~dispatch:fail_all in
  let _ = Rec.dispatch_due ~keeper_name:"k1" ~now_ts:11.0 ~dispatch:fail_all in
  let failed = Rec.list ~keeper_name:"k1" in
  check int "two failed tasks" 2 (List.length failed);
  List.iter
    (fun (task : Rec.recurring_task) ->
       check bool (task.label ^ " remains enabled") true task.enabled;
       check int (task.label ^ " failure_count") 2 task.failure_count)
    failed;
  let successes =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:25.0 ~dispatch:(fun task _action ->
      if String.equal task.label "task-a" then Error "task-a failed again" else Ok ())
  in
  check int "one successful dispatch" 1 successes;
  let tasks = Rec.list ~keeper_name:"k1" in
  let task_a = task_by_label "task-a" tasks in
  let task_b = task_by_label "task-b" tasks in
  check int "task-a failure_count after partial failure" 3 task_a.failure_count;
  check bool "task-a remains enabled" true task_a.enabled;
  check (float 0.001) "task-a last_run_ts still old" 0.0 task_a.last_run_ts;
  check int "task-b failure_count reset" 0 task_b.failure_count;
  check bool "task-b remains enabled" true task_b.enabled;
  check int "task-b run_count" 1 task_b.run_count;
  check (float 0.001) "task-b last_run_ts updated" 25.0 task_b.last_run_ts
;;

let test_task_to_json () =
  Rec.clear ();
  let t =
    Rec.add
      ~keeper_name:"k1"
      ~label:"json test"
      ~interval_sec:120
      (Rec.Broadcast "test msg")
  in
  let json = Rec.task_to_json t in
  let open Yojson.Safe.Util in
  check string "id" t.id (json |> member "id" |> to_string);
  check string "keeper" "k1" (json |> member "keeper_name" |> to_string);
  check int "interval" 120 (json |> member "interval_sec" |> to_int);
  check bool "enabled" true (json |> member "enabled" |> to_bool)
;;

let test_generate_id_unique () =
  let id1 = Rec.generate_id () in
  let id2 = Rec.generate_id () in
  check bool "unique ids" true (id1 <> id2)
;;

let () =
  run
    "keeper_recurring"
    [ ( "crud"
	      , [ test_case "add and list" `Quick test_add_and_list
	        ; test_case "filter by keeper" `Quick test_list_filters_by_keeper
	        ; test_case "remove" `Quick test_remove
	        ; test_case "tool dispatch contract" `Quick test_tool_dispatch_contract
	        ] )
    ; ( "dispatch"
      , [ test_case "due tasks" `Quick test_dispatch_due
        ; test_case "failure never disables" `Quick test_failure_never_disables
        ; test_case
            "failure preserves last_run_ts"
            `Quick
            test_failure_does_not_update_last_run_ts
        ; test_case
            "multi-task partial failure"
            `Quick
            test_multiple_tasks_preserve_partial_failure
        ] )
    ; ( "serialization"
      , [ test_case "task to json" `Quick test_task_to_json
        ; test_case "unique ids" `Quick test_generate_id_unique
        ] )
    ]
;;
