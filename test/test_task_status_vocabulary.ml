(** The task schema advertises statuses accepted by the runtime parser. *)

open Alcotest
module D = Masc_domain

let test_every_advertised_status_is_recognised () =
  List.iter
    (fun status ->
      let probe = `Assoc [ ("status", `String status) ] in
      match D.task_status_of_yojson probe with
      | Ok _ -> ()
      | Error message ->
        check bool
          (Printf.sprintf "%S is a status the parser knows (%s)" status message)
          false
          (String.length message >= 19 && String.sub message 0 19 = "Unknown task status"))
    D.valid_task_status_strings
;;

let () =
  Alcotest.run "Task status vocabulary"
    [ "agreement", [ test_case "every advertised status is recognised" `Quick
        test_every_advertised_status_is_recognised ] ]
;;
