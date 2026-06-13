open Alcotest

(** Test Progress module *)

let captured_json = ref []

let mock_broadcast json =
  captured_json := json :: !captured_json

let setup () =
  captured_json := [];
  Masc.Progress.reset_for_testing ();
  Masc.Progress.set_sse_callback mock_broadcast

let test_notify_basic () =
  setup ();
  Masc.Progress.notify ~task_id:"test-task" ~progress:0.5 ();

  check int "one notification sent" 1 (List.length !captured_json);

  let json = List.hd !captured_json in
  let open Yojson.Safe.Util in
  check string "jsonrpc version" "2.0" (json |> member "jsonrpc" |> to_string);
  check string "method" "notifications/progress" (json |> member "method" |> to_string);

  let params = json |> member "params" in
  check string "taskId" "test-task" (params |> member "taskId" |> to_string);
  check bool "progress is 0.5" true (Float.equal 0.5 (params |> member "progress" |> to_float))

let test_notify_with_message () =
  setup ();
  Masc.Progress.notify ~task_id:"test-task" ~progress:0.75 ~message:"Processing..." ();

  let json = List.hd !captured_json in
  let params = Yojson.Safe.Util.member "params" json in
  check string "message included" "Processing..."
    (Yojson.Safe.Util.member "message" params |> Yojson.Safe.Util.to_string)

let test_tracker_create () =
  setup ();
  let tracker = Masc.Progress.Tracker.create ~task_id:"tracker-test" ~total_steps:10 () in
  check bool "initial progress is 0" true (Float.equal 0.0 tracker.current)

let test_tracker_step () =
  setup ();
  let tracker = Masc.Progress.Tracker.create ~task_id:"step-test" ~total_steps:4 () in

  Masc.Progress.Tracker.step tracker ();
  check bool "progress after 1 step" true (Float.equal 0.25 tracker.current);

  Masc.Progress.Tracker.step tracker ();
  check bool "progress after 2 steps" true (Float.equal 0.5 tracker.current);

  (* Should have sent 2 notifications *)
  check int "two notifications sent" 2 (List.length !captured_json)

let test_tracker_complete () =
  setup ();
  let tracker = Masc.Progress.Tracker.create ~task_id:"complete-test" () in

  Masc.Progress.Tracker.complete tracker ~message:"Done!" ();
  check bool "progress is 1.0" true (Float.equal 1.0 tracker.current);

  let json = List.hd !captured_json in
  let params = Yojson.Safe.Util.member "params" json in
  check bool "final progress is 1.0" true
    (Float.equal 1.0 (Yojson.Safe.Util.member "progress" params |> Yojson.Safe.Util.to_float))

let test_start_and_stop_tracking () =
  setup ();
  let _ = Masc.Progress.start_tracking ~task_id:"track-test" ~total_steps:10 () in
  check bool "tracker exists" true (Option.is_some (Masc.Progress.get_tracker "track-test"));

  Masc.Progress.stop_tracking "track-test";
  check bool "tracker removed" true (Option.is_none (Masc.Progress.get_tracker "track-test"))

(** Validation tests *)

let test_validate_task_id_empty () =
  setup ();
  match Masc.Progress.validate_task_id "" with
  | Error err ->
    check bool "error mentions empty" true
      (String.length (Masc.Progress.validation_error_to_string err) > 0)
  | Ok _ -> fail "empty task_id should fail"

let test_validate_task_id_too_long () =
  setup ();
  let long_id = String.make 300 'x' in
  match Masc.Progress.validate_task_id long_id with
  | Error err ->
    check bool "error mentions too long" true
      (String.length (Masc.Progress.validation_error_to_string err) > 0)
  | Ok _ -> fail "long task_id should fail"

let test_validate_task_id_invalid_chars () =
  setup ();
  match Masc.Progress.validate_task_id "task\x00id" with
  | Error err ->
    check bool "error mentions invalid" true
      (String.length (Masc.Progress.validation_error_to_string err) > 0)
  | Ok _ -> fail "task_id with null char should fail"

let test_validate_progress_out_of_range () =
  setup ();
  match Masc.Progress.validate_progress 1.5 with
  | Error err ->
    check bool "error mentions range" true
      (String.length (Masc.Progress.validation_error_to_string err) > 0)
  | Ok _ -> fail "progress > 1.0 should fail"

let test_validate_progress_negative () =
  setup ();
  match Masc.Progress.validate_progress (-0.5) with
  | Error err ->
    check bool "error mentions range" true
      (String.length (Masc.Progress.validation_error_to_string err) > 0)
  | Ok _ -> fail "negative progress should fail"

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "progress"
    [
      ("notify", [
        test_case "basic notification" `Quick test_notify_basic;
        test_case "with message" `Quick test_notify_with_message;
      ]);
      ("tracker", [
        test_case "create" `Quick test_tracker_create;
        test_case "step" `Quick test_tracker_step;
        test_case "complete" `Quick test_tracker_complete;
      ]);
      ("tracking", [
        test_case "start and stop" `Quick test_start_and_stop_tracking;
      ]);
      ("validation", [
        test_case "empty task_id" `Quick test_validate_task_id_empty;
        test_case "task_id too long" `Quick test_validate_task_id_too_long;
        test_case "task_id invalid chars" `Quick test_validate_task_id_invalid_chars;
        test_case "progress > 1.0" `Quick test_validate_progress_out_of_range;
        test_case "progress < 0.0" `Quick test_validate_progress_negative;
      ]);
    ]
