(** Tests for Keeper_recurring — in-memory recurring task registry. *)

open Alcotest
module Rec = Masc_mcp.Keeper_recurring

let check = Alcotest.check

let task_by_label label =
  List.find (fun (task : Rec.recurring_task) -> String.equal task.label label)
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

let test_failure_auto_disable () =
  Rec.clear ();
  let t =
    Rec.add
      ~keeper_name:"k1"
      ~label:"fail"
      ~interval_sec:30
      ~max_failures:2
      (Rec.Broadcast "oops")
  in
  (* Fail twice *)
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:100.0 ~dispatch:(fun _task _action ->
      Error "boom")
  in
  let tasks = Rec.list ~keeper_name:"k1" in
  let task = List.hd tasks in
  check int "failure 1" 1 task.failure_count;
  check bool "still enabled" true task.enabled;
  (* Need to set last_run_ts back to allow re-dispatch *)
  (* Actually, on failure we don't update last_run_ts, so it stays 0.0 *)
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:200.0 ~dispatch:(fun _task _action ->
      Error "boom again")
  in
  let tasks2 = Rec.list ~keeper_name:"k1" in
  let task2 = List.hd tasks2 in
  check int "failure 2" 2 task2.failure_count;
  check bool "auto-disabled" false task2.enabled;
  (* No more dispatches *)
  let count =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:300.0 ~dispatch:(fun _task _action ->
      Ok ())
  in
  check int "disabled no dispatch" 0 count;
  ignore t
;;

let test_reenable_after_cooldown () =
  Rec.clear ();
  let _t =
    Rec.add
      ~keeper_name:"k1"
      ~label:"fail"
      ~interval_sec:10
      ~max_failures:1
      (Rec.Broadcast "msg")
  in
  (* First failure -> auto-disabled (max_failures=1).
     last_run_ts stays 0.0 because dispatch_due does not update it on failure. *)
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:10.0 ~dispatch:(fun _t _a -> Error "boom")
  in
  let task = List.hd (Rec.list ~keeper_name:"k1") in
  check bool "auto-disabled" false task.enabled;
  check int "failure_count 1" 1 task.failure_count;
  (* Within cooldown window (2 * interval_sec = 20.0); now=15 < 0 + 20 -> no re-enable *)
  let n0 = Rec.reenable_due_tasks ~keeper_name:"k1" ~now_ts:15.0 in
  check int "within cooldown 0" 0 n0;
  let task1 = List.hd (Rec.list ~keeper_name:"k1") in
  check bool "still disabled" false task1.enabled;
  (* After cooldown; now=25 >= 0 + 20 -> re-enable, failure_count reset *)
  let n1 = Rec.reenable_due_tasks ~keeper_name:"k1" ~now_ts:25.0 in
  check int "after cooldown 1" 1 n1;
  let task2 = List.hd (Rec.list ~keeper_name:"k1") in
  check bool "re-enabled" true task2.enabled;
  check int "failure_count reset" 0 task2.failure_count;
  (* Idempotent: second call after re-enable returns 0 because task is enabled. *)
  let n2 = Rec.reenable_due_tasks ~keeper_name:"k1" ~now_ts:25.0 in
  check int "idempotent on enabled" 0 n2
;;

let test_reenable_filter_by_keeper () =
  Rec.clear ();
  let _t1 =
    Rec.add
      ~keeper_name:"k1"
      ~label:"a"
      ~interval_sec:10
      ~max_failures:1
      (Rec.Broadcast "a")
  in
  let _t2 =
    Rec.add
      ~keeper_name:"k2"
      ~label:"b"
      ~interval_sec:10
      ~max_failures:1
      (Rec.Broadcast "b")
  in
  (* Disable both *)
  let _ =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:10.0 ~dispatch:(fun _ _ -> Error "x")
  in
  let _ =
    Rec.dispatch_due ~keeper_name:"k2" ~now_ts:10.0 ~dispatch:(fun _ _ -> Error "x")
  in
  (* Re-enable only k1 *)
  let n = Rec.reenable_due_tasks ~keeper_name:"k1" ~now_ts:30.0 in
  check int "k1 re-enabled 1" 1 n;
  let k1 = List.hd (Rec.list ~keeper_name:"k1") in
  let k2 = List.hd (Rec.list ~keeper_name:"k2") in
  check bool "k1 enabled" true k1.enabled;
  check bool "k2 still disabled" false k2.enabled
;;

let test_failure_does_not_update_last_run_ts () =
  Rec.clear ();
  let _t =
    Rec.add
      ~keeper_name:"k1"
      ~label:"fail"
      ~interval_sec:10
      ~max_failures:2
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

let test_reenabled_multiple_tasks_preserve_partial_failure () =
  Rec.clear ();
  let _a =
    Rec.add
      ~keeper_name:"k1"
      ~label:"task-a"
      ~interval_sec:10
      ~max_failures:2
      (Rec.Broadcast "a")
  in
  let _b =
    Rec.add
      ~keeper_name:"k1"
      ~label:"task-b"
      ~interval_sec:10
      ~max_failures:2
      (Rec.Broadcast "b")
  in
  let fail_all _task _action = Error "initial failure" in
  let _ = Rec.dispatch_due ~keeper_name:"k1" ~now_ts:10.0 ~dispatch:fail_all in
  let _ = Rec.dispatch_due ~keeper_name:"k1" ~now_ts:11.0 ~dispatch:fail_all in
  let disabled = Rec.list ~keeper_name:"k1" in
  check int "two disabled tasks" 2 (List.length disabled);
  List.iter
    (fun (task : Rec.recurring_task) ->
       check bool (task.label ^ " disabled") false task.enabled;
       check int (task.label ^ " failure_count") 2 task.failure_count)
    disabled;
  let n = Rec.reenable_due_tasks ~keeper_name:"k1" ~now_ts:25.0 in
  check int "two re-enabled" 2 n;
  let successes =
    Rec.dispatch_due ~keeper_name:"k1" ~now_ts:25.0 ~dispatch:(fun task _action ->
      if String.equal task.label "task-a" then Error "task-a failed again" else Ok ())
  in
  check int "one successful dispatch" 1 successes;
  let tasks = Rec.list ~keeper_name:"k1" in
  let task_a = task_by_label "task-a" tasks in
  let task_b = task_by_label "task-b" tasks in
  check int "task-a failure_count after partial failure" 1 task_a.failure_count;
  check bool "task-a remains enabled below max failures" true task_a.enabled;
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
        ] )
    ; ( "dispatch"
      , [ test_case "due tasks" `Quick test_dispatch_due
        ; test_case "failure auto-disable" `Quick test_failure_auto_disable
        ; test_case "reenable after cooldown" `Quick test_reenable_after_cooldown
        ; test_case "reenable filter by keeper" `Quick test_reenable_filter_by_keeper
        ; test_case
            "failure preserves last_run_ts"
            `Quick
            test_failure_does_not_update_last_run_ts
        ; test_case
            "reenable multi-task partial failure"
            `Quick
            test_reenabled_multiple_tasks_preserve_partial_failure
        ] )
    ; ( "serialization"
      , [ test_case "task to json" `Quick test_task_to_json
        ; test_case "unique ids" `Quick test_generate_id_unique
        ] )
    ]
;;
