let process_status_to_json = function
  | Unix.WEXITED code -> `Assoc [ "kind", `String "exit"; "code", `Int code ]
  | Unix.WSIGNALED signal ->
    `Assoc [ "kind", `String "signal"; "signal", `Int signal ]
  | Unix.WSTOPPED signal ->
    `Assoc [ "kind", `String "stopped"; "signal", `Int signal ]
;;

let process_status_is_success = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
;;

let process_result_json ?(extra = []) ~status ~output () =
  `Assoc
    ([ "ok", `Bool (process_status_is_success status)
     ; "status", process_status_to_json status
     ; "output", `String output
     ]
     @ extra)
;;
