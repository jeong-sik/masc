(** Task statuses advertised to callers survive the runtime JSON boundary. *)

open Alcotest
module D = Masc_domain

let test_advertised_statuses_roundtrip () =
  List.iter
    (fun status ->
      let timestamp = "2026-10-04T00:00:00Z" in
      let probe =
        `Assoc
          [ "status", `String status
          ; "assignee", `String "keeper"
          ; "claimed_at", `String timestamp
          ; "started_at", `String timestamp
          ; "submitted_at", `String timestamp
          ; "verification_id", `String "verification-1"
          ; "completed_at", `String timestamp
          ; "cancelled_by", `String "keeper"
          ; "cancelled_at", `String timestamp
          ]
      in
      match D.task_status_of_yojson probe with
      | Ok parsed ->
        check string "parser preserves the advertised status" status
          (D.task_status_to_string parsed);
        (match D.task_status_of_yojson (D.task_status_to_yojson parsed) with
         | Ok reparsed ->
           check (testable D.pp_task_status ( = )) "status payload roundtrip"
             parsed reparsed
         | Error message -> failf "serialized %S was rejected: %s" status message)
      | Error message ->
        failf "advertised status %S was rejected: %s" status message)
    D.valid_task_status_strings
;;

let test_unknown_status_is_rejected () =
  match D.task_status_of_yojson (`Assoc [ "status", `String "unknown-status" ]) with
  | Error _ -> ()
  | Ok status -> failf "unknown status was parsed as %s" (D.task_status_to_string status)
;;

let () =
  Alcotest.run "Task status vocabulary"
    [ "JSON boundary",
      [ test_case "advertised statuses roundtrip" `Quick
          test_advertised_statuses_roundtrip
      ; test_case "unknown status is rejected" `Quick test_unknown_status_is_rejected
      ]
    ]
;;
