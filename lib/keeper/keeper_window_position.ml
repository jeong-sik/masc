(* Where a keeper's next request starts (RFC keeper-context-window-in-tokens
   §7 (라)). See the interface for the contract. *)

module W = Keeper_memory_os_types
module P = Keeper_librarian_progress

let ( let* ) = Result.bind

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) "window-position.json"
;;

type in_progress =
  | Absent_at_baseline
  | Nothing_in_progress
  | Stated of string

type t =
  { position : P.position
  ; in_progress : in_progress
  ; recorded_at : float
  }

let field_trace_id = "trace_id"
let field_end_atom = "end_atom"
let field_last_atom_digest = "last_atom_digest"
let field_in_progress = "in_progress"
let field_recorded_at = "recorded_at"
let field_kind = "kind"
let field_text = "text"

let fields =
  [ field_trace_id
  ; field_end_atom
  ; field_last_atom_digest
  ; field_in_progress
  ; field_recorded_at
  ]
;;

let kind_absent_at_baseline = "absent_at_baseline"
let kind_nothing_in_progress = "nothing_in_progress"
let kind_stated = "stated"
let bare_in_progress_fields = [ field_kind ]
let stated_fields = [ field_kind; field_text ]
let non_blank s = not (String.equal (String.trim s) "")

(* Shared by the decoder and [write], so a file this module wrote is a file
   this module reads back. *)
let validate (window : t) =
  let { P.trace_id; end_atom; last_atom_digest } = window.position in
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
  let* () =
    match window.in_progress with
    | Stated text when not (non_blank text) ->
      W.wire_fail [ W.Wire_field field_in_progress; W.Wire_field field_text ] W.Blank_string
    | Stated _ | Absent_at_baseline | Nothing_in_progress -> Ok ()
  in
  if Float.is_finite window.recorded_at && window.recorded_at >= 0.
  then Ok window
  else W.wire_fail [ W.Wire_field field_recorded_at ] W.Not_finite
;;

let in_progress_to_json = function
  | Absent_at_baseline -> `Assoc [ field_kind, `String kind_absent_at_baseline ]
  | Nothing_in_progress -> `Assoc [ field_kind, `String kind_nothing_in_progress ]
  | Stated text ->
    `Assoc [ field_kind, `String kind_stated; field_text, `String text ]
;;

let to_json (window : t) : Yojson.Safe.t =
  `Assoc
    [ field_trace_id, `String window.position.P.trace_id
    ; field_end_atom, `Int window.position.P.end_atom
    ; field_last_atom_digest, `String window.position.P.last_atom_digest
    ; field_in_progress, in_progress_to_json window.in_progress
    ; field_recorded_at, `Float window.recorded_at
    ]
;;

(* The kind names the fields it carries, so it is read first and the
   exact-fields check is made against that kind's set. *)
let in_progress_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* kind = W.wire_string_field field_kind assoc in
    if String.equal kind kind_absent_at_baseline
    then (
      let* () = W.exact_field_names_result bare_in_progress_fields assoc in
      Ok Absent_at_baseline)
    else if String.equal kind kind_nothing_in_progress
    then (
      let* () = W.exact_field_names_result bare_in_progress_fields assoc in
      Ok Nothing_in_progress)
    else if String.equal kind kind_stated
    then (
      let* () = W.exact_field_names_result stated_fields assoc in
      let* text = W.wire_string_field field_text assoc in
      Ok (Stated text))
    else W.wire_fail [ W.Wire_field field_kind ] (W.Unknown_token kind)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* trace_id = W.wire_string_field field_trace_id assoc in
    let* end_atom = W.wire_int_field field_end_atom assoc in
    let* last_atom_digest = W.wire_string_field field_last_atom_digest assoc in
    let* in_progress_json = W.wire_json_field field_in_progress assoc in
    let* in_progress =
      W.wire_at (W.Wire_field field_in_progress) (in_progress_of_json in_progress_json)
    in
    let* recorded_at = W.wire_number_field field_recorded_at assoc in
    validate
      { position = { P.trace_id; end_atom; last_atom_digest }; in_progress; recorded_at }
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
    Printf.sprintf "window position unreadable path=%s: %s" path message
  | Not_json { path; message } ->
    Printf.sprintf "window position is not valid JSON path=%s: %s" path message
  | Malformed { path; error } ->
    Printf.sprintf "window position rejected path=%s: %s" path (W.wire_error_to_string error)
;;

let decode ~path content =
  match Yojson.Safe.from_string content with
  | json ->
    (match of_json json with
     | Ok window -> Ok (Some window)
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
  | Invalid_position of W.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

let write_error_to_string = function
  | Invalid_position error -> "window position rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "window position write failed path=%s: %s" path message
;;

let write ~keepers_dir ~keeper_id window =
  match validate window with
  | Error error -> Error (Invalid_position error)
  | Ok window ->
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let failed message = Error (Write_failed { path; message }) in
    (match
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string (to_json window))
     with
     | Ok () -> Ok ()
     | Error message -> failed message
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception Sys_error message -> failed message
     | exception Unix.Unix_error (code, fn, arg) ->
       failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;

type view =
  | Absorbed of t
  | Empty_history
  | Absent
  | Outlived of
      { recorded : t
      ; reason : outlived
      }

and outlived =
  | Other_trace of string
  | Atom_missing of
      { end_atom : int
      ; atom_count : int
      }
  | Message_differs of
      { end_atom : int
      ; stored_digest : string
      ; history_digest : string option
      }

let view_of_history window ~trace_id ~digest_at ~atom_count =
  if atom_count = 0
  then Empty_history
  else (
    match window with
    | None -> Absent
    | Some ({ position; _ } as recorded) ->
      let outlived reason = Outlived { recorded; reason } in
      if not (String.equal position.P.trace_id trace_id)
      then outlived (Other_trace position.P.trace_id)
      else if position.P.end_atom > atom_count
      then outlived (Atom_missing { end_atom = position.P.end_atom; atom_count })
      else (
        (* The digest is the opening of the atom before the position: the last
           one the Librarian read. A rewrite that changed it renumbered the
           atoms after it too, so the position names different words now. *)
        let history_digest = digest_at (position.P.end_atom - 1) in
        match history_digest with
        | Some digest when String.equal digest position.P.last_atom_digest ->
          Absorbed recorded
        | Some _ | None ->
          outlived
            (Message_differs
               { end_atom = position.P.end_atom
               ; stored_digest = position.P.last_atom_digest
               ; history_digest
               })))
;;
