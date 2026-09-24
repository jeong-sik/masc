(* Turn boundary records (RFC librarian-lifecycle §4.6). See the interface for
   the contract. *)

module W = Keeper_memory_os_types
module Window = Runtime_model_input_tail_window

let ( let* ) = Result.bind
let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) "turn-boundaries.jsonl"
;;

type position =
  | Atom_history of
      { end_atom : int
      ; last_atom_digest : string
      }
  | Empty_atom_history
  | No_atom_history
  | Stale_noop

type history_at_start =
  | Fresh_history
  | Continued_history
  | Continued_history_from of
      { start_atom : int
      ; start_atom_digest : string
      }

type event =
  | Turn_ended of
      { turn_ref : Ids.Turn_ref.t
      ; history_at_start : history_at_start
      ; position : position
      }
  | History_restarted of { trace_id : string }

type record =
  { recorded_at : float
  ; event : event
  }

let history_at_start_of_messages messages =
  let _labelled, atom_count = Window.annotate messages in
  match atom_count with
  | 0 -> Fresh_history
  | start_atom ->
    (* The start state is the position the turn began from, so a later line can
       answer what an unreadable line before it was (RFC librarian-lifecycle
       §4.6, masc#37061). The digest is the same one [position_of_messages]
       takes; when the opening message is missing it is left out and the branch
       degrades to the bare [Continued_history], which a reader does not treat
       as a start state. *)
    (match Window.atom_opening_digest messages (start_atom - 1) with
     | Some start_atom_digest -> Continued_history_from { start_atom; start_atom_digest }
     | None -> Continued_history)
;;

let position_of_messages messages =
  let _labelled, atom_count = Window.annotate messages in
  match atom_count with
  | 0 -> Ok Empty_atom_history
  | end_atom ->
    let last_atom = end_atom - 1 in
    (match Window.atom_opening_digest messages last_atom with
     | Some last_atom_digest -> Ok (Atom_history { end_atom; last_atom_digest })
     | None ->
       Error
         (Printf.sprintf
            "history counts %d atoms but has no opening message for atom %d"
            end_atom
            last_atom))
;;

let field_kind = "kind"
let field_recorded_at = "recorded_at"
let field_turn_ref = "turn_ref"
let field_history_at_start = "history_at_start"
let field_position = "position"
let field_end_atom = "end_atom"
let field_last_atom_digest = "last_atom_digest"
let field_start_atom = "start_atom"
let field_start_atom_digest = "start_atom_digest"
let field_trace_id = "trace_id"
let kind_turn_ended = "turn_ended"
let kind_history_restarted = "history_restarted"
let kind_atom_history = "atom_history"
let kind_empty_atom_history = "empty_atom_history"
let kind_no_atom_history = "no_atom_history"
let kind_stale_noop = "stale_noop"
let kind_continued_from = "continued_from"
let token_fresh_history = "fresh"
let token_continued_history = "continued"

let turn_ended_fields =
  [ field_kind; field_recorded_at; field_turn_ref; field_history_at_start; field_position ]
;;

let history_restarted_fields = [ field_kind; field_recorded_at; field_trace_id ]
let atom_history_fields = [ field_kind; field_end_atom; field_last_atom_digest ]
let continued_from_fields = [ field_kind; field_start_atom; field_start_atom_digest ]
let bare_position_fields = [ field_kind ]
let non_blank s = not (String.equal (String.trim s) "")

let validate_position = function
  | Atom_history { end_atom; last_atom_digest } ->
    let* () =
      if end_atom >= 1
      then Ok ()
      else W.wire_fail [ W.Wire_field field_end_atom ] W.Not_positive
    in
    if non_blank last_atom_digest
    then Ok ()
    else W.wire_fail [ W.Wire_field field_last_atom_digest ] W.Blank_string
  | Empty_atom_history | No_atom_history | Stale_noop -> Ok ()
;;

let validate_history_at_start = function
  | Fresh_history | Continued_history -> Ok ()
  | Continued_history_from { start_atom; start_atom_digest } ->
    let* () =
      if start_atom >= 1
      then Ok ()
      else W.wire_fail [ W.Wire_field field_start_atom ] W.Not_positive
    in
    if non_blank start_atom_digest
    then Ok ()
    else W.wire_fail [ W.Wire_field field_start_atom_digest ] W.Blank_string
;;

(* Shared by the decoder and [append], so a row this module wrote is a row this
   module reads back. [Ids.Turn_ref.make] takes any trace id while
   [Ids.Turn_ref.of_string] refuses an empty one, so the reference is checked
   through the same round trip a reader makes. *)
let validate (r : record) =
  let* () =
    if Float.is_finite r.recorded_at
    then Ok ()
    else W.wire_fail [ W.Wire_field field_recorded_at ] W.Not_finite
  in
  match r.event with
  | Turn_ended { turn_ref; history_at_start; position } ->
    let* () =
      let printed = Ids.Turn_ref.to_string turn_ref in
      match Ids.Turn_ref.of_string printed with
      | Some read_back when Ids.Turn_ref.equal read_back turn_ref -> Ok ()
      | Some _ | None ->
        W.wire_fail [ W.Wire_field field_turn_ref ] (W.Not_a_turn_ref printed)
    in
    let* () =
      W.wire_at
        (W.Wire_field field_history_at_start)
        (validate_history_at_start history_at_start)
    in
    let* () = W.wire_at (W.Wire_field field_position) (validate_position position) in
    Ok r
  | History_restarted { trace_id } ->
    if non_blank trace_id
    then Ok r
    else W.wire_fail [ W.Wire_field field_trace_id ] W.Blank_string
;;

let position_to_json = function
  | Atom_history { end_atom; last_atom_digest } ->
    `Assoc
      [ field_kind, `String kind_atom_history
      ; field_end_atom, `Int end_atom
      ; field_last_atom_digest, `String last_atom_digest
      ]
  | Empty_atom_history -> `Assoc [ field_kind, `String kind_empty_atom_history ]
  | No_atom_history -> `Assoc [ field_kind, `String kind_no_atom_history ]
  | Stale_noop -> `Assoc [ field_kind, `String kind_stale_noop ]
;;

let history_at_start_to_json = function
  | Fresh_history -> `String token_fresh_history
  | Continued_history -> `String token_continued_history
  | Continued_history_from { start_atom; start_atom_digest } ->
    `Assoc
      [ field_kind, `String kind_continued_from
      ; field_start_atom, `Int start_atom
      ; field_start_atom_digest, `String start_atom_digest
      ]
;;

let record_to_json (r : record) =
  match r.event with
  | Turn_ended { turn_ref; history_at_start; position } ->
    `Assoc
      [ field_kind, `String kind_turn_ended
      ; field_recorded_at, `Float r.recorded_at
      ; field_turn_ref, `String (Ids.Turn_ref.to_string turn_ref)
      ; field_history_at_start, history_at_start_to_json history_at_start
      ; field_position, position_to_json position
      ]
  | History_restarted { trace_id } ->
    `Assoc
      [ field_kind, `String kind_history_restarted
      ; field_recorded_at, `Float r.recorded_at
      ; field_trace_id, `String trace_id
      ]
;;

(* The kind names the fields the object carries, so it is read first and the
   exact-fields check is made against that kind's set. *)
let position_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* kind = W.wire_string_field field_kind assoc in
    if String.equal kind kind_atom_history
    then (
      let* () = W.exact_field_names_result atom_history_fields assoc in
      let* end_atom = W.wire_int_field field_end_atom assoc in
      let* last_atom_digest = W.wire_string_field field_last_atom_digest assoc in
      Ok (Atom_history { end_atom; last_atom_digest }))
    else if String.equal kind kind_empty_atom_history
    then (
      let* () = W.exact_field_names_result bare_position_fields assoc in
      Ok Empty_atom_history)
    else if String.equal kind kind_no_atom_history
    then (
      let* () = W.exact_field_names_result bare_position_fields assoc in
      Ok No_atom_history)
    else if String.equal kind kind_stale_noop
    then (
      let* () = W.exact_field_names_result bare_position_fields assoc in
      Ok Stale_noop)
    else W.wire_fail [ W.Wire_field field_kind ] (W.Unknown_token kind)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

let history_at_start_of_string token =
  if String.equal token token_fresh_history
  then Ok Fresh_history
  else if String.equal token token_continued_history
  then Ok Continued_history
  else W.wire_fail [ W.Wire_field field_history_at_start ] (W.Unknown_token token)
;;

(* A start state is an object; the two bare tokens stay strings, so a line
   written before this branch existed still decodes. *)
let history_at_start_of_json (json : Yojson.Safe.t) =
  match json with
  | `String token -> history_at_start_of_string token
  | `Assoc assoc ->
    let* kind = W.wire_string_field field_kind assoc in
    if String.equal kind kind_continued_from
    then (
      let* () = W.exact_field_names_result continued_from_fields assoc in
      let* start_atom = W.wire_int_field field_start_atom assoc in
      let* start_atom_digest = W.wire_string_field field_start_atom_digest assoc in
      Ok (Continued_history_from { start_atom; start_atom_digest }))
    else W.wire_fail [ W.Wire_field field_kind ] (W.Unknown_token kind)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null ->
    W.wire_here W.Expected_object
;;

(* The line's kind names the fields it carries, so it is read first and the
   exact-fields check is made against that kind's set. *)
let record_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* kind = W.wire_string_field field_kind assoc in
    if String.equal kind kind_turn_ended
    then (
      let* () = W.exact_field_names_result turn_ended_fields assoc in
      let* recorded_at = W.wire_number_field field_recorded_at assoc in
      let* turn_ref_text = W.wire_string_field field_turn_ref assoc in
      let* turn_ref =
        match Ids.Turn_ref.of_string turn_ref_text with
        | Some turn_ref -> Ok turn_ref
        | None ->
          W.wire_fail [ W.Wire_field field_turn_ref ] (W.Not_a_turn_ref turn_ref_text)
      in
      let* history_at_start_json = W.wire_json_field field_history_at_start assoc in
      let* history_at_start = history_at_start_of_json history_at_start_json in
      let* position_json = W.wire_json_field field_position assoc in
      let* position =
        W.wire_at (W.Wire_field field_position) (position_of_json position_json)
      in
      validate { recorded_at; event = Turn_ended { turn_ref; history_at_start; position } })
    else if String.equal kind kind_history_restarted
    then (
      let* () = W.exact_field_names_result history_restarted_fields assoc in
      let* recorded_at = W.wire_number_field field_recorded_at assoc in
      let* trace_id = W.wire_string_field field_trace_id assoc in
      validate { recorded_at; event = History_restarted { trace_id } })
    else W.wire_fail [ W.Wire_field field_kind ] (W.Unknown_token kind)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

type append_error =
  | Invalid_record of W.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

let append_error_to_string = function
  | Invalid_record error ->
    "turn boundary record rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "turn boundary append failed path=%s: %s" path message
;;

let append ~keepers_dir ~keeper_id record =
  match validate record with
  | Error error -> Error (Invalid_record error)
  | Ok record ->
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let line = Yojson.Safe.to_string (record_to_json record) ^ "\n" in
    let failed message = Error (Write_failed { path; message }) in
    (match Fs_compat.append_private_jsonl_durable_locked_result path line with
     | Fs_compat.Private_file_succeeded () -> Ok ()
     | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "turn boundary append committed; descriptor settlement failed path=%s: %s"
         path
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
       Ok ()
     | Fs_compat.Private_file_failed error ->
       failed (Fs_compat.private_jsonl_append_error_to_string error)
     | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
       failed
         (Printf.sprintf
            "%s; descriptor settlement also failed: %s"
            (Fs_compat.private_jsonl_append_error_to_string error)
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception Sys_error message -> failed message
     | exception Unix.Unix_error (code, fn, arg) ->
       failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;

type read_error =
  | Not_json of string
  | Malformed of W.wire_error
  | Incomplete_line

let read_error_to_string = function
  | Not_json message -> "turn boundary line is not valid JSON: " ^ message
  | Malformed error -> "turn boundary line rejected: " ^ W.wire_error_to_string error
  | Incomplete_line -> "turn boundary line has no newline: an append never completed"
;;

let decode_line line =
  match Yojson.Safe.from_string line with
  | json -> Result.map_error (fun error -> Malformed error) (record_of_json json)
  | exception Yojson.Json_error message -> Error (Not_json message)
;;

let numbered_lines ~rows ~rows_end ~end_offset =
  (* [rows] is every newline-terminated line, so what follows its last newline
     is the empty string and not a line. *)
  let complete =
    match List.rev (String.split_on_char '\n' rows) with
    | [] -> []
    | _after_last_newline :: reversed -> List.rev reversed
  in
  let decoded = List.mapi (fun index line -> index + 1, decode_line line) complete in
  if rows_end < end_offset
  then decoded @ [ List.length complete + 1, Error Incomplete_line ]
  else decoded
;;

let read ~keepers_dir ~keeper_id =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let of_rows = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Ok []
    | Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset } ->
      Ok (numbered_lines ~rows ~rows_end ~end_offset)
  in
  let settled cleanup_failure =
    Log.Keeper.warn
      ~keeper_name:keeper_id
      "turn boundary read; descriptor settlement failed path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  in
  let unreadable exn =
    Error
      (Printf.sprintf
         "turn boundary store unreadable path=%s: %s"
         path
         (Printexc.to_string exn))
  in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded rows -> of_rows rows
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
    settled cleanup_failure;
    of_rows value
  | Fs_compat.Private_file_failed (Fs_compat.Private_jsonl_rows.Io_failed exn) ->
    unreadable exn
  | Fs_compat.Private_file_failed_with_cleanup_failure
      { error = Fs_compat.Private_jsonl_rows.Io_failed exn; cleanup_failure } ->
    settled cleanup_failure;
    unreadable exn
;;

let atom_position_stated ~trace_id (record : record) =
  match record.event with
  | Turn_ended
      { turn_ref; history_at_start = _; position = Atom_history { end_atom; last_atom_digest } }
    ->
    if String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
    then Some (turn_ref, end_atom, last_atom_digest)
    else None
  | Turn_ended
      { turn_ref = _
      ; history_at_start = _
      ; position = Empty_atom_history | No_atom_history | Stale_noop
      }
  | History_restarted _ -> None
;;

let witness_line ?through ~trace_id ~end_atom ~last_atom_digest lines =
  List.fold_left
    (fun latest (line, decoded) ->
       let counted =
         match through with
         | None -> true
         | Some last_counted -> line <= last_counted
       in
       if not counted
       then latest
       else (
         match decoded with
         | Error (_ : read_error) -> latest
         | Ok record ->
           (match atom_position_stated ~trace_id record with
            | Some (turn_ref, stated_end, stated_digest)
              when stated_end = end_atom && String.equal stated_digest last_atom_digest ->
              Some (line, record.recorded_at, turn_ref)
            | Some _ | None -> latest)))
    None
    lines
;;
