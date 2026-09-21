(* What an official-client turn left in the history files of its trace (RFC
   librarian-lifecycle §10-3). See the interface for the contract. *)

module W = Keeper_memory_os_types
module H = Keeper_context_core_history

let ( let* ) = Result.bind

type fragment =
  | Message of
      { turn_ref : Ids.Turn_ref.t
      ; recorded_at : float
      ; source : string option
      ; message : Agent_core.Types.message
      }
  | Tool_observation of
      { turn_ref : Ids.Turn_ref.t
      ; recorded_at : float
      ; observation : Keeper_librarian.tool_observation
      }

let fragment_turn_ref = function
  | Message { turn_ref; _ } | Tool_observation { turn_ref; _ } -> turn_ref
;;

type line =
  | Fragment of fragment
  | Untagged

type read_error =
  | Not_json of string
  | Malformed of W.wire_error
  | Message_rejected of string
  | Incomplete_line

let read_error_to_string = function
  | Not_json message -> "history line is not valid JSON: " ^ message
  | Malformed error -> "history line rejected: " ^ W.wire_error_to_string error
  | Message_rejected detail -> "history line's message rejected: " ^ detail
  | Incomplete_line -> "history line has no newline: an append never completed"
;;

type file =
  | Main
  | Internal

let path ~session_dir = function
  | Main -> H.main_history_path ~session_dir
  | Internal -> H.internal_history_path ~session_dir
;;

(* The keys a message line may carry: the writer's own three, the routing
   source, and the message's fields. *)
let message_line_required = [ H.key_ts_unix; H.key_turn_ref; H.key_kind; "role"; "content_blocks" ]
let message_line_optional = [ H.key_source; "name"; "tool_call_id"; "metadata" ]
let tool_observation_fields =
  [ H.key_ts_unix; H.key_turn_ref; H.key_kind; H.key_tool_name; H.key_outcome ]
;;

(* Required keys all present, and no key outside required and optional. The
   exact-fields check of the wire module cannot say "optional", so the
   mismatch is built the same way it would. *)
let message_field_names_result assoc =
  let names = List.map fst assoc in
  let missing = List.filter (fun name -> not (List.mem name names)) message_line_required in
  let unexpected =
    List.filter
      (fun name ->
         not (List.mem name message_line_required || List.mem name message_line_optional))
      names
  in
  if missing = [] && unexpected = []
  then Ok ()
  else W.wire_here (W.Field_set_mismatch { missing; unexpected })
;;

let turn_ref_field assoc =
  let* text = W.wire_string_field H.key_turn_ref assoc in
  match Ids.Turn_ref.of_string text with
  | Some turn_ref -> Ok turn_ref
  | None -> W.wire_fail [ W.Wire_field H.key_turn_ref ] (W.Not_a_turn_ref text)
;;

let outcome_of_token token =
  if String.equal token (Tool_result.string_of_tool_call_outcome Tool_result.Ok)
  then Ok Keeper_librarian.Succeeded
  else if String.equal token (Tool_result.string_of_tool_call_outcome Tool_result.Error)
  then Ok Keeper_librarian.Failed
  else if String.equal token (Tool_result.string_of_tool_call_outcome Tool_result.Unknown)
  then Ok Keeper_librarian.Unknown
  else W.wire_fail [ W.Wire_field H.key_outcome ] (W.Unknown_token token)
;;

let decode_tagged ~turn_ref json assoc : (fragment, read_error) result =
  let wire result = Result.map_error (fun error -> Malformed error) result in
  let* kind = wire (W.wire_string_field H.key_kind assoc) in
  let* recorded_at = wire (W.wire_number_field H.key_ts_unix assoc) in
  if String.equal kind H.kind_message
  then (
    let* () = wire (message_field_names_result assoc) in
    let* source =
      match List.assoc_opt H.key_source assoc with
      | None -> Ok None
      | Some _ -> wire (Result.map Option.some (W.wire_string_field H.key_source assoc))
    in
    match Keeper_context_core.message_of_json json with
    | message -> Ok (Message { turn_ref; recorded_at; source; message })
    | exception Invalid_argument detail -> Error (Message_rejected detail)
    | exception Failure detail -> Error (Message_rejected detail)
    | exception Yojson.Safe.Util.Type_error (detail, _) -> Error (Message_rejected detail))
  else if String.equal kind H.kind_tool_observation
  then (
    let* () = wire (W.exact_field_names_result tool_observation_fields assoc) in
    let* tool_name = wire (W.wire_string_field H.key_tool_name assoc) in
    let* token = wire (W.wire_string_field H.key_outcome assoc) in
    let* outcome = wire (outcome_of_token token) in
    Ok (Tool_observation { turn_ref; recorded_at; observation = { tool_name; outcome } }))
  else wire (W.wire_fail [ W.Wire_field H.key_kind ] (W.Unknown_token kind))
;;

let decode_line text : (line, read_error) result =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error message -> Error (Not_json message)
  | `Assoc assoc as json ->
    if not (List.mem_assoc H.key_turn_ref assoc)
    then Ok Untagged
    else (
      match turn_ref_field assoc with
      | Error error -> Error (Malformed error)
      | Ok turn_ref -> Result.map (fun fragment -> Fragment fragment) (decode_tagged ~turn_ref json assoc))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Result.map_error (fun error -> Malformed error) (W.wire_here W.Expected_object)
;;

let numbered_lines ~rows ~rows_end ~end_offset =
  let complete =
    match List.rev (String.split_on_char '\n' rows) with
    | [] -> []
    | _after_last_newline :: reversed -> List.rev reversed
  in
  let decoded = List.mapi (fun index text -> index + 1, decode_line text) complete in
  if rows_end < end_offset
  then decoded @ [ List.length complete + 1, Error Incomplete_line ]
  else decoded
;;

let read ~session_dir file =
  let path = path ~session_dir file in
  let of_rows = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Ok []
    | Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset } ->
      Ok (numbered_lines ~rows ~rows_end ~end_offset)
  in
  let settled cleanup_failure =
    Log.Keeper.warn
      "history read; descriptor settlement failed path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  in
  let unreadable exn =
    Error (Printf.sprintf "history store unreadable path=%s: %s" path (Printexc.to_string exn))
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

let of_turn turn_ref lines =
  List.filter_map
    (fun (_, read) ->
       match read with
       | Ok (Fragment fragment) when Ids.Turn_ref.equal (fragment_turn_ref fragment) turn_ref ->
         Some fragment
       | Ok (Fragment _) | Ok Untagged | Error _ -> None)
    lines
;;

let first_refused lines =
  let first_named =
    List.find_map
      (fun (line, read) ->
         match read with
         | Ok (Fragment _) -> Some line
         | Ok Untagged | Error _ -> None)
      lines
  in
  match first_named with
  | None -> None
  | Some first_named ->
    List.find_map
      (fun (line, read) ->
         match read with
         | Error ((Not_json _ | Malformed _ | Message_rejected _) as error) when line > first_named
           -> Some (line, error)
         | Error (Not_json _ | Malformed _ | Message_rejected _ | Incomplete_line) | Ok _ -> None)
      lines
;;
