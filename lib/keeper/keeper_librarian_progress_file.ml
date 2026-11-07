(* The file both Librarian progress stores share. See the interface for the
   contract. *)

module W = Keeper_memory_os_types

type read_error =
  | Unreadable of
      { path : string
      ; message : string
      }
  | Not_json of
      { path : string
      ; message : string
      }
  | Malformed of
      { path : string
      ; error : W.wire_error
      }

type write_error =
  | Invalid_progress of W.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

let read_error_to_string ~subject = function
  | Unreadable { path; message } ->
    Printf.sprintf "%s unreadable path=%s: %s" subject path message
  | Not_json { path; message } ->
    Printf.sprintf "%s is not valid JSON path=%s: %s" subject path message
  | Malformed { path; error } ->
    Printf.sprintf
      "%s rejected path=%s: %s"
      subject
      path
      (W.wire_error_to_string error)
;;

let write_error_to_string ~subject = function
  | Invalid_progress error -> subject ^ " rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "%s write failed path=%s: %s" subject path message
;;

let unix_failure code fn arg =
  Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
;;

let decode ~path ~of_json content =
  match Yojson.Safe.from_string content with
  | json ->
    (match of_json json with
     | Ok value -> Ok (Some value)
     | Error error -> Error (Malformed { path; error }))
  | exception Yojson.Json_error message -> Error (Not_json { path; message })
;;

let read ~path ~of_json =
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some content -> decode ~path ~of_json content
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Sys_error message -> Error (Unreadable { path; message })
  | exception Unix.Unix_error (code, fn, arg) ->
    Error (Unreadable { path; message = unix_failure code fn arg })
;;

let write ~path ~validate ~to_json value =
  match validate value with
  | Error error -> Error (Invalid_progress error)
  | Ok value ->
    let failed message = Error (Write_failed { path; message }) in
    (match
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string (to_json value))
     with
     | Ok () -> Ok ()
     | Error message -> failed message
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception Sys_error message -> failed message
     | exception Unix.Unix_error (code, fn, arg) -> failed (unix_failure code fn arg))
;;
