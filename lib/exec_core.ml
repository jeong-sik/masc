let process_status_to_json = function
  | Unix.WEXITED code -> `Assoc [ "kind", `String "exit"; "code", `Int code ]
  | Unix.WSIGNALED signal ->
    `Assoc [ "kind", `String "signal"; "signal", `Int signal ]
  | Unix.WSTOPPED signal ->
    `Assoc [ "kind", `String "stopped"; "signal", `Int signal ]
;;

(* The inverse of [process_status_to_json], owned here so the wire shape has
   one author. A member missing, of the wrong type, or a kind this does not
   write is an error naming it, not a guessed status. *)
let process_status_of_json = function
  | `Assoc fields ->
    let int_member name =
      match List.assoc_opt name fields with
      | Some (`Int value) -> Ok value
      | Some _ | None -> Error (Printf.sprintf "process status: %s is not an integer" name)
    in
    (match List.assoc_opt "kind" fields with
     | Some (`String "exit") -> Result.map (fun code -> Unix.WEXITED code) (int_member "code")
     | Some (`String "signal") ->
       Result.map (fun signal -> Unix.WSIGNALED signal) (int_member "signal")
     | Some (`String "stopped") ->
       Result.map (fun signal -> Unix.WSTOPPED signal) (int_member "signal")
     | Some (`String kind) -> Error (Printf.sprintf "process status: unknown kind %S" kind)
     | Some _ | None -> Error "process status: kind is not a string")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "process status: not an object"
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
