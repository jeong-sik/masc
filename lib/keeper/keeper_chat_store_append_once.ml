open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_row_codec
open Keeper_chat_store_provenance_index
open Keeper_chat_store_append_primitives

module Row_route = struct
  type t =
    { surface : Surface_ref.t option
    ; conversation_id : string option
    }

  let none = { surface = None; conversation_id = None }
end

(* A row that was already there was announced when it was stored. The route
   of an appended row was forced to encode it, so forcing it here reads the
   value under no lock and computes nothing. *)
let announce_if_appended ~keeper_name ~(route : Row_route.t Lazy.t) result =
  (match result with
   | Ok (Appended _) ->
     announce_appended ~keeper_name ?surface:(Lazy.force route).surface ()
   | Ok (Already_present _) | Error _ -> ());
  result

(* [line] is encoded under the file lock only when its slot is absent, so a
   lazy route is never read for a row that is already present. Stdlib.Lazy:
   the lock body runs in a systhread where Eio.Lazy cannot run, and each lazy
   belongs to one append call, so nothing forces it concurrently. *)
type append_once_line =
  { transcript_slot : Keeper_chat_delivery_identity.transcript_slot
  ; row_id : string
  ; line : string Lazy.t
  }

let transcript_slot_ordinal = function
  | Keeper_chat_delivery_identity.Tool_call { ordinal; _ }
  | Keeper_chat_delivery_identity.Tool_delivery { ordinal } -> Some ordinal
  | Keeper_chat_delivery_identity.Accepted_user
  | Keeper_chat_delivery_identity.Terminal_result
  | Keeper_chat_delivery_identity.Settled_failure
  | Keeper_chat_delivery_identity.Approval_request
  | Keeper_chat_delivery_identity.Approval_resolution
  | Keeper_chat_delivery_identity.Approval_replay
  | Keeper_chat_delivery_identity.Approval_replay_correction
  | Keeper_chat_delivery_identity.Approval_continuation -> None
;;

let validate_append_once_lines lines =
  let rec loop seen_slots seen_ordinals seen_executions = function
    | [] -> Ok ()
    | { transcript_slot; _ } :: rest ->
      let open Result.Syntax in
      let* () =
        if
          List.exists
            (Keeper_chat_delivery_identity.transcript_slot_equal transcript_slot)
            seen_slots
        then Error "append-once batch repeats a delivery provenance slot"
        else Ok ()
      in
      let ordinal = transcript_slot_ordinal transcript_slot in
      let* () =
        match ordinal with
        | Some ordinal when List.mem ordinal seen_ordinals ->
          Error "append-once batch repeats a tool ordinal"
        | Some _ | None -> Ok ()
      in
      let execution_id =
        match transcript_slot with
        | Keeper_chat_delivery_identity.Tool_call { execution_id; _ } ->
          Some execution_id
        | Keeper_chat_delivery_identity.Accepted_user
        | Keeper_chat_delivery_identity.Tool_delivery _
        | Keeper_chat_delivery_identity.Terminal_result
        | Keeper_chat_delivery_identity.Settled_failure
        | Keeper_chat_delivery_identity.Approval_request
        | Keeper_chat_delivery_identity.Approval_resolution
        | Keeper_chat_delivery_identity.Approval_replay
        | Keeper_chat_delivery_identity.Approval_replay_correction
        | Keeper_chat_delivery_identity.Approval_continuation -> None
      in
      let* () =
        match execution_id with
        | Some execution_id
          when String.equal
                 (String.trim (Ids.Execution_id.to_string execution_id))
                 "" ->
          Error "append-once batch contains a blank canonical execution_id"
        | Some execution_id
          when List.exists (Ids.Execution_id.equal execution_id) seen_executions ->
          Error
            "append-once batch reuses a canonical execution_id for multiple tool ordinals"
        | Some _ | None -> Ok ()
      in
      loop
        (transcript_slot :: seen_slots)
        (Option.fold ~none:seen_ordinals
           ~some:(fun ordinal -> ordinal :: seen_ordinals)
           ordinal)
        (Option.fold ~none:seen_executions
           ~some:(fun execution_id -> execution_id :: seen_executions)
           execution_id)
        rest
  in
  loop [] [] [] lines
;;

let append_lines_once ?(reject_partial_after_result = false) path ~delivery_key
      ~result_slot lines =
  match validate_append_once_lines lines with
  | Error detail -> Error detail
  | Ok () ->
    (match
       Fs_compat.update_private_file_durable_locked_result path (fun existing ->
      let inspect index =
        let rec loop found additions = function
          | [] -> Ok (found, List.rev additions)
          | ({ transcript_slot; row_id; line = _ } as candidate) :: rest ->
            (match
               find_indexed_provenance
                 index
                 ~provenance:
                   { Keeper_chat_delivery_identity.delivery_key
                   ; transcript_slot
                   }
             with
             | Error detail -> Error detail
             | Ok (Some existing_row_id) ->
               loop
                 ((transcript_slot, existing_row_id, true) :: found)
                 additions
                 rest
             | Ok None ->
               loop
                 ((transcript_slot, row_id, false) :: found)
                 (candidate :: additions)
                 rest)
        in
        loop [] [] lines
      in
      let inspected =
        Result.bind (provenance_index_of_existing existing) inspect
      in
      match inspected with
      | Error detail -> None, Error detail
      | Ok (rows, additions) ->
        let result_row =
          List.find_map
            (fun (slot, row_id, was_present) ->
               if Keeper_chat_delivery_identity.transcript_slot_equal slot result_slot
               then Some (row_id, was_present)
               else None)
            rows
        in
        (match result_row with
         | None -> None, Error "idempotent chat append is missing its result slot"
         | Some (row_id, result_was_present)
           when reject_partial_after_result && result_was_present && additions <> [] ->
           None,
           Error
             "assistant transcript already exists without its tool-call payload"
         | Some (row_id, _) ->
           let result =
             if additions = []
             then Already_present { row_id }
             else Appended { row_id }
           in
           let payload =
             additions
             |> List.map (fun candidate -> Lazy.force candidate.line ^ "\n")
             |> String.concat ""
           in
           (if additions = [] then None else Some payload), Ok result))
     with
     | Private_file_succeeded result -> result
     | Private_file_succeeded_with_cleanup_failure
      { value = result; cleanup_failure } ->
       Log.Keeper.error
         "keeper_chat_store: provenance batch update succeeded with descriptor settlement failure path=%s: %s"
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
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))
;;

let tool_call_append_lines ~ts ~route ~turn_ref ~delivery_key tool_calls =
  List.map
    (fun (tc, transcript_slot) ->
       let row_id = mint_message_id ~ts in
       { transcript_slot
       ; row_id
       ; line =
           lazy
             (let { Row_route.surface; conversation_id } = Lazy.force route in
              encode_line
                ~role:Role.Tool
                ~content:(normalize_tool_args tc.args)
                ~ts
                ~message_id:row_id
                ?tool_call_id:(provider_tool_call_id tc.call_id)
                ?execution_id:tc.execution_id
                ~tool_call_name:tc.call_name
                ?surface
                ?conversation_id
                ?turn_ref
                ~provenance:
                  { Keeper_chat_delivery_identity.delivery_key; transcript_slot }
                ())
       })
    (tool_transcript_bindings tool_calls)
;;

let append_tool_calls_once
      ~base_dir
      ~keeper_name
      ~delivery_key
      ~(tool_calls : tool_call list)
      ?surface
      ?conversation_id
      ?turn_ref
      ()
  =
  match tool_calls with
  | [] -> Error "idempotent tool-call append requires at least one tool call"
  | _ ->
    try
      ensure_dir_once ~base_dir;
      let redaction = redaction_for ~base_dir ~keeper_name in
      let tool_calls = List.map (redact_tool_call redaction) tool_calls in
      let path = chat_path ~base_dir ~keeper_name in
      let ts = Time_compat.now () in
      let route = Lazy.from_val { Row_route.surface; conversation_id } in
      let lines = tool_call_append_lines ~ts ~route ~turn_ref ~delivery_key tool_calls in
      let ordinal = List.length tool_calls - 1 in
      let result_slot = tool_transcript_slot ~ordinal (List.nth tool_calls ordinal) in
      append_lines_once path ~delivery_key ~result_slot lines
      |> announce_if_appended ~keeper_name ~route
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ChatStoreFailures)
        ~labels:[ "operation", Keeper_chat_store_operation.(to_label Append) ]
        ();
      let detail = Printexc.to_string exn in
      Log.Keeper.warn
        "keeper_chat_store: tool-call append-once failed for %s: %s"
        (sanitize_name keeper_name)
        detail;
      Error detail
;;
