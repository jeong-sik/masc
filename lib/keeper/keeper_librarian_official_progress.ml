(* The Librarian's position among official-client turns (RFC
   librarian-lifecycle §10-3). See the interface for the contract. *)

module W = Keeper_memory_os_types

let ( let* ) = Result.bind

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) "librarian-official-progress.json"
;;

type t = { boundary_line : int }

let field_boundary_line = "boundary_line"
let fields = [ field_boundary_line ]

(* Shared by the decoder and [write], so a file this module wrote is a file
   this module reads back. *)
let validate (progress : t) =
  if progress.boundary_line >= 1
  then Ok progress
  else W.wire_fail [ W.Wire_field field_boundary_line ] W.Not_positive
;;

let to_json (progress : t) : Yojson.Safe.t =
  `Assoc [ field_boundary_line, `Int progress.boundary_line ]
;;

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* boundary_line = W.wire_int_field field_boundary_line assoc in
    validate { boundary_line }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

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

let read_error_to_string = function
  | Unreadable { path; message } ->
    Printf.sprintf "librarian official progress unreadable path=%s: %s" path message
  | Not_json { path; message } ->
    Printf.sprintf "librarian official progress is not valid JSON path=%s: %s" path message
  | Malformed { path; error } ->
    Printf.sprintf
      "librarian official progress rejected path=%s: %s"
      path
      (W.wire_error_to_string error)
;;

let decode ~path content =
  match Yojson.Safe.from_string content with
  | json ->
    (match of_json json with
     | Ok progress -> Ok (Some progress)
     | Error error -> Error (Malformed { path; error }))
  | exception Yojson.Json_error message -> Error (Not_json { path; message })
;;

let read ~keepers_dir ~keeper_id =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some content -> decode ~path content
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Sys_error message -> Error (Unreadable { path; message })
  | exception Unix.Unix_error (code, fn, arg) ->
    Error
      (Unreadable
         { path; message = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code) })
;;

type write_error =
  | Invalid_progress of W.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

let write_error_to_string = function
  | Invalid_progress error ->
    "librarian official progress rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "librarian official progress write failed path=%s: %s" path message
;;

let write ~keepers_dir ~keeper_id progress =
  match validate progress with
  | Error error -> Error (Invalid_progress error)
  | Ok progress ->
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let failed message = Error (Write_failed { path; message }) in
    (match
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string (to_json progress))
     with
     | Ok () -> Ok ()
     | Error message -> failed message
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception Sys_error message -> failed message
     | exception Unix.Unix_error (code, fn, arg) ->
       failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;
