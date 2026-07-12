(* See .mli for high-level shape. *)

module Gw = Discord_gateway_client
module State = Channel_gate_discord_state

(* Intents requested at IDENTIFY time. Same set as RFC-0203 §Modules
   and the previous sidecar configuration. *)
let default_intents : Gw.intent list =
  [ Gw.Guilds
  ; Gw.Guild_messages
  ; Gw.Message_content
  ; Gw.Guild_message_reactions
  ; Gw.Direct_messages
  ; Gw.Direct_message_reactions
  ]

(* ---------------------------------------------------------------- *)
(* Env-driven config                                                *)
(* ---------------------------------------------------------------- *)

let trimmed_env name =
  match Sys.getenv_opt name with
  | None -> None
  | Some raw ->
    let t = String.trim raw in
    if String.equal t "" then None else Some t

let bot_token_opt () = trimmed_env "DISCORD_BOT_TOKEN"

(* Default trigger policy when none is configured (empty/unset). The
   "quiet, mention-triggered bot" baseline per RFC-0203. *)
let default_trigger_policy : Gw.trigger_policy = Gw.Mention_or_thread

(* Parse a configured trigger policy. Delegates to the single strict
   parser in Discord_gateway_state so config and the (test-covered)
   canonical grammar can never drift. An empty value is "unset" and
   silently takes the default; a non-empty value that fails to parse
   (typo, removed variant) is logged and falls back to the default
   rather than being silently coerced into a policy the operator did
   not write. *)
let parse_trigger_policy raw : Gw.trigger_policy =
  let s = String.trim raw in
  if String.equal s "" then default_trigger_policy
  else
    match Discord_gateway_state.parse_trigger_policy s with
    | Ok policy -> policy
    | Error msg ->
      Log.Server.warn
        "discord trigger_policy %S rejected (%s); using default %s"
        s msg
        (Discord_gateway_state.trigger_policy_to_string default_trigger_policy);
      default_trigger_policy

let resolved_trigger_policy () =
  let from_toml () =
    try
      let resolution = Config_dir_resolver.resolve () in
      let toml_path =
        Filename.concat resolution.Config_dir_resolver.config_root.path
          Config_dir_resolver.runtime_toml_filename
      in
      if Sys.file_exists toml_path then
        let tbl = Otoml.Parser.from_file toml_path in
        Otoml.find_opt tbl Otoml.get_string [ "discord"; "trigger_policy" ]
      else None
    with _ -> None
  in
  match from_toml () with
  | Some raw -> parse_trigger_policy raw
  | None ->
    (match trimmed_env "MASC_DISCORD_TRIGGER_POLICY" with
    | None -> Gw.Mention_or_thread
    | Some raw -> parse_trigger_policy raw)

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

(* Discord typing indicators expire after 10s. Refresh below that window while
   the accepted inbound is waiting for keeper output. *)
let typing_refresh_interval_s = 8.0

let trigger_typing_once ~channel_id =
  match State.trigger_typing ~channel_id () with
  | Ok () -> ()
  | Error State.Missing_token ->
      Log.Server.debug
        "discord trigger_typing skipped: DISCORD_BOT_TOKEN is unset"
  | Error e ->
      Log.Server.debug
        "discord trigger_typing failed (channel=%s): %s"
        channel_id
        (Format.asprintf "%a" State.pp_send_error e)

(* Discord exposes only a typing indicator; MASC still treats
   "response requested", "waiting for a keeper response", and "streaming
   response text" as separate runtime phases. This helper projects only the
   waiting phase to Discord UX without making typing a MASC state source of
   truth. If the keeper is already running another lane, the dispatch waits
   behind the same turn-admission slot; this refresh loop is the Discord-side
   projection of that derived Busy/waiting state. Streaming text should be a
   separate edit-loop transport. *)
let with_response_wait_typing_indicator ~clock ~channel_id f =
  trigger_typing_once ~channel_id;
  Eio.Switch.run (fun typing_sw ->
    let done_p, done_r = Eio.Promise.create () in
    let finish () = Eio.Promise.resolve done_r () in
    Eio.Fiber.fork ~sw:typing_sw (fun () ->
      let rec loop () =
        match
          Eio.Fiber.first
            (fun () ->
              Eio.Promise.await done_p;
              `Done)
            (fun () ->
              Eio.Time.sleep clock typing_refresh_interval_s;
              `Tick)
        with
        | `Done -> ()
        | `Tick ->
            trigger_typing_once ~channel_id;
            loop ()
      in
      loop ());
    match f () with
    | result ->
        finish ();
        result
    | exception exn ->
        finish ();
        raise exn)

type stream_finish =
  | Stream_not_started
  | Stream_completed
  | Stream_final_edit_failed of State.send_error
  | Stream_overflow_send_failed of State.send_error

type discord_stream_reply =
  { channel_id : string
  ; reply_to_message_id : string
  ; mutable message_id : string option
  ; mutable last_edit_time : float
  ; mutable last_edited_text : string
  ; mutable disabled : bool
  }

let streaming_edit_interval_s = 1.0

let make_discord_stream_reply ~channel_id ~reply_to_message_id =
  { channel_id
  ; reply_to_message_id
  ; message_id = None
  ; last_edit_time = 0.0
  ; last_edited_text = ""
  ; disabled = false
  }

let discord_stream_content snapshot =
  snapshot
  |> Observability_redact.redact_text
  |> Discord_rest_client.truncate_to_limit

let log_stream_error stage state error =
  Log.Server.warn
    "discord streaming %s failed (channel=%s reply_to=%s): %s"
    stage state.channel_id state.reply_to_message_id
    (Format.asprintf "%a" State.pp_send_error error)

let publish_discord_stream_snapshot state snapshot =
  if not state.disabled then begin
    let content = discord_stream_content snapshot in
    if not (String.equal content "" || String.equal content state.last_edited_text)
    then
      match state.message_id with
      | None -> (
          match
            State.send_message ~channel_id:state.channel_id ~content
              ~reply_to_message_id:state.reply_to_message_id ()
          with
          | Ok message_id ->
              state.message_id <- Some message_id;
              state.last_edit_time <- Unix.gettimeofday ();
              state.last_edited_text <- content
          | Error error ->
              state.disabled <- true;
              log_stream_error "initial send" state error)
      | Some message_id ->
          let elapsed = Unix.gettimeofday () -. state.last_edit_time in
          if elapsed >= streaming_edit_interval_s then
            match
              State.edit_message ~channel_id:state.channel_id ~message_id
                ~content ()
            with
            | Ok () ->
                state.last_edit_time <- Unix.gettimeofday ();
                state.last_edited_text <- content
            | Error error ->
                log_stream_error "edit" state error
  end

let finish_discord_stream_reply state ~final_content =
  match state.message_id with
  | None -> Stream_not_started
  | Some message_id ->
      let redacted = Observability_redact.redact_text final_content in
      let head, overflow =
        Discord_rest_client.split_at_codepoint redacted
          ~limit:Discord_rest_client.message_content_limit
      in
      let edit_result =
        if String.equal head state.last_edited_text then Ok ()
        else
          State.edit_message ~channel_id:state.channel_id ~message_id
            ~content:head ()
      in
      (match edit_result with
       | Error error ->
           log_stream_error "final edit" state error;
           Stream_final_edit_failed error
       | Ok () ->
           state.last_edited_text <- head;
           if String.equal overflow "" then Stream_completed
           else
             match
               State.send_message ~channel_id:state.channel_id
                 ~content:overflow ()
             with
             | Ok _ -> Stream_completed
             | Error error ->
                 log_stream_error "overflow send" state error;
                 Stream_overflow_send_failed error)

let metadata_opt key = function
  | None -> []
  | Some value ->
      let value = String.trim value in
      if value = "" then [] else [ (key, value) ]

let metadata_bool key value = [ (key, string_of_bool value) ]

let discord_conversation_id ~guild_id ~channel_id =
  let guild_label =
    match guild_id with
    | Some guild_id when not (String.equal (String.trim guild_id) "") ->
        guild_id
    | Some _ | None -> "dm"
  in
  Printf.sprintf "discord:%s:channel:%s" guild_label channel_id

let discord_attention_surface ~guild_id ~channel_id =
  Keeper_external_attention.Discord
    { guild_id; channel_id; parent_channel_id = None; thread_id = None }

let discord_chat_metadata ~guild_id ~channel_id ~message_id =
  [
    ("conversation_id", discord_conversation_id ~guild_id ~channel_id);
    ("external_message_id", message_id);
  ]

let record_external_attention ~base_dir ~keeper_name ~guild_id ~channel_id
      ~message_id ~author_id ~author_name ~content ~mentions_bot ~route ~urgency
  =
  let surface = discord_attention_surface ~guild_id ~channel_id in
  let conversation_id = discord_conversation_id ~guild_id ~channel_id in
  let dedupe_key =
    Printf.sprintf "discord:%s:%s" conversation_id message_id
  in
  let event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key in
  let item : Keeper_external_attention.item =
    { event_id
    ; dedupe_key
    ; keeper_name
    ; conversation = { conversation_id; surface }
    ; external_message =
        Some { surface; message_id; reply_to_message_id = None }
    ; source_label = State.channel
    ; actor =
        { actor_id = Some author_id
        ; display_name = author_name
        ; authority = Keeper_chat_store.External
        }
    ; urgency
    ; content_preview = content
    ; content_ref = None
    ; received_at =
        Unix.gettimeofday ()
        (* NDT-OK: Discord ingress wall-clock timestamp. The value is
           persisted as event evidence and for pending-order projection;
           it does not branch deterministic policy. *)
    ; metadata =
        [ "route", route
        ; "mentions_bot", string_of_bool mentions_bot
        ; "discord_channel_id", channel_id
        ]
        @ metadata_opt "discord_guild_id" guild_id
    }
  in
  match Keeper_external_attention.record ~base_path:base_dir item with
  | `Recorded -> Some event_id
  | `Duplicate item -> Some item.event_id
  | `Error error ->
      Log.Server.warn
        "discord external attention record failed (channel=%s keeper=%s): %s"
        channel_id keeper_name error;
      None

let mark_attention_resolved ~base_dir ~keeper_name ~event_id ~reason =
  match
    Keeper_external_attention.mark_resolved
      ~base_path:base_dir
      ~keeper_name
      ~event_ids:[ event_id ]
      ~reason
      ()
  with
  | Ok () -> ()
  | Error error ->
      Log.Server.warn
        "discord external attention resolve failed (keeper=%s event=%s): %s"
        keeper_name event_id error

let resolve_binding_for_message ~channel_id ~message_reference_channel_id =
  match State.resolve_keeper_for_channel ~channel_id with
  | Some resolution -> Some (resolution, [])
  | None -> (
      match message_reference_channel_id with
      | None -> None
      | Some reference_channel_id ->
          let reference_channel_id = String.trim reference_channel_id in
          if reference_channel_id = "" || String.equal reference_channel_id channel_id
          then None
          else
            match State.resolve_keeper_for_channel ~channel_id:reference_channel_id with
            | None -> None
            | Some resolution ->
                Some
                  ( {
                      State.keeper_name = resolution.State.keeper_name;
                      incoming_channel_id = channel_id;
                      bound_channel_id = resolution.bound_channel_id;
                      via_parent = true;
                    },
                    [ ("discord.binding_reference_channel_id", reference_channel_id) ] ))

let handle_message_create ~dispatch
      ~clock
      ~(channel_id : string) ~(message_id : string)
      ~(guild_id : string option)
      ~base_dir
      ~(author_id : string) ~(author_name : string option)
      ~(content : string)
      ~(mentions_bot : bool)
      ~(explicit_mentions_bot : bool)
      ~(message_reference_channel_id : string option)
      ~(message_reference_message_id : string option)
      ~(referenced_message_author_id : string option) =
  match resolve_binding_for_message ~channel_id ~message_reference_channel_id with
  | None ->
    (* No binding for this channel — drop quietly. The bot may be in
       channels it isn't bound to (e.g. server-wide guild messages). *)
    Discord_observability.record_inbound_dispatch
      Discord_observability.Dropped_unbound;
    ()
  | Some (resolution, resolution_metadata) ->
    let keeper_name = resolution.State.keeper_name in
    let metadata =
      discord_chat_metadata ~guild_id ~channel_id ~message_id
      @ [ ("discord.channel_id", channel_id)
      ; ("discord.message_id", message_id)
      ; ("discord.bound_channel_id", resolution.bound_channel_id)
      ; ("discord.binding_via_parent", string_of_bool resolution.via_parent)
      ]
      @ resolution_metadata
      @ metadata_opt "discord.guild_id" guild_id
      @ metadata_bool "discord.mentions_bot" mentions_bot
      @ metadata_bool "discord.explicit_mentions_bot" explicit_mentions_bot
      (* Connector-neutral key consumed by the gate recorder: the
         structured mentions array named this channel's bound keeper
         (its bot user), so the persisted user line carries an explicit
         mention even when the text has no "@name" token (Discord
         renders mentions as <@snowflake>, invisible to the token
         parser).  RFC-0232 §3.3. *)
      @ metadata_bool "mentions_bound_keeper" mentions_bot
      @ metadata_opt "discord.message_reference_channel_id"
          message_reference_channel_id
      @ metadata_opt "discord.message_reference_message_id"
          message_reference_message_id
      @ metadata_opt "discord.referenced_message_author_id"
          referenced_message_author_id
    in
    let urgency =
      if mentions_bot then Keeper_external_attention.Mention
      else
        match guild_id with
        | None -> Keeper_external_attention.Direct_message
        | Some _ -> Keeper_external_attention.Ambient
    in
    let attention_event_id =
      record_external_attention ~base_dir ~keeper_name ~guild_id ~channel_id
        ~message_id ~author_id ~author_name ~content ~mentions_bot
        ~route:"triggered" ~urgency
    in
    let msg : Channel_gate.inbound_message =
      { channel = State.channel
      ; channel_user_id = author_id
      ; channel_user_name = Option.value author_name ~default:author_id
        (* NDT-OK: display name ([global_name] else [username], RFC-0223
           P1); the snowflake stands in only for malformed payloads
           missing both — the gate contract requires a non-empty name,
           and the id fallback preserves the pre-P1 behavior. *)
      ; channel_workspace_id = channel_id
      ; keeper_name
      ; content
      ; idempotency_key = Printf.sprintf "discord-msg-%s" message_id
      ; metadata
      }
    in
    let stream_reply =
      make_discord_stream_reply ~channel_id ~reply_to_message_id:message_id
    in
    let on_text_snapshot =
      publish_discord_stream_snapshot stream_reply
    in
    (match
       with_response_wait_typing_indicator ~clock ~channel_id (fun () ->
         Channel_gate.handle_inbound_streaming ~dispatch ~on_text_snapshot msg)
     with
     | Error gate_err ->
       (match gate_err with
        | Channel_gate.Dispatch_unavailable ->
          let notice =
            Printf.sprintf "⚠️ `%s` 오프라인" keeper_name
          in
          (match State.send_message ~channel_id ~content:notice
                  ~reply_to_message_id:message_id () with
           | Ok _ ->
             Discord_observability.record_inbound_dispatch
               Discord_observability.Dispatch_unavailable;
             Discord_observability.record_reply
               Discord_observability.Reply_send_ok
           | Error e ->
             Discord_observability.record_inbound_dispatch
               Discord_observability.Dispatch_unavailable;
             Discord_observability.record_reply
               Discord_observability.Reply_send_failed;
             Log.Server.error
               "discord send unavailable notice failed (channel=%s): %s"
               channel_id
               (Format.asprintf "%a" State.pp_send_error e));
         Log.Server.info
           "discord inbound -> keeper unavailable, notice sent (channel=%s keeper=%s)"
           channel_id keeper_name
        | Channel_gate.Validation _
        | Channel_gate.Keeper_error _
        | Channel_gate.Internal _ ->
          Discord_observability.record_inbound_dispatch
            Discord_observability.Gate_error;
          Log.Server.warn
            "discord inbound -> keeper failed (channel=%s keeper=%s): %s"
            channel_id keeper_name
            (Channel_gate.gate_error_to_string gate_err))
     | Ok out ->
       if String.equal out.content "" then begin
         (match attention_event_id with
          | Some event_id ->
              mark_attention_resolved ~base_dir ~keeper_name ~event_id
                ~reason:"discord_empty_reply"
          | None -> ());
         Discord_observability.record_inbound_dispatch
           Discord_observability.Empty_reply;
         Discord_observability.record_reply Discord_observability.Reply_empty
       end
       else
         (match finish_discord_stream_reply stream_reply ~final_content:out.content with
          | Stream_completed ->
              (match attention_event_id with
               | Some event_id ->
                   mark_attention_resolved ~base_dir ~keeper_name ~event_id
                     ~reason:"discord_reply_streamed"
               | None -> ());
              Discord_observability.record_inbound_dispatch
                Discord_observability.Reply_sent;
              Discord_observability.record_reply
                Discord_observability.Reply_send_ok
          | Stream_not_started | Stream_final_edit_failed _ ->
              (match State.send_message ~channel_id ~content:out.content ~reply_to_message_id:message_id () with
               | Ok _ ->
                 (match attention_event_id with
                  | Some event_id ->
                      mark_attention_resolved ~base_dir ~keeper_name ~event_id
                        ~reason:"discord_reply_sent"
                  | None -> ());
                 Discord_observability.record_inbound_dispatch
                   Discord_observability.Reply_sent;
                 Discord_observability.record_reply
                   Discord_observability.Reply_send_ok
               | Error e ->
                 Discord_observability.record_inbound_dispatch
                   Discord_observability.Reply_send_error;
                 Discord_observability.record_reply
                   Discord_observability.Reply_send_failed;
                 Log.Server.error "discord send_message failed (channel=%s): %s"
                   channel_id
                   (Format.asprintf "%a" State.pp_send_error e))
          | Stream_overflow_send_failed _ ->
              (match attention_event_id with
               | Some event_id ->
                   mark_attention_resolved ~base_dir ~keeper_name ~event_id
                     ~reason:"discord_reply_partial_overflow"
               | None -> ());
              Discord_observability.record_inbound_dispatch
                Discord_observability.Reply_send_error;
              Discord_observability.record_reply
                Discord_observability.Reply_send_failed))

let on_event ~dispatch ~clock ~base_dir (ev : Gw.gateway_event) =
  match ev with
  | Gw.Ready { bot_user_id; _ } ->
    State.record_ready ~bot_user_id;
    Log.Server.info "Discord gateway READY (bot_user_id=%s)" bot_user_id
  | Gw.Message_create
      { channel_id
      ; message_id
      ; guild_id
      ; author_id
      ; author_name
      ; content
      ; mentions_bot
      ; explicit_mentions_bot
      ; author_is_bot = _
      ; message_reference_channel_id
      ; message_reference_message_id
      ; referenced_message_author_id
      } ->
    (* mentions_bot is already enforced by the trigger policy at the
       gateway-state layer; nothing extra to check here. *)
    handle_message_create ~dispatch ~clock ~channel_id ~message_id ~author_id
      ~guild_id ~base_dir ~author_name ~content ~mentions_bot ~explicit_mentions_bot
      ~message_reference_channel_id ~message_reference_message_id
      ~referenced_message_author_id
  | Gw.Reaction_add _ ->
    (* The previous Python sidecar used a configurable emoji
       trigger to drain pending messages. That feature is dropped in
       the in-process gateway; re-add as a follow-up if needed. *)
    ()
  | Gw.Thread_tracked { thread_id; parent_channel_id } ->
    State.register_thread ~thread_id ~parent_channel_id;
    Log.Server.info
      "Discord thread registered: %s -> parent %s (total=%d)"
      thread_id parent_channel_id
      (State.registered_thread_count ())
  | Gw.Threads_bulk_tracked { threads } ->
    List.iter (fun (tid, pid) -> State.register_thread ~thread_id:tid ~parent_channel_id:pid) threads;
    Log.Server.info
      "Discord guild threads bulk registered: %d threads (total=%d)"
      (List.length threads)
      (State.registered_thread_count ())
  | Gw.Thread_removed { thread_id } ->
    State.unregister_thread ~thread_id;
    Log.Server.info
      "Discord thread removed: %s (total=%d)"
      thread_id
      (State.registered_thread_count ())
  | Gw.Ignored _ ->
    ()

(* RFC-0226 ambient lane recording: a bound-channel message that failed
   the trigger policy is still conversation the keeper sits in. Persist
   a single user line — no dispatch, no turn. Unbound channels drop, as
   on the dispatch path. *)
let handle_ambient ~base_dir
      ~(channel_id : string) ~(guild_id : string option) ~(message_id : string)
      ~(author_id : string) ~(author_name : string option) ~(content : string) =
  match State.keeper_for_channel ~channel_id with
  | None ->
    Discord_observability.record_ambient
      Discord_observability.Ambient_dropped_unbound
  | Some keeper_name ->
    let trimmed = String.trim content in
    if String.equal trimmed "" then
      Discord_observability.record_ambient
        Discord_observability.Ambient_dropped_empty
    else if String.length trimmed > Channel_gate.max_content_length () then
      (* Same inbound bound the turn path enforces
         ([Channel_gate.handle_inbound] validation): a message this
         size cannot become a turn either; it is rejected, not
         truncated. *)
      Discord_observability.record_ambient
        Discord_observability.Ambient_dropped_too_long
    else begin
      let parent_channel_id = State.parent_channel_of_thread ~channel_id in
      let thread_id = Option.map (fun _ -> channel_id) parent_channel_id in
      let attention_event_id =
        record_external_attention ~base_dir ~keeper_name ~guild_id ~channel_id
          ~message_id ~author_id ~author_name ~content:trimmed
          ~mentions_bot:false ~route:"ambient"
          ~urgency:Keeper_external_attention.Ambient
      in
      Keeper_chat_store.append_user_message
        ~base_dir ~keeper_name ~content:trimmed
        ~surface:
          (Surface_ref.Discord
             {
               guild_id;
               channel_id;
               parent_channel_id;
               thread_id;
             })
        ~conversation_id:(discord_conversation_id ~guild_id ~channel_id)
        ~external_message_id:message_id
        ~speaker:
          { Keeper_chat_store.speaker_id = Some author_id
          ; speaker_name = author_name
          ; speaker_authority = Keeper_chat_store.External
          }
        ();
      Keeper_chat_broadcast.chat_appended ~keeper_name ~source:State.channel ();
      (* RFC-connector-ambient-attention-wake P3: wake the (possibly idle) keeper
         on this ambient message via an edge stimulus carrying the external-
         attention event_id (not content — content stays in the durable store),
         plus a wakeup hint for sub-second propagation. Gated off by default:
         until the spurious-wake throttle (P4) lands, running a turn on every
         ambient line in a chatty channel is the anti-pattern the trigger policy
         deliberately filtered. *)
      (match attention_event_id with
       | Some event_id
         when Feature_flag_registry.get_bool "MASC_CONNECTOR_AMBIENT_WAKE_ENABLED"
              (* P4 throttle: the flag short-circuits first (cheap, no side
                 effect); the debounce records a timestamp only when reached, so
                 a chatty channel wakes the keeper at most once per window and a
                 no-progress-latched keeper is not re-woken (RFC-0246). *)
              && Keeper_keepalive_signal.connector_reactive_wakeup_allowed
                   ~base_path:base_dir ~keeper_name ~channel_id
         ->
         let stimulus =
           { Keeper_event_queue.post_id = event_id
           ; urgency = Keeper_event_queue.Low
           ; arrived_at = Unix.gettimeofday ()
             (* NDT-OK: stimulus receipt time, used only for ordering/age *)
           ; payload =
               (* RFC-0320: carry the originating Discord channel+author so a
                  woken keeper replies into the same thread, not its own state. *)
               Keeper_event_queue.Connector_attention
                 { event_id
                 ; channel =
                     Keeper_continuation_channel.Discord
                       { guild_id
                       ; channel_id
                       ; parent_channel_id
                       ; thread_id
                       ; user_id = author_id
                       }
                 }
           }
         in
         Keeper_registry_event_queue.enqueue ~base_path:base_dir keeper_name stimulus;
         Keeper_registry.wakeup ~base_path:base_dir keeper_name
       | Some _ | None -> ());
      Discord_observability.record_ambient
        Discord_observability.Ambient_recorded
    end

let on_ambient ~base_dir (ev : Gw.gateway_event) =
  match ev with
  | Gw.Message_create
      { channel_id; guild_id; message_id; author_id; author_name; content; _ }
    ->
    handle_ambient ~base_dir ~channel_id ~guild_id ~message_id ~author_id
      ~author_name ~content
  | Gw.Ready _ | Gw.Reaction_add _ | Gw.Thread_tracked _ | Gw.Threads_bulk_tracked _ | Gw.Thread_removed _ | Gw.Ignored _ -> ()

(* ---------------------------------------------------------------- *)
(* Start                                                            *)
(* ---------------------------------------------------------------- *)

let start ~sw ~env ~clock ~state =
  match bot_token_opt () with
  | None ->
    Log.Server.warn
      "RFC-0203: DISCORD_BOT_TOKEN is unset; in-process Discord gateway not started"
  | Some token ->
    let policy = resolved_trigger_policy () in
    State.set_trigger_policy policy;
    let dispatch =
      (* RFC-connector-deferred-reply-via-chat-queue: tag this dispatch as the Discord connector so a message that
         arrives while the keeper is in flight is enqueued onto
         [Keeper_chat_queue] (drained by the serial consumer, delivered back to
         the channel via [Keeper_chat_discord.adapter_loop]) rather than the
         outbound-less async poll store ([Keeper_msg_async]). *)
      Gate_keeper_backend.dispatch_with_text_snapshot
        ~connector_kind:Gate_keeper_backend.Discord
        ~submission_owner:Gate_keeper_backend.Channel_actor
        ~sw ~clock
        ~proc_mgr:state.Mcp_server.proc_mgr
        ~net:state.Mcp_server.net
        ~config:(Mcp_server.workspace_config state)
    in
    let policy_label = Discord_gateway_state.trigger_policy_to_string policy in
    Log.Server.info
      "RFC-0203: starting in-process Discord gateway (policy=%s, intents=%d)"
      policy_label
      (Gw.intents_bitmask default_intents);
    Eio.Fiber.fork ~sw (fun () ->
      try
        Gw.run
          ~sw ~env ~token
          ~intents:default_intents
          ~trigger_policy:policy
          ~on_event:(fun ev ->
            (* Read base_path per event: [workspace_config] is mutable
               (workspace-switch tools swap it). *)
            on_event
              ~dispatch
              ~clock
              ~base_dir:(Mcp_server.workspace_config state).base_path
              ev)
          ~on_ambient:(fun ev ->
            (* Read base_path per event: [workspace_config] is mutable
               (workspace-switch tools swap it). *)
            on_ambient
              ~base_dir:(Mcp_server.workspace_config state).base_path ev)
          ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.error
          "RFC-0203: in-process Discord gateway crashed: %s"
          (Printexc.to_string exn))
