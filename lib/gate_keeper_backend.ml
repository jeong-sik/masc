(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.
    See [gate_keeper_backend.mli] for the full contract. *)

(* ── Connector deferred-reply routing (RFC-connector-deferred-reply-via-chat-queue) ─────────────── *)

(* [connector_kind] is the typed identity of the connector a [dispatch] serves.
   It is a property of the connector, not of each message, so it is baked in at
   dispatch-construction time (the Discord gateway passes [~connector_kind:Discord]
   when it builds its dispatch). The per-message channel_id / user_id arrive as the
   ordinary [channel_workspace_id] / [channel_user_id] dispatch fields.

   This lives in [masc] (not the [masc_gate] [dispatch_fn] type) on purpose:
   [message_source] is a [masc] type, and putting it on a [masc_gate] signature
   would be a [masc_gate -> masc] dependency cycle. Threading the typed kind as an
   injected dispatch argument keeps [masc_gate] connector-neutral (RFC-0226) while
   letting the busy branch route without string-matching the [channel] lane. *)
type connector_kind =
  | Discord
  | Slack
      (** RFC-0317: the in-process Slack Socket Mode gateway
          ([Server_slack_in_process_gateway]) builds its dispatch with
          [~connector_kind:Slack]. Like [Discord] it has an outbound adapter
          ([Keeper_chat_slack.adapter_loop], drained by the serial chat
          consumer), so a message arriving mid-turn projects onto the chat queue
          for deferred delivery rather than the outbound-less async poll store.
          Added together with that gateway, not before. *)
  | Generic
      (** Every connector that is not a wired in-process inbound gateway with its
          own outbound adapter. Today this is the HTTP gate-route lane
          (imessage-bot, cli-connector) which POSTs and awaits synchronously, so
          a busy message keeps the async [masc_keeper_msg] poll path; see
          RFC-connector-deferred-reply-via-chat-queue §3.3 option (a). *)

type submission_owner =
  | Authenticated_caller of string
  | Channel_actor

type durable_connector =
  | Discord_connector
  | Slack_connector

(* [route_busy_connector] decides where a connector message goes when the keeper
   is already in flight. Pure and exhaustive over [connector_kind] so a new
   connector forces a routing decision at compile time (no catch-all). [Discord]
   projects onto the chat queue, whose serial consumer drains it after the slot
   frees and delivers the reply through the connector's outbound adapter
   ([Keeper_chat_discord.adapter_loop]); [Generic] has no such adapter and falls
   back to the async poll store. *)
let route_busy_connector (kind : connector_kind) ~channel_id ~user_id ~user_name
    ~team_id ~thread_ts :
    [ `Enqueue_chat_queue of Keeper_chat_queue.message_source | `Async_poll ] =
  match kind with
  | Discord -> `Enqueue_chat_queue (Keeper_chat_queue.Discord { channel_id; user_id })
  | Slack ->
    `Enqueue_chat_queue
      (Keeper_chat_queue.Slack
         { channel_id; user_id; user_name; team_id; thread_ts })
  | Generic -> `Async_poll

(* ── Keeper response parsing ─────────────────────────────────── *)

let extract_turn_stats (body : string) : Gate_protocol.turn_stats option =
  Safe_ops.protect ~default:None (fun () ->
    let json = Yojson.Safe.from_string body in
    match
      Json_util.get_int json "duration_ms",
      Json_util.get_int json "total_tokens"
    with
    | Some dur, Some tok when dur > 0 || tok > 0 ->
      Some
        { Gate_protocol.model_used = "runtime"; duration_ms = dur; tokens_used = tok }
    | _ -> None)

let extract_reply_text (body : string) : string =
  Safe_ops.protect ~default:body (fun () ->
    let json = Yojson.Safe.from_string body in
    match Json_util.get_string json "reply" with
    | Some r -> r
    | None -> body)

let extract_structured (body : string) : Yojson.Safe.t option =
  Safe_ops.protect ~default:None (fun () ->
    let json = Yojson.Safe.from_string body in
    match Json_util.assoc_member_opt "structured" json with
    | None | Some `Null -> None
    | Some v -> Some v)

let non_empty_opt value =
  match String.trim value with
  | "" -> None
  | trimmed -> Some trimmed

(** Typed parse failures for the async ACK envelope.

    The previous [Safe_ops.protect ~default:None] wrapper collapsed two
    distinct failure modes into a single [None]: the keeper returned a
    legitimate reply *without* an ACK contract (queued, running — handled
    separately by the [Streaming] arm of the dispatch match), and the
    backend could not parse the ACK contract at all (malformed JSON,
    missing request_id, missing status, unknown future status). The
    connector could not distinguish "queued" from "parse failed".

    Exposing the failure as a typed sum lets the dispatch site surface
    a deliberate degraded/error ACK shape and log the backend drift,
    rather than silently substituting the keeper's reply text. *)
type ack_parse_failure =
  | Invalid_json of string
  | Missing_request_id
  | Empty_request_id
  | Missing_status
  | Invalid_status of string

let ack_parse_failure_to_string = function
  | Invalid_json detail ->
      Printf.sprintf "invalid json: %s" detail
  | Missing_request_id -> "missing request_id"
  | Empty_request_id -> "empty request_id"
  | Missing_status -> "missing status"
  | Invalid_status raw ->
      Printf.sprintf "unknown status %S (not in the closed status set)" raw

(** Parse the async ACK envelope from a keeper tool response body.

    Returns [Ok request] when the body is a valid JSON object with both
    a non-empty [request_id] and a [status] that maps to one of the
    closed [Gate_protocol.message_request_status] variants.

    Returns [Error reason] otherwise. JSON parse failures are isolated
    from the closed-sum status check so that a malformed envelope is
    surfaced as a backend-degraded path, distinct from a legitimately
    absent ACK field. *)
let extract_message_request_ack ~channel ~channel_user_id ~keeper_name ~metadata body :
    (Gate_protocol.message_request, ack_parse_failure) result =
  let json =
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error detail -> Error (Invalid_json detail)
  in
  match json with
  | Error failure -> Error failure
  | Ok json ->
      let request_id =
        match Json_util.get_string json "request_id" with
        | None -> None
        | Some value -> non_empty_opt value
      in
      (match request_id with
       | None ->
           (match Json_util.get_string json "request_id" with
            | Some _ -> Error Empty_request_id
            | None -> Error Missing_request_id)
       | Some trimmed_request_id -> (
           match Json_util.get_string json "status" with
           | None -> Error Missing_status
           | Some raw ->
               let normalized = String.lowercase_ascii (String.trim raw) in
               (match
                  Gate_protocol.message_request_status_of_string normalized
                with
               | Some status ->
                   let destination_id =
                     match Json_util.get_string json "keeper_name" with
                     | Some value ->
                       (match non_empty_opt value with
                        | Some trimmed -> trimmed
                        | None -> keeper_name)
                     | None -> keeper_name
                   in
                   let request : Gate_protocol.message_request =
                     { request_id = trimmed_request_id
                     ; destination_type = "keeper"
                     ; destination_id
                     ; channel
                     ; actor_id = non_empty_opt channel_user_id
                     ; status
                     ; modalities = [ "text" ]
                     ; transport = non_empty_opt channel
                     ; metadata = ("status_source", "keeper_msg_async") :: metadata
                     }
                   in
                   Ok request
               | None -> Error (Invalid_status normalized))))

let in_flight_metadata (info : Keeper_turn_admission.in_flight_info option) =
  match info with
  | None -> []
  | Some { Keeper_turn_admission.lane; started_at = _ } ->
      [ "in_flight_lane", Keeper_turn_admission.lane_to_string lane ]

let busy_ack_reply_text ?in_flight (request : Gate_protocol.message_request) =
  let status = Gate_protocol.message_request_status_to_string request.status in
  let in_flight_text =
    match in_flight with
    | None -> ""
    | Some { Keeper_turn_admission.lane; started_at = _ } ->
        Printf.sprintf
          " Current turn: %s."
          (Keeper_turn_admission.lane_to_string lane)
  in
  Printf.sprintf
    "%s is busy; your message is %s (request_id=%s).%s"
    request.destination_id
    status
    request.request_id
    in_flight_text

(* ACK text for the RFC-connector-deferred-reply-via-chat-queue chat-queue deferral path. The
   message was durably enqueued onto [Keeper_chat_queue], so its receipt id is
   the correlation handle instead of a [Keeper_msg_async] poll request id. The
   reply is delivered later by the serial consumer through the connector's
   outbound adapter. *)
let busy_ack_reply_text_queued
    ~(admission_rejection : Keeper_turn_admission.rejection)
    ~keeper_name ~receipt_id ~recovery_required_count =
  let in_flight_text =
    match admission_rejection.in_flight with
    | None -> ""
    | Some { Keeper_turn_admission.lane; started_at = _ } ->
        Printf.sprintf
          " Current turn: %s."
          (Keeper_turn_admission.lane_to_string lane)
  in
  match admission_rejection.shutdown_operation_id, recovery_required_count with
  | Some operation_id, 0 ->
      Printf.sprintf
        "%s is stopping under shutdown operation %s; your message is durably \
         queued and will wait for the next active lane (receipt_id=%s).%s"
        keeper_name
        (Keeper_shutdown_types.Operation_id.to_string operation_id)
        receipt_id in_flight_text
  | Some operation_id, recovery_required_count ->
      Printf.sprintf
        "%s is stopping under shutdown operation %s; your message is durably queued, but this Keeper lane also has %d receipt(s) awaiting explicit delivery recovery and cannot dispatch automatically (receipt_id=%s).%s"
        keeper_name
        (Keeper_shutdown_types.Operation_id.to_string operation_id)
        recovery_required_count receipt_id in_flight_text
  | None, 0 ->
      Printf.sprintf
        "%s is busy; your message is queued and will be answered once the current \
        turn finishes (receipt_id=%s).%s"
        keeper_name receipt_id in_flight_text
  | None, recovery_required_count ->
      Printf.sprintf
        "%s accepted your message durably, but this Keeper lane has %d receipt(s) awaiting explicit delivery recovery and cannot dispatch automatically (receipt_id=%s).%s"
        keeper_name recovery_required_count receipt_id in_flight_text

let chat_queue_message_request ~channel ~channel_user_id ~keeper_name
    ~(admission_rejection : Keeper_turn_admission.rejection) ~metadata
    (receipt : Keeper_chat_queue.enqueue_receipt) =
  let receipt_id =
    Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id
  in
  let shutdown_metadata =
    match admission_rejection.shutdown_operation_id with
    | None -> []
    | Some operation_id ->
        [ ( "shutdown_operation_id"
          , Keeper_shutdown_types.Operation_id.to_string operation_id ) ]
  in
  { Gate_protocol.request_id = receipt_id
  ; destination_type = "keeper"
  ; destination_id = keeper_name
  ; channel
  ; actor_id = non_empty_opt channel_user_id
  ; status = Gate_protocol.Queued
  ; modalities = [ "text" ]
  ; transport = non_empty_opt channel
  ; metadata =
      [ "status_source", "keeper_chat_queue"
      ; "receipt_id", receipt_id
      ; "queue_revision", Int64.to_string receipt.revision
      ; "pending_count", string_of_int receipt.pending_count
      ; "inflight_count", string_of_int receipt.inflight_count
      ; ( "recovery_required_count"
        , string_of_int receipt.recovery_required_count )
      ]
      @ shutdown_metadata
      @ metadata
  }

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

let string_assoc_json fields =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) fields)

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

let metadata_value_any keys metadata =
  List.find_map (fun key -> metadata_value key metadata) keys

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

let discord_channel_id ~channel_workspace_id ~metadata =
  match metadata_value_any [ "discord.channel_id"; "discord_channel_id" ] metadata with
  | Some channel_id -> channel_id
  | None -> String.trim channel_workspace_id

let discord_guild_id metadata =
  metadata_value_any [ "discord.guild_id"; "discord_guild_id" ] metadata

(* Slack surface derivation (RFC-0317). The in-process gateway sets
   [channel_workspace_id = channel_id] and mirrors it as [slack.channel_id]
   metadata; prefer the metadata key, fall back to the workspace id. *)
let slack_channel_id ~channel_workspace_id ~metadata =
  match metadata_value_any [ "slack.channel_id"; "slack_channel_id" ] metadata with
  | Some channel_id -> channel_id
  | None -> String.trim channel_workspace_id

let slack_team_id metadata =
  metadata_value_any [ "slack.team_id"; "slack_team_id" ] metadata

let slack_thread_ts metadata =
  metadata_value_any [ "slack.thread_ts"; "slack_thread_ts" ] metadata

let surface_for_channel_context ~connector_kind ~channel ~channel_workspace_id
    ~metadata ?conversation_id ?external_message_id () =
  match connector_kind with
  | Discord ->
      Surface_ref.Discord
        {
          guild_id = discord_guild_id metadata;
          channel_id = discord_channel_id ~channel_workspace_id ~metadata;
          parent_channel_id =
            metadata_value_any
              [ "discord.parent_channel_id"; "discord_parent_channel_id" ]
              metadata;
          thread_id =
            metadata_value_any [ "discord.thread_id"; "discord_thread_id" ] metadata;
        }
  | Slack ->
      Surface_ref.Slack
        {
          team_id = slack_team_id metadata;
          channel_id = slack_channel_id ~channel_workspace_id ~metadata;
          thread_ts = slack_thread_ts metadata;
        }
  | Generic ->
      let label =
        match non_empty_opt channel with
        | Some lane -> lane
        | None -> "gate"
      in
      Surface_ref.Gate
        {
          label;
          address =
            gate_address ~channel ~channel_workspace_id ?conversation_id
              ?external_message_id ();
        }

let conversation_id_for_channel_context ~connector_kind ~channel
    ~channel_workspace_id ~metadata =
  match metadata_value "conversation_id" metadata with
  | Some value -> Some value
  | None -> (
      match connector_kind with
      | Discord ->
          let channel_id = discord_channel_id ~channel_workspace_id ~metadata in
          (match non_empty_opt channel_id with
           | None -> None
           | Some channel_id ->
               let guild_label =
                 match discord_guild_id metadata with
                 | Some guild_id -> guild_id
                 | None -> "dm"
               in
               Some (Printf.sprintf "discord:%s:channel:%s" guild_label channel_id))
      | Slack ->
          (* Same shape as the in-process gateway's [slack_conversation_id] so
             the inbound-recorded conversation and the busy-deferred delivery
             reference one id (Slack threads share the parent channel id). *)
          let channel_id = slack_channel_id ~channel_workspace_id ~metadata in
          (match non_empty_opt channel_id with
           | None -> None
           | Some channel_id -> Some (Printf.sprintf "slack:channel:%s" channel_id))
      | Generic ->
          (match non_empty_opt channel, non_empty_opt channel_workspace_id with
           | Some lane, Some workspace_id ->
               Some (Printf.sprintf "gate:%s:workspace:%s" lane workspace_id)
           | _ -> None))

let external_message_id_for_channel_context ~idempotency_key ~metadata =
  match metadata_value_any [ "external_message_id"; "discord.message_id" ] metadata with
  | Some value -> Some value
  | None -> non_empty_opt idempotency_key

let ensure_metadata key value metadata =
  match value with
  | None -> metadata
  | Some value ->
      if Option.is_some (List.assoc_opt key metadata) then metadata
      else metadata @ [ (key, value) ]

let connector_kind_of_durable = function
  | Discord_connector -> Discord
  | Slack_connector -> Slack

let delivery_key_of_receipt receipt_id =
  match Keeper_chat_delivery_identity.Receipt_ids.of_list [ receipt_id ] with
  | Ok receipt_ids ->
    Ok (Keeper_chat_delivery_identity.Queue_receipts receipt_ids)
  | Error error ->
    Error (Keeper_chat_delivery_identity.Receipt_ids.error_to_string error)

let rejection_snapshot ~base_path ~keeper_name =
  let snapshot = Keeper_turn_admission.snapshot_for ~base_path ~keeper_name in
  { Keeper_turn_admission.waiting = snapshot.snapshot_waiting
  ; in_flight = snapshot.snapshot_in_flight
  ; shutdown_operation_id = snapshot.snapshot_shutdown_operation_id
  }

let terminal_request_status = function
  | Keeper_chat_queue.Delivered _ -> Gate_protocol.Done
  | Keeper_chat_queue.Failed { kind = Keeper_chat_queue.Cancelled; _ } ->
    Gate_protocol.Cancelled
  | Keeper_chat_queue.Failed _ -> Gate_protocol.Failed
  | Keeper_chat_queue.Pending -> Gate_protocol.Queued
  | Keeper_chat_queue.Inflight _ -> Gate_protocol.Running
  | Keeper_chat_queue.Recovery_required _ ->
    Gate_protocol.Acceptance_uncertain

let extra_mentions_for_metadata ~keeper_name metadata =
  match metadata_value "mentions_bound_keeper" metadata with
  | Some "true" ->
    Option.to_list (Keeper_identity.Keeper_id.of_string keeper_name)
  | Some _ | None -> []

let terminal_connector_reply ~redact_text ~channel ~channel_user_id
    ~keeper_name ~metadata ~receipt_id ~revision state =
  let request_id = Keeper_chat_queue.Receipt_id.to_string receipt_id in
  let status = terminal_request_status state in
  let status_text = Gate_protocol.message_request_status_to_string status in
  let message_request : Gate_protocol.message_request =
    { request_id
    ; destination_type = "keeper"
    ; destination_id = keeper_name
    ; channel
    ; actor_id = non_empty_opt channel_user_id
    ; status
    ; modalities = [ "text" ]
    ; transport = non_empty_opt channel
    ; metadata =
        [ "status_source", "keeper_chat_queue"
        ; "receipt_id", request_id
        ; "queue_revision", Int64.to_string revision
        ; "source_event_replayed", "true"
        ]
        @ metadata
    }
  in
  Gate_protocol.Reply
    { content =
        redact_text
          (Printf.sprintf
             "%s already settled this exact source event (receipt_id=%s, status=%s)."
             keeper_name request_id status_text)
    ; structured = None
    ; stats = None
    ; message_request = Some message_request
    }

let accept_connector ~connector ~clock ~config ~channel ~channel_user_id
    ~channel_user_name ~channel_workspace_id ~keeper_name ~idempotency_key
    ~metadata ~content =
  let keeper_name = String.trim keeper_name in
  let connector_kind = connector_kind_of_durable connector in
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:config.Workspace.base_path
      ~keeper_name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
  let conversation_id =
    conversation_id_for_channel_context ~connector_kind ~channel
      ~channel_workspace_id ~metadata
  in
  let external_message_id =
    external_message_id_for_channel_context ~idempotency_key ~metadata
  in
  let metadata =
    metadata
    |> ensure_metadata "conversation_id" conversation_id
    |> ensure_metadata "external_message_id" external_message_id
  in
  let surface =
    surface_for_channel_context ~connector_kind ~channel ~channel_workspace_id
      ~metadata ?conversation_id ?external_message_id ()
  in
  let extra_mentions = extra_mentions_for_metadata ~keeper_name metadata in
  let slack_reply_thread_ts =
    match slack_thread_ts metadata with
    | Some thread_ts -> Some thread_ts
    | None ->
      metadata_value_any [ "slack.message_ts"; "slack_message_ts" ] metadata
  in
  let source =
    match
      route_busy_connector connector_kind
        ~channel_id:channel_workspace_id ~user_id:channel_user_id
        ~user_name:channel_user_name ~team_id:(slack_team_id metadata)
        ~thread_ts:slack_reply_thread_ts
    with
    | `Enqueue_chat_queue source -> Ok source
    | `Async_poll ->
      Error "durable connector resolved to the async poll route"
  in
  match
    Keeper_chat_delivery_identity.Request_id.of_string idempotency_key,
    source
  with
  | Error detail, _ | _, Error detail ->
    Gate_protocol.Keeper_error_result (redact_text detail)
  | Ok request_id, Ok source ->
    let receipt_id = Keeper_chat_queue.Receipt_id.of_request_id request_id in
    (match delivery_key_of_receipt receipt_id with
     | Error detail ->
       Gate_protocol.Keeper_error_result (redact_text detail)
     | Ok delivery_key ->
       let opt value =
         match String.trim value with
         | "" -> None
         | value -> Some value
       in
       (match
          Keeper_chat_store.append_user_message_once
            ~base_dir:config.Workspace.base_path ~keeper_name ~delivery_key
            ~content:(String.trim content) ~surface ?conversation_id
            ?external_message_id
            ~speaker:
              { Keeper_chat_store.speaker_id = opt channel_user_id
              ; speaker_name = opt channel_user_name
              ; speaker_authority = Keeper_chat_store.External
              }
            ~extra_mentions ()
        with
        | Error detail ->
          Gate_protocol.Keeper_error_result (redact_text detail)
        | Ok append_result ->
          let row_id, appended =
            match append_result with
            | Keeper_chat_store.Appended { row_id } -> row_id, true
            | Already_present { row_id } -> row_id, false
          in
          if appended then
            Keeper_chat_broadcast.chat_appended
              ~keeper_name ~source:(String.trim channel) ();
          (match
             Keeper_chat_queue.enqueue_with_receipt ~keeper_name ~receipt_id
               { Keeper_chat_queue.content = String.trim content
               ; user_blocks = []
               ; attachments = []
               ; timestamp = Eio.Time.now clock
               ; source
               ; user_row_origin =
                   Keeper_chat_store.Already_persisted { row_id }
               }
           with
           | Ok receipt ->
             let admission_rejection =
               rejection_snapshot
                 ~base_path:config.Workspace.base_path
                 ~keeper_name
             in
             let message_request =
               chat_queue_message_request ~channel ~channel_user_id
                 ~keeper_name ~admission_rejection ~metadata receipt
             in
             Gate_protocol.Reply
               { content =
                   redact_text
                     (busy_ack_reply_text_queued ~admission_rejection
                        ~keeper_name ~receipt_id:message_request.request_id
                        ~recovery_required_count:
                          receipt.recovery_required_count)
               ; structured = None
               ; stats = None
               ; message_request = Some message_request
               }
           | Error
               (Keeper_chat_queue.Receipt_already_terminal
                  { receipt_id; state }) ->
             (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id with
              | Ok { revision; receipt = Some _ } ->
                terminal_connector_reply ~redact_text ~channel
                  ~channel_user_id ~keeper_name ~metadata ~receipt_id
                  ~revision state
              | Ok { receipt = None; _ } ->
                Gate_protocol.Keeper_error_result
                  (redact_text
                     "terminal connector receipt disappeared during lookup")
              | Error error ->
                Gate_protocol.Keeper_error_result
                  (redact_text
                     (Keeper_chat_queue.mutation_error_to_string error)))
           | Error error ->
             Gate_protocol.Keeper_error_result
               (redact_text
                  (Keeper_chat_queue.mutation_error_to_string error)))))

let persist_connector_assistant_reply ~base_dir ~keeper_name ~source ?surface
    ?conversation_id ?turn_ref ~reply () =
  let content = String.trim reply in
  if content <> "" then begin
    let surface =
      match surface with
      | Some surface -> surface
      | None -> Surface_ref.Gate { label = source; address = [] }
    in
    (* RFC-0233 §7: [turn_ref] is the join key the keeper minted into the
       reply payload, carried onto this connector turn's assistant row. *)
    Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name
      ~content ~surface ?conversation_id ?turn_ref ();
    Keeper_chat_broadcast.chat_appended ~keeper_name ~source ~content ()
  end

(* Trailing [()] keeps [?on_text_snapshot] erasable (warning 16): the wrappers
   below either pass it ([dispatch_with_text_snapshot]) or omit it so it defaults
   to [None] ([dispatch]). Without the unit the optional leaks into [dispatch]'s
   inferred type and breaks the .mli signature. Do not drop the [()]. *)
let dispatch_core ?on_text_snapshot ?(connector_kind = Generic) ~submission_owner
    ~sw ~clock ~proc_mgr ~net ~publication_recovery_provider ~config
    ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
    ~keeper_name ~idempotency_key ~metadata ~content () =
  let keeper_name = String.trim keeper_name in
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:config.Workspace.base_path
      ~keeper_name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
  let redact_json = Keeper_secret_redaction.redact_json redaction in
  let agent_name =
    agent_name_for_channel_actor ~channel ~channel_workspace_id ~channel_user_id
  in
  let submitted_by =
    match submission_owner with
    | Authenticated_caller caller -> caller
    | Channel_actor -> agent_name
  in
  (* Use filesystem-safe sanitizer: this key is later used as a directory
     component in session_dir. An unsanitized channel_workspace_id with '..' or '/'
     would escape the intended traces/channels/ subtree. Discord passes
     numeric IDs so this is defensive for future integrations (webhooks,
     custom channels) that could pass attacker-controlled values. *)
  let channel_session_key =
    Printf.sprintf "%s_%s"
      (filesystem_safe_or_unknown channel)
      (filesystem_safe_or_unknown channel_workspace_id)
  in
  (* RFC-0226: the gate inbound boundary is the sole recorder of
     connector user lines. Recording happens here — post
     validation/dedup ([Channel_gate.handle_inbound]), pre turn — so a
     failed or silent turn cannot drop the inbound message. The final
     connector reply is appended below after the direct-delivery stream returns
     the keeper's direct reply. The user line carries the raw [content];
     the contextualized wrapper below is turn input, not conversation
     history. *)
  let lane = String.trim channel in
  let opt value = match String.trim value with "" -> None | v -> Some v in
  let conversation_id =
    conversation_id_for_channel_context ~connector_kind ~channel
      ~channel_workspace_id ~metadata
  in
  let external_message_id =
    external_message_id_for_channel_context ~idempotency_key ~metadata
  in
  let metadata =
    metadata
    |> ensure_metadata "conversation_id" conversation_id
    |> ensure_metadata "external_message_id" external_message_id
  in
  let surface =
    surface_for_channel_context ~connector_kind ~channel ~channel_workspace_id
      ~metadata ?conversation_id ?external_message_id ()
  in
  (* RFC-0232 §3.3: the connector decoded a structured mention of this
     channel's bound keeper (e.g. Discord <@snowflake>, invisible to
     the content token parser), so the recorder persists it as an
     explicit mention of the lane owner. *)
  let extra_mentions = extra_mentions_for_metadata ~keeper_name metadata in
  Keeper_chat_store.append_user_message
    ~base_dir:config.Workspace.base_path
    ~keeper_name
    ~content:(String.trim content)
    ~surface
    ?conversation_id
    ?external_message_id
    ~speaker:
      { Keeper_chat_store.speaker_id = opt channel_user_id
      ; speaker_name = opt channel_user_name
      ; speaker_authority = Keeper_chat_store.External
      }
    ~extra_mentions
    ();
  Keeper_chat_broadcast.chat_appended
    ~keeper_name ~source:lane ();
  let args =
    `Assoc [
      ("name", `String keeper_name);
      ( "message",
        `String
          (contextualize_message ~channel ~channel_user_id ~channel_user_name
             ~channel_workspace_id ~metadata ~content) );
      ("direct_reply", `Bool true);
      ("channel_session_key", `String channel_session_key);
      (* RFC-0223 P1: raw connector identity, consumed by
         [Keeper_tool_surface_ops.append_direct_chat_pair_if_reply] so the
         persisted chat line carries the lane label and speaker instead
         of the generic "agent" source. Internal-only args, same class
         as [direct_reply] / [channel_session_key]. *)
      ("channel", `String channel);
      ("channel_workspace_id", `String channel_workspace_id);
      ("channel_user_id", `String channel_user_id);
      ("channel_user_name", `String channel_user_name);
      ("channel_metadata", string_assoc_json metadata);
    ]
  in
  let keeper_ctx : _ Keeper_tool_surface.context = {
    config;
    agent_name;
    sw;
    clock;
    proc_mgr;
    net;
    publication_recovery_provider;
  } in
  let start_mtime = Mtime_clock.now () in
  let on_text_delta =
    match on_text_snapshot with
    | None -> (fun _ -> ())
    | Some publish_snapshot ->
        let streamed_text = Buffer.create 1024 in
        fun delta ->
          Buffer.add_string streamed_text delta;
          let snapshot = redact_text (Buffer.contents streamed_text) in
          (try publish_snapshot snapshot with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn ->
               Log.Server.warn
                 "channel gate text snapshot callback failed (keeper=%s): %s"
                 keeper_name (Printexc.to_string exn))
  in
  let slack_reply_thread_ts =
    match slack_thread_ts metadata with
    | Some thread_ts -> Some thread_ts
    | None -> metadata_value_any [ "slack.message_ts"; "slack_message_ts" ] metadata
  in
  let defer_to_existing_work
      (admission_rejection : Keeper_turn_admission.rejection) =
    match
      route_busy_connector connector_kind
        ~channel_id:channel_workspace_id ~user_id:channel_user_id
        ~user_name:channel_user_name ~team_id:(slack_team_id metadata)
        ~thread_ts:slack_reply_thread_ts
    with
    | `Enqueue_chat_queue source ->
      (* RFC-connector-deferred-reply-via-chat-queue: route accepted connector
         input onto the durable queue whenever the authoritative if-free
         admission reports Busy. This includes a receipt committed or leased
         after any outer observation but before the turn slot was acquired. *)
      (match
         Keeper_chat_queue.enqueue ~keeper_name
           { Keeper_chat_queue.content = String.trim content
           ; user_blocks = []
           ; attachments = []
           ; timestamp = Eio.Time.now clock
           ; source
           ; user_row_origin = Keeper_chat_store.Already_persisted_upstream
           }
       with
       | Ok receipt -> `Queued_to_chat_lane (admission_rejection, receipt)
       | Error error ->
         Log.Server.error
           "channel gate durable chat enqueue failed (keeper=%s, lane=%s): %s"
           keeper_name lane
           (Keeper_chat_queue.mutation_error_to_string error);
         `Chat_queue_error error)
    | `Async_poll ->
      `Async_ack
        ( admission_rejection.in_flight
        , Some
            (Keeper_tool_surface.dispatch_keeper_msg
               ~submitted_by
               keeper_ctx
               ~args) )
  in
  let dispatch_result =
    (* The admission boundary, not a route-level peek, owns the FIFO decision.
       It rechecks the durable queue after acquiring the Keeper turn slot. *)
    match
      Keeper_tool_surface.dispatch_keeper_msg_stream_if_free
        ~on_text_delta keeper_ctx ~args
    with
    | `Ran result -> `Streaming result
    | `Busy admission_rejection ->
      defer_to_existing_work admission_rejection
  in
  match dispatch_result with
  | `Async_ack (in_flight, Some result) when not (Tool_result.is_failed result) ->
      let body = Tool_result.message result in
      let duration_ms =
        Mtime.Span.to_uint64_ns (Mtime.span (Mtime_clock.now ()) start_mtime)
        |> Int64.div 1_000_000L
        |> Int64.to_int
      in
      let ack_with_in_flight =
        extract_message_request_ack ~channel ~channel_user_id ~keeper_name
          ~metadata:(metadata @ in_flight_metadata in_flight)
          body
      in
      let message_request, reply =
        match ack_with_in_flight with
        | Ok request ->
            ( Some request
            , busy_ack_reply_text ?in_flight request )
        | Error failure ->
            (* Backend drift: the keeper accepted the message into its
               async queue but the wire envelope we expected is missing or
               malformed. Do not silently substitute the keeper's reply
               body — that collapses the queued state with a degraded
               parse path and breaks the connector's "is this queued?"
               decision. Log the parse failure with the same
               [status_source=keeper_msg_async] surface so on-call can
               triage whether the keeper contract regressed or the body
               was truncated mid-flight, and emit a degraded reply that
               names the parse failure without leaking the raw body. *)
            Log.Server.warn
              "channel gate async ACK parse failure (keeper=%s, lane=%s, \
               request_id_context=%s, failure=%s): connector will see a \
               degraded ACK, not the keeper's reply body."
              keeper_name lane (extract_reply_text body |> String.length |> string_of_int)
              (ack_parse_failure_to_string failure);
            ( None
            , Printf.sprintf
                "%s is busy; the gate could not parse the async ACK \
                 envelope (%s). Your message was forwarded to the keeper, \
                 but no durable request id is available. Treat this as a \
                 transient backend degradation rather than a queued reply."
                keeper_name
                (ack_parse_failure_to_string failure) )
      in
      let reply = redact_text reply in
      let structured = Option.map redact_json (extract_structured body) in
      let stats =
        Some
          { Gate_protocol.model_used = "runtime"
          ; duration_ms
          ; tokens_used = 0
          }
      in
      Gate_protocol.Reply { content = reply; structured; stats; message_request }
  | `Queued_to_chat_lane (admission_rejection, receipt) ->
      (* RFC-connector-deferred-reply-via-chat-queue: the message was enqueued onto [Keeper_chat_queue]; the
         connector gets a busy ACK now and the deferred reply later via the
         serial consumer's outbound adapter. The existing [message_request]
         envelope carries the durable receipt id and queue revision so the
         connector can correlate that later delivery. *)
      let duration_ms =
        Mtime.Span.to_uint64_ns (Mtime.span (Mtime_clock.now ()) start_mtime)
        |> Int64.div 1_000_000L
        |> Int64.to_int
      in
      let message_request =
        chat_queue_message_request ~channel ~channel_user_id ~keeper_name
          ~admission_rejection ~metadata receipt
      in
      let reply =
        redact_text
          (busy_ack_reply_text_queued ~admission_rejection ~keeper_name
             ~receipt_id:message_request.request_id
             ~recovery_required_count:receipt.recovery_required_count)
      in
      let stats =
        Some { Gate_protocol.model_used = "runtime"; duration_ms; tokens_used = 0 }
      in
      Gate_protocol.Reply
        { content = reply
        ; structured = None
        ; stats
        ; message_request = Some message_request
        }
  | `Chat_queue_error error ->
      Gate_protocol.Keeper_error_result
        (redact_text
           (Printf.sprintf
              "%s is busy; your message was not queued because the durable chat queue rejected it: %s"
              keeper_name
              (Keeper_chat_queue.mutation_error_to_string error)))
  | `Streaming (Some result) when not (Tool_result.is_failed result) ->
      let body = Tool_result.message result in
      let duration_ms =
        Mtime.Span.to_uint64_ns (Mtime.span (Mtime_clock.now ()) start_mtime)
        |> Int64.div 1_000_000L
        |> Int64.to_int
      in
      let reply = extract_reply_text body |> redact_text in
      let structured = Option.map redact_json (extract_structured body) in
      let stats = match extract_turn_stats body with
        | Some s -> Some { s with duration_ms }
        | None -> Some { Gate_protocol.model_used = "runtime"; duration_ms; tokens_used = 0 }
      in
      (* RFC-0233 §7: pull the turn's join key out of the same reply payload
         (parse, don't repair) so the connector assistant row joins to its
         Turn_record. *)
      let turn_ref =
        Keeper_turn_outcome.turn_ref_of_reply_payload
          (try Some (Yojson.Safe.from_string body)
           with Yojson.Json_error _ -> None)
      in
      persist_connector_assistant_reply
        ~base_dir:config.Workspace.base_path ~keeper_name ~source:lane
        ~surface ?conversation_id ?turn_ref ~reply ();
      Gate_protocol.Reply { content = reply; structured; stats; message_request = None }
  | `Async_ack (_, Some result) | `Streaming (Some result) ->
      Gate_protocol.Keeper_error_result (redact_text (Tool_result.message result))
  | `Async_ack (_, None) | `Streaming None ->
      Gate_protocol.Unavailable_result

(* [connector_kind] is a required labelled argument (not optional): these
   wrappers are partially applied to produce a [Channel_gate.dispatch_fn] /
   [streaming_dispatch_fn], so a leading erasable optional would either fail to
   erase (warning 16) or linger into the resulting function type and not match
   the connector-neutral [dispatch_fn] shape. Requiring the connector to name
   its kind also makes a missing wiring a compile error rather than a silent
   [Generic] default. *)
let dispatch ~connector_kind ~submission_owner ~sw ~clock ~proc_mgr ~net
    ~publication_recovery_provider ~config
    ~channel
    ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
    ~idempotency_key ~metadata ~content =
  match connector_kind with
  | Discord ->
    accept_connector ~connector:Discord_connector ~clock ~config ~channel
      ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
      ~idempotency_key ~metadata ~content
  | Slack ->
    accept_connector ~connector:Slack_connector ~clock ~config ~channel
      ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
      ~idempotency_key ~metadata ~content
  | Generic ->
    dispatch_core ~connector_kind ~submission_owner ~sw ~clock ~proc_mgr ~net
      ~publication_recovery_provider ~config ~channel ~channel_user_id
      ~channel_user_name ~channel_workspace_id ~keeper_name ~idempotency_key
      ~metadata ~content ()

let dispatch_with_text_snapshot ~connector_kind ~submission_owner
    ~on_text_snapshot ~sw ~clock ~proc_mgr ~net ~publication_recovery_provider
    ~config ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
    ~keeper_name ~idempotency_key ~metadata ~content =
  match connector_kind with
  | Discord ->
    accept_connector ~connector:Discord_connector ~clock ~config ~channel
      ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
      ~idempotency_key ~metadata ~content
  | Slack ->
    accept_connector ~connector:Slack_connector ~clock ~config ~channel
      ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
      ~idempotency_key ~metadata ~content
  | Generic ->
    dispatch_core ~connector_kind ~submission_owner ~on_text_snapshot ~sw
      ~clock ~proc_mgr ~net ~publication_recovery_provider ~config ~channel
      ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
      ~idempotency_key ~metadata ~content ()
