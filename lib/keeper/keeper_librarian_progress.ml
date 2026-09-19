(* The Librarian's read position (RFC librarian-lifecycle §4.6). See the
   interface for the contract. *)

module W = Keeper_memory_os_types

let ( let* ) = Result.bind
let suffix = ".librarian-progress.json"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

type position =
  { trace_id : string
  ; end_atom : int
  ; last_atom_digest : string
  }

type t =
  { position : position
  ; boundary_lines_seen : int
  }

let field_trace_id = "trace_id"
let field_end_atom = "end_atom"
let field_last_atom_digest = "last_atom_digest"
let field_boundary_lines_seen = "boundary_lines_seen"

let fields =
  [ field_trace_id; field_end_atom; field_last_atom_digest; field_boundary_lines_seen ]
;;

let non_blank s = not (String.equal (String.trim s) "")

(* Shared by the decoder and [write], so a file this module wrote is a file
   this module reads back. *)
let validate (progress : t) =
  let { trace_id; end_atom; last_atom_digest } = progress.position in
  let* () =
    if non_blank trace_id
    then Ok ()
    else W.wire_fail [ W.Wire_field field_trace_id ] W.Blank_string
  in
  let* () =
    if end_atom >= 1
    then Ok ()
    else W.wire_fail [ W.Wire_field field_end_atom ] W.Not_positive
  in
  let* () =
    if non_blank last_atom_digest
    then Ok ()
    else W.wire_fail [ W.Wire_field field_last_atom_digest ] W.Blank_string
  in
  if progress.boundary_lines_seen >= 0
  then Ok progress
  else W.wire_fail [ W.Wire_field field_boundary_lines_seen ] W.Negative
;;

let to_json (progress : t) : Yojson.Safe.t =
  `Assoc
    [ field_trace_id, `String progress.position.trace_id
    ; field_end_atom, `Int progress.position.end_atom
    ; field_last_atom_digest, `String progress.position.last_atom_digest
    ; field_boundary_lines_seen, `Int progress.boundary_lines_seen
    ]
;;

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* trace_id = W.wire_string_field field_trace_id assoc in
    let* end_atom = W.wire_int_field field_end_atom assoc in
    let* last_atom_digest = W.wire_string_field field_last_atom_digest assoc in
    let* boundary_lines_seen = W.wire_int_field field_boundary_lines_seen assoc in
    validate
      { position = { trace_id; end_atom; last_atom_digest }; boundary_lines_seen }
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
    Printf.sprintf "librarian progress unreadable path=%s: %s" path message
  | Not_json { path; message } ->
    Printf.sprintf "librarian progress is not valid JSON path=%s: %s" path message
  | Malformed { path; error } ->
    Printf.sprintf
      "librarian progress rejected path=%s: %s"
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
    "librarian progress rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "librarian progress write failed path=%s: %s" path message
;;

let write ~keepers_dir ~keeper_id progress =
  match validate progress with
  | Error error -> Error (Invalid_progress error)
  | Ok progress ->
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let failed message = Error (Write_failed { path; message }) in
    (match
       Fs_compat.mkdir_p keepers_dir;
       Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string (to_json progress))
     with
     | Ok () -> Ok ()
     | Error message -> failed message
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception Sys_error message -> failed message
     | exception Unix.Unix_error (code, fn, arg) ->
       failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;
