(** Tests for Keeper_recurring — in-memory recurring task registry. *)

open Alcotest
module Rec = Masc_mcp.Keeper_recurring

let check = Alcotest.check

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
        ] )
    ; ( "serialization"
      , [ test_case "task to json" `Quick test_task_to_json
        ; test_case "unique ids" `Quick test_generate_id_unique
        ] )
    ]
;;
