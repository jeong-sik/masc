open Alcotest

(* A reader of the status gets back the status that was written, and an
   object it did not write is an error rather than a guessed exit. *)
let test_process_status_round_trips () =
  let same a b =
    match a, b with
    | Unix.WEXITED x, Unix.WEXITED y
    | Unix.WSIGNALED x, Unix.WSIGNALED y
    | Unix.WSTOPPED x, Unix.WSTOPPED y -> x = y
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> false
  in
  List.iter
    (fun status ->
      match
        Masc.Exec_core.process_status_of_json
          (Masc.Exec_core.process_status_to_json status)
      with
      | Ok read -> check bool "the written status reads back" true (same status read)
      | Error detail -> fail detail)
    [ Unix.WEXITED 0; Unix.WEXITED 2; Unix.WSIGNALED Sys.sigkill; Unix.WSTOPPED Sys.sigstop ];
  List.iter
    (fun json ->
      check bool (Yojson.Safe.to_string json) true
        (Result.is_error (Masc.Exec_core.process_status_of_json json)))
    [ `Assoc [ "kind", `String "exit" ]
    ; `Assoc [ "kind", `String "exit"; "code", `String "0" ]
    ; `Assoc [ "kind", `String "vanished"; "code", `Int 0 ]
    ; `Assoc [ "code", `Int 0 ]
    ; `String "exit 0"
    ]
;;

let () =
  run
    "exec_core"
    [ ( "process_status"
      , [ test_case "process status round trips" `Quick test_process_status_round_trips ] )
    ]
;;
