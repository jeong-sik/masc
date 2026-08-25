(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.
    See [gate_keeper_backend.mli] for the full contract. *)

type connector_delivery =
  { continuation_channel : Keeper_continuation_channel.t
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; workspace_id : string option
  }

let non_empty_opt value =
  match String.trim value with
  | "" -> None
  | trimmed -> Some trimmed

(* ── Dispatch ────────────────────────────────────────────────── *)

let normalized_context_value value =
  value
  |> String.to_seq
  |> Seq.map (function
       | '\n' | '\r' | '\t' -> ' '
       | ch -> ch)
  |> String.of_seq
  |> String.trim

let normalized_or_unknown value =
  match normalized_context_value value with
  | "" -> "unknown"
  | trimmed -> trimmed

(** Sanitize a value for use as a filesystem path component.
    Replaces everything outside [A-Za-z0-9_-] with '_' so that the resulting
    string cannot escape its intended parent directory via '/', '\\', or '..'
    sequences. Empty or fully-stripped values collapse to "unknown". *)
let filesystem_safe_or_unknown value =
  let normalized = normalized_context_value value in
  if normalized = "" then "unknown"
  else
    let buf = Buffer.create (String.length normalized) in
    String.iter
      (fun ch ->
        match ch with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' ->
          Buffer.add_char buf ch
        | _ -> Buffer.add_char buf '_')
      normalized;
    let s = Buffer.contents buf in
    if s = "" || String.for_all (fun c -> c = '_') s then "unknown" else s

let agent_name_for_channel_actor ~channel ~channel_workspace_id ~channel_user_id =
  Printf.sprintf "gate:%s:%s:%s"
    (filesystem_safe_or_unknown channel)
    (filesystem_safe_or_unknown channel_workspace_id)
    (filesystem_safe_or_unknown channel_user_id)

let contextualize_message ~channel ~channel_user_id ~channel_user_name
    ~channel_workspace_id ~metadata ~content =
  let safe_channel = normalized_or_unknown channel in
  let safe_user_id = normalized_or_unknown channel_user_id in
  let safe_user_name = normalized_or_unknown channel_user_name in
  let safe_workspace_id = normalized_or_unknown channel_workspace_id in
  let safe_content = String.trim content in
  let metadata_lines =
    metadata
    |> List.filter_map (fun (key, value) ->
           let key = normalized_context_value key in
           let value = normalized_context_value value in
           if key = "" || value = "" then None
           else Some (key ^ ": " ^ value))
  in
  let context_lines =
    [
      "[External channel context]";
      "channel: " ^ safe_channel;
      "workspace_id: " ^ safe_workspace_id;
      "user_id: " ^ safe_user_id;
      "user_name: " ^ safe_user_name;
    ]
  in
  let metadata_block =
    match metadata_lines with
    | [] -> []
    | lines -> "" :: "[External channel metadata]" :: lines
  in
  String.concat "\n"
    (context_lines
     @ metadata_block
     @ [ ""; "[User message]"; safe_content ])

let metadata_value key metadata =
  match List.assoc_opt key metadata with
  | Some value ->
      let value = String.trim value in
      if value = "" then None else Some value
  | None -> None

let assoc_string_if_present key value =
  match non_empty_opt value with
  | None -> []
  | Some value -> [ (key, value) ]

let opt_assoc_string_if_present key = function
  | None -> []
  | Some value -> assoc_string_if_present key value

let gate_address ~channel ~channel_workspace_id ?conversation_id
    ?external_message_id () =
  assoc_string_if_present "connector" channel
  @ assoc_string_if_present "workspace_id" channel_workspace_id
  @ opt_assoc_string_if_present "conversation_id" conversation_id
  @ opt_assoc_string_if_present "external_message_id" external_message_id

let surface_for_channel_context ~channel ~channel_workspace_id ?conversation_id
    ?external_message_id () =
  let label =
    match non_empty_opt channel with
    | Some lane -> lane
    | None -> "gate"
  in
  Surface_ref.Gate
    { label
    ; address =
        gate_address ~channel ~channel_workspace_id ?conversation_id
          ?external_message_id ()
    }

let conversation_id_for_channel_context ~channel ~channel_workspace_id ~metadata =
  match metadata_value "conversation_id" metadata with
  | Some value -> Some value
  | None ->
    (match non_empty_opt channel, non_empty_opt channel_workspace_id with
     | Some lane, Some workspace_id ->
       Some (Printf.sprintf "gate:%s:workspace:%s" lane workspace_id)
     | _ -> None)

let external_message_id_for_channel_context ~idempotency_key ~metadata =
  match metadata_value "external_message_id" metadata with
  | Some value -> Some value
  | None -> non_empty_opt idempotency_key

let reconcile_delivery_metadata key expected metadata =
  let observed =
    List.filter_map
      (fun (candidate, value) ->
         if String.equal candidate key then Some value else None)
      metadata
  in
  match expected, observed with
  | None, [] -> Ok metadata
  | None, _ :: _ ->
    Error
      (Printf.sprintf
         "connector delivery omitted %s but metadata supplied an independent value"
         key)
  | Some expected, [] -> Ok (metadata @ [ (key, expected) ])
  | Some expected, [ observed ] when String.equal expected observed -> Ok metadata
  | Some expected, [ observed ] ->
    Error
      (Printf.sprintf
         "connector delivery %s conflicts with metadata (delivery=%S metadata=%S)"
         key
         expected
         observed)
  | Some _, _ :: _ :: _ ->
    Error (Printf.sprintf "connector metadata contains duplicate %s fields" key)
;;

(* The untyped gate-message [channel_workspace_id] string and the typed
   [delivery.workspace_id] describe the same workspace at two layers; the
   stringly layer encodes absence as "". Any disagreement between them is a
   wiring defect, so intake fails closed instead of silently picking one —
   the same discipline as {!reconcile_delivery_metadata}. *)
let reconcile_gate_workspace_id ~channel_workspace_id ~workspace_id =
  match non_empty_opt channel_workspace_id, workspace_id with
  | None, None -> Ok ()
  | Some gate, Some typed when String.equal gate typed -> Ok ()
  | Some gate, Some typed ->
    Error
      (Printf.sprintf
         "connector gate workspace_id conflicts with typed delivery \
          (gate=%S delivery=%S)"
         gate
         typed)
  | Some gate, None ->
    Error
      (Printf.sprintf
         "connector gate supplied workspace_id %S but the typed delivery \
          omitted it"
         gate)
  | None, Some typed ->
    Error
      (Printf.sprintf
         "connector typed delivery supplied workspace_id %S but the gate \
          context omitted it"
         typed)
;;

let extra_mentions_for_metadata ~keeper_name metadata =
  match metadata_value "mentions_bound_keeper" metadata with
  | Some "true" ->
    Option.to_list (Keeper_identity.Keeper_id.of_string keeper_name)
  | Some _ | None -> []

let operation_request_status = function
  | Keeper_chat_operation.Queued -> Gate_protocol.Queued
  | Running _ -> Gate_protocol.Running
  | Succeeded _ -> Gate_protocol.Done
  | Failed _ -> Gate_protocol.Failed
  | Cancelled _ -> Gate_protocol.Cancelled
;;

let accept_connector ~delivery ~clock:_ ~config ~channel ~channel_user_id
    ~channel_user_name ~channel_workspace_id ~keeper_name ~idempotency_key
    ~metadata ~content =
  let keeper_name = String.trim keeper_name in
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:config.Workspace.base_path
      ~keeper_name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
  let conversation_id = delivery.conversation_id in
  let external_message_id = delivery.external_message_id in
  let workspace_id = delivery.workspace_id in
  let metadata =
    match
      reconcile_delivery_metadata "conversation_id" conversation_id metadata
    with
    | Error _ as error -> error
    | Ok metadata ->
      (match
         reconcile_delivery_metadata
           "external_message_id"
           external_message_id
           metadata
       with
       | Error _ as error -> error
       | Ok metadata ->
         reconcile_delivery_metadata "workspace_id" workspace_id metadata)
  in
  let metadata =
    match reconcile_gate_workspace_id ~channel_workspace_id ~workspace_id with
    | Error _ as error -> error
    | Ok () -> metadata
  in
  match metadata with
  | Error detail -> Gate_protocol.Keeper_error_result (redact_text detail)
  | Ok metadata ->
    (match
       Keeper_chat_operation.Operation_id.of_string idempotency_key
     with
     | Error detail ->
       Gate_protocol.Keeper_error_result (redact_text detail)
     | Ok operation_id ->
       let extra_mentions = extra_mentions_for_metadata ~keeper_name metadata in
       let submitted_by =
         agent_name_for_channel_actor
           ~channel
           ~channel_workspace_id
           ~channel_user_id
       in
       let source =
         Keeper_chat_operation_payload.source_to_json
           ~submitted_by
           ~thread_id:("keeper:" ^ keeper_name)
           ~continuation_channel:delivery.continuation_channel
           ~surface:delivery.surface
           ~channel
           ~channel_user_id
           ~channel_user_name
           ~channel_workspace_id
           ~conversation_id:delivery.conversation_id
           ~external_message_id:delivery.external_message_id
           ~workspace_id:delivery.workspace_id
           ~extra_mentions
           ~user_row_origin:Keeper_chat_store.Needs_append
       in
       (match source with
        | Error detail -> Gate_protocol.Keeper_error_result (redact_text detail)
        | Ok source ->
          let input =
            Keeper_chat_operation_payload.input_to_json
              ~message:(String.trim content)
              ~user_blocks:[]
              ~turn_instructions:None
              ~surface_context:None
              ~attachments:[]
          in
          (match
             Keeper_owner_registry.submit_operation
               ~base_path:config.Workspace.base_path
               ~keeper_name
               ~operation_id
               ~source
               ~input
           with
           | Error (Keeper_owner_registry.Command_lookup_failed _) ->
             Gate_protocol.Unavailable_result
           | Error error ->
             Gate_protocol.Keeper_error_result
               (redact_text (Keeper_owner_registry.command_error_to_string error))
           | Ok acceptance ->
             let operation = acceptance.Keeper_owner.operation in
             let operation_id =
               Keeper_chat_operation.Operation_id.to_string operation.operation_id
             in
             let status = operation_request_status operation.state in
             let message_request : Gate_protocol.message_request =
               { request_id = operation_id
               ; destination_type = "keeper"
               ; destination_id = keeper_name
               ; channel
               ; actor_id = non_empty_opt channel_user_id
               ; status
               ; modalities = [ "text" ]
               ; transport = non_empty_opt channel
               ; metadata =
                   [ "status_source", "keeper_chat_operation"
                   ; "operation_id", operation_id
                   ; "queued_count", string_of_int acceptance.queued_count
                   ]
                   @ metadata
               }
             in
             Gate_protocol.Reply
               { content =
                   redact_text
                     (Printf.sprintf
                        "%s accepted operation %s (%s)"
                        keeper_name
                        operation_id
                        (Keeper_chat_operation.state_to_string operation.state))
               ; structured = None
               ; stats = None
               ; message_request = Some message_request
               })))

(* [Channel_gate.handle_inbound_with] records every dispatch outcome and
   duration through [Channel_gate_metrics.record_attempt]. TEL-OK: recording
   again in this adapter would double-count the same connector attempt. *)
let dispatch ~clock ~config ~channel
    ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
    ~idempotency_key ~metadata ~content =
  let conversation_id =
    conversation_id_for_channel_context
      ~channel
      ~channel_workspace_id
      ~metadata
  in
  let external_message_id =
    external_message_id_for_channel_context ~idempotency_key ~metadata
  in
  let surface =
    surface_for_channel_context
      ~channel
      ~channel_workspace_id
      ?conversation_id
      ?external_message_id
      ()
  in
  match
    Keeper_continuation_channel.dashboard
      ~thread_id:("keeper:" ^ String.trim keeper_name)
  with
  | Error detail -> Gate_protocol.Keeper_error_result detail
  | Ok continuation_channel ->
    accept_connector
      ~delivery:
        { continuation_channel
        ; surface
        ; conversation_id
        ; external_message_id
        ; workspace_id = non_empty_opt channel_workspace_id
        }
      ~clock
      ~config
      ~channel
      ~channel_user_id
      ~channel_user_name
      ~channel_workspace_id
      ~keeper_name
      ~idempotency_key
      ~metadata
      ~content
