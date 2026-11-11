open Keeper_chat_types
open Keeper_chat_store_provenance_index
open Keeper_chat_store_transcript_index

let append_line_once path ~provenance ~row_id line =
  match provenance.Keeper_chat_delivery_identity.delivery_key with
  | Keeper_chat_delivery_identity.Autonomous_turn _ ->
    Error "autonomous turn rows require the binding-aware batch writer"
  | Keeper_chat_delivery_identity.Operation _ | Operation_checkpoint _ | Operation_native _
  | Fusion_run _ | Workspace_message _ | Connector_message _ | Approval_lifecycle _ ->
  match
    update_indexed_transcript path (fun index ->
      match Result.bind index (fun index -> find_indexed_provenance index ~provenance) with
      | Error detail -> None, Error detail
      | Ok (Some existing_row_id) ->
        None, Ok (Already_present { row_id = existing_row_id })
      | Ok None -> Some (line ^ "\n"), Ok (Appended { row_id }))
  with
  | Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure
      { value = result; cleanup_failure } ->
    Log.Keeper.error
      "keeper_chat_store: provenance update succeeded with descriptor settlement failure path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    result
  | Private_file_failed error ->
    Error (Fs_compat.durable_append_error_to_string error)
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Printf.sprintf
         "%s; descriptor settlement failed: %s"
         (Fs_compat.durable_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
;;

let append_chat_payload_durable path payload =
  match Fs_compat.append_private_jsonl_durable_locked_result path payload with
  | Private_file_succeeded () -> ()
  | Private_file_succeeded_with_cleanup_failure
      { value = (); cleanup_failure } ->
    Log.Keeper.error
      "keeper_chat_store: payload append succeeded with descriptor settlement failure path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Private_file_failed error ->
    raise
      (Sys_error
         (Printf.sprintf
            "%s: %s"
            path
            (Fs_compat.private_jsonl_append_error_to_string error)))
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    raise
      (Sys_error
         (Printf.sprintf
            "%s: %s; descriptor settlement failed: %s"
            path
            (Fs_compat.private_jsonl_append_error_to_string error)
            (Fs_compat.private_jsonl_operation_failure_to_string
               cleanup_failure)))
;;

(* Each writer below says its rows are in once the durable write has
   returned, outside the file lock, from the row it stored: the surface it
   persisted and the clip it kept. A caller that stores a row therefore cannot
   leave the open transcripts without word of it. *)
let announce_appended ~keeper_name ?surface ?audio () =
  Keeper_chat_broadcast.chat_appended ~keeper_name
    ?connector:(Option.map Surface_ref.lane_label surface)
    ?audio ()

(* Tool calls with empty accumulated arguments are normalised to "{}" so
   every persisted line keeps a non-empty [content] (the read-side
   validity check and the dashboard history mapping both require it). *)
let normalize_tool_args args =
  if String.trim args = "" then "{}" else args

(* Two questions were sharing one answer.

   "What did the provider call this?" is a record. It can be unanswered, and
   the log writer already answers an empty call_id by omitting the field
   ([keeper_event_bridge.ml:199]). Synthesising "tc-<position>" here made the
   two writers disagree about the same execution, and the dashboard join
   matches on that id alone, so the step stayed pending forever (#21894).
   {!Tool_invocation_ref} states the rule directly: correlation identity is
   never inferred from names, arguments, timestamps, or hashes.

   "Where does this turn's reply go?" is a delivery address. Its position is
   total because the slot is this store's own, but it must not masquerade as
   an execution identity. *)
let provider_tool_call_id call_id =
  if String.trim call_id = "" then None else Some call_id

let tool_transcript_slot ~ordinal (call : tool_call) =
  match call.execution_id with
  | Some execution_id ->
    Keeper_chat_delivery_identity.Tool_call { execution_id; ordinal }
  | None -> Keeper_chat_delivery_identity.Tool_delivery { ordinal }

type tool_ownership =
  { execution_id : Ids.Execution_id.t
  ; ordinal : int
  }

let tool_ownerships calls =
  List.concat
    (List.mapi
       (fun ordinal (call : tool_call) ->
         match call.execution_id with
         | Some execution_id -> [ { execution_id; ordinal } ]
         | None -> [])
       calls)

let tool_transcript_bindings calls =
  List.mapi (fun ordinal call -> call, tool_transcript_slot ~ordinal call) calls
