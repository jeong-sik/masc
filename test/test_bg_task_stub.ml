(* Tick 4 smoke tests — verify the Bg_task signatures compile and the
   stub returns structured errors. Real lifecycle tests land in Tick 5
   together with the pgid/ring-buffer implementation. *)

open Alcotest

let test_task_id_roundtrip () =
  let tid = Bg_task.task_id_of_string_exn "abc-123" in
  check string "roundtrip" "abc-123" (Bg_task.task_id_to_string tid)

let test_task_id_empty_rejected () =
  match Bg_task.task_id_of_string_exn "" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "empty id must raise"

let test_list_empty_for_unknown_keeper () =
  let ids = Bg_task.list ~keeper:"no-such-keeper" in
  check int "empty list" 0 (List.length ids)

let test_read_stub_errors () =
  let tid = Bg_task.task_id_of_string_exn "stub" in
  match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
  | Error (Bg_task.Read_failed msg) ->
      check bool "stub message mentions Tick 5" true
        (String.length msg > 0)
  | _ -> fail "stub read must return Read_failed"

let test_kill_stub_errors () =
  let tid = Bg_task.task_id_of_string_exn "stub" in
  match Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:1.0 with
  | Error (Bg_task.Kill_failed _) -> ()
  | _ -> fail "stub kill must return Kill_failed"

let test_reap_orphans_returns_zero () =
  check int "no orphans at boot" 0
    (Bg_task.reap_orphans ~base_path:"/tmp/no-such-base")

let () =
  run "bg_task_stub"
    [
      ( "signatures",
        [
          test_case "task_id roundtrip" `Quick test_task_id_roundtrip;
          test_case "empty task_id rejected" `Quick
            test_task_id_empty_rejected;
          test_case "list on unknown keeper is empty" `Quick
            test_list_empty_for_unknown_keeper;
          test_case "stub read returns Read_failed" `Quick
            test_read_stub_errors;
          test_case "stub kill returns Kill_failed" `Quick
            test_kill_stub_errors;
          test_case "reap_orphans returns 0 pre-impl" `Quick
            test_reap_orphans_returns_zero;
        ] );
    ]
