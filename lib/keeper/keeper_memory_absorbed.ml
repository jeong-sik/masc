(* Absorbed memory records (RFC-0456 §4.2). See the interface for the contract. *)

module W = Keeper_memory_os_types

let ( let* ) = Result.bind
let suffix = ".memory-absorbed.jsonl"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

type record =
  { recorded_at : float
  ; trace_id : string
  ; memory_id : string
  ; into : string
  ; fact : W.fact
  }

let field_recorded_at = "recorded_at"
let field_trace_id = "trace_id"
let field_memory_id = "memory_id"
let field_into = "into"
let field_fact = "fact"

let fields = [ field_recorded_at; field_trace_id; field_memory_id; field_into; field_fact ]

let validate (r : record) =
  let* () =
    if Float.is_finite r.recorded_at
    then Ok ()
    else W.wire_fail [ W.Wire_field field_recorded_at ] W.Not_finite
  in
  let* () =
    if W.is_memory_id r.memory_id
    then Ok ()
    else W.wire_fail [ W.Wire_field field_memory_id ] (W.Not_a_memory_id r.memory_id)
  in
  let* () =
    if W.is_memory_id r.into
    then Ok ()
    else W.wire_fail [ W.Wire_field field_into ] (W.Not_a_memory_id r.into)
  in
  (* A fact that absorbs itself names nothing; a row whose id is not its fact's
     identity would answer a search with text the id does not name. *)
  let* () =
    if String.equal r.memory_id r.into
    then W.wire_fail [ W.Wire_field field_into ] (W.Duplicate_entry r.into)
    else Ok ()
  in
  let identity = W.memory_id r.fact in
  if String.equal identity r.memory_id
  then Ok r
  else W.wire_fail [ W.Wire_field field_memory_id ] (W.Not_a_memory_id r.memory_id)
;;

let record_to_json (r : record) =
  `Assoc
    [ field_recorded_at, `Float r.recorded_at
    ; field_trace_id, `String r.trace_id
    ; field_memory_id, `String r.memory_id
    ; field_into, `String r.into
    ; field_fact, W.fact_to_json r.fact
    ]
;;

let record_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* recorded_at = W.wire_number_field field_recorded_at assoc in
    let* trace_id = W.wire_string_field field_trace_id assoc in
    let* memory_id = W.wire_string_field field_memory_id assoc in
    let* into = W.wire_string_field field_into assoc in
    let* fact =
      match List.assoc_opt field_fact assoc with
      | Some fact_json ->
        W.fact_of_json fact_json
        |> Result.map_error (fun (error : W.wire_error) ->
          { error with W.path = W.Wire_field field_fact :: error.W.path })
      | None -> W.wire_fail [ W.Wire_field field_fact ] W.Expected_object
    in
    validate { recorded_at; trace_id; memory_id; into; fact }
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
  | Invalid_record error -> "absorbed memory record rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "absorbed memory append failed path=%s: %s" path message
;;

let append_all ~keepers_dir ~keeper_id records =
  let rec validated acc = function
    | [] -> Ok (List.rev acc)
    | record :: rest ->
      (match validate record with
       | Ok record -> validated (record_to_json record :: acc) rest
       | Error error -> Error (Invalid_record error))
  in
  match validated [] records with
  | Error _ as error -> error
  | Ok [] -> Ok ()
  | Ok (_ :: _ as lines) ->
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let suffix =
      String.concat "" (List.map (fun json -> Yojson.Safe.to_string json ^ "\n") lines)
    in
    let failed message = Error (Write_failed { path; message }) in
    (match Fs_compat.append_private_jsonl_durable_locked_result path suffix with
     | Fs_compat.Private_file_succeeded () -> Ok ()
     | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "absorbed memory append committed; descriptor settlement failed path=%s: %s"
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
  | Not_json message -> "absorbed memory line is not valid JSON: " ^ message
  | Malformed error -> "absorbed memory line rejected: " ^ W.wire_error_to_string error
  | Incomplete_line -> "absorbed memory line has no newline: an append never completed"
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
      "absorbed memory read; descriptor settlement failed path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  in
  let unreadable exn =
    Error
      (Printf.sprintf
         "absorbed memory store unreadable path=%s: %s"
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
