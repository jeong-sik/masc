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
  (* Env > TOML > default — the same precedence every other env↔TOML pair in
     this codebase uses (keeper_runtime_config key_to_env, runtime lanes), and
     the precedence config/runtime.toml documents for this key. This site was
     the one inversion (TOML-first), which silently ignored the env var
     whenever [discord].trigger_policy was set (masc#25123). *)
  match trimmed_env "MASC_DISCORD_TRIGGER_POLICY" with
  | Some raw -> parse_trigger_policy raw
  | None ->
    (match from_toml () with
    | Some raw -> parse_trigger_policy raw
    | None -> Gw.Mention_or_thread)

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

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

let discord_delivery ~guild_id ~channel_id ~message_id ~author_id :
    Gate_keeper_backend.connector_delivery =
  let parent_channel_id = State.parent_channel_of_thread ~channel_id in
  let thread_id = Option.map (fun _ -> channel_id) parent_channel_id in
  { source = Keeper_chat_queue.Discord { channel_id; user_id = author_id }
  ; surface =
      Surface_ref.Discord
        { guild_id; channel_id; parent_channel_id; thread_id }
  ; conversation_id = Some (discord_conversation_id ~guild_id ~channel_id)
  ; external_message_id = Some message_id
  }

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

let accept_message_create ~resolved_binding ~dispatch_for_delivery
      ~(channel_id : string) ~(message_id : string)
      ~(guild_id : string option)
      ~base_dir
      ~(author_id : string) ~(author_name : string option)
      ~(content : string)
      ~(mentions_bot : bool)
      ~(explicit_mentions_bot : bool)
      ~(message_reference_channel_id : string option)
      ~(message_reference_message_id : string option)
      ~(referenced_message_author_id : string option) () =
  let binding =
    match resolved_binding with
    | Some binding -> Some binding
    | None ->
      resolve_binding_for_message ~channel_id ~message_reference_channel_id
  in
  match binding with
  | None ->
    (* No binding for this channel — drop quietly. The bot may be in
       channels it isn't bound to (e.g. server-wide guild messages). *)
    Discord_observability.record_inbound_dispatch
      Discord_observability.Dropped_unbound;
    None
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
    let delivery =
      discord_delivery ~guild_id ~channel_id ~message_id ~author_id
    in
    let outcome =
      Channel_gate.handle_inbound ~dispatch:(dispatch_for_delivery delivery) msg
    in
    Some (fun () ->
     match outcome with
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
         (match
            State.send_message ~channel_id ~content:out.content
              ~reply_to_message_id:message_id ()
          with
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
              (Format.asprintf "%a" State.pp_send_error e)))

let accept_event ~resolved_binding ~dispatch_for_delivery ~base_dir
    (ev : Gw.gateway_event) =
  match ev with
  | Gw.Ready { bot_user_id; _ } ->
    State.record_ready ~bot_user_id;
    Log.Server.info "Discord gateway READY (bot_user_id=%s)" bot_user_id;
    None
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
    accept_message_create ~resolved_binding ~dispatch_for_delivery ~channel_id
      ~message_id ~author_id
      ~guild_id ~base_dir ~author_name ~content ~mentions_bot ~explicit_mentions_bot
      ~message_reference_channel_id ~message_reference_message_id
      ~referenced_message_author_id ()
  | Gw.Reaction_add _ ->
    (* The previous Python sidecar used a configurable emoji
       trigger to drain pending messages. That feature is dropped in
       the in-process gateway; re-add as a follow-up if needed. *)
    None
  | Gw.Thread_tracked { thread_id; parent_channel_id } ->
    State.register_thread ~thread_id ~parent_channel_id;
    Log.Server.info
      "Discord thread registered: %s -> parent %s (total=%d)"
      thread_id parent_channel_id
      (State.registered_thread_count ());
    None
  | Gw.Threads_bulk_tracked { threads } ->
    List.iter (fun (tid, pid) -> State.register_thread ~thread_id:tid ~parent_channel_id:pid) threads;
    Log.Server.info
      "Discord guild threads bulk registered: %d threads (total=%d)"
      (List.length threads)
      (State.registered_thread_count ());
    None
  | Gw.Thread_removed { thread_id } ->
    State.unregister_thread ~thread_id;
    Log.Server.info
      "Discord thread removed: %s (total=%d)"
      thread_id
      (State.registered_thread_count ());
    None
  | Gw.Ignored _ ->
    None

(* RFC-0226 ambient lane recording: a bound-channel message that failed
   the trigger policy is still conversation the keeper sits in. Persist
   a single user line — no dispatch, no turn. Unbound channels drop, as
   on the dispatch path. *)
let handle_ambient ?resolved_keeper_name ~base_dir
      ~(channel_id : string) ~(guild_id : string option) ~(message_id : string)
      ~(author_id : string) ~(author_name : string option) ~(content : string) () =
  let keeper_name =
    match resolved_keeper_name with
    | Some keeper_name -> Some keeper_name
    | None -> State.keeper_for_channel ~channel_id
  in
  match keeper_name with
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
      (* Every accepted Connector event is a durable per-Keeper stimulus. The
         event identity comes from the producer-owned external-attention row;
         no content, channel activity, elapsed-time window, or rollout flag may
         suppress it. The wake is only a hint after the durable commit, so a
         busy or lifecycle-deferred Keeper retains the exact event for its next
         lane cycle. *)
      (match attention_event_id with
       | Some event_id ->
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
                     (match
                        Keeper_continuation_channel.discord
                          ~guild_id
                          ~channel_id
                          ~parent_channel_id
                          ~thread_id
                          ~user_id:author_id
                      with
                      | Ok channel -> channel
                      | Error message -> invalid_arg message)
                 }
           }
         in
         (match
            Keeper_registry_event_queue.enqueue_stimulus_durable_result
              ~base_path:base_dir
              keeper_name
              stimulus
          with
          | Keeper_registry_event_queue.Stimulus_storage_error detail ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string KeepaliveSignalFailures)
              ~labels:
                [ ("keeper", keeper_name)
                ; ("phase", "connector_attention_delivery")
                ]
              ();
            Log.Server.error
              "connector attention durable delivery failed (keeper=%s event=%s): %s"
              keeper_name
              event_id
              detail
          | Keeper_registry_event_queue.Stimulus_enqueued
          | Keeper_registry_event_queue.Stimulus_already_present ->
            (match
               Keeper_registry.wakeup_running
                 ~intent:Keeper_registry.Reactive_signal
                 ~base_path:base_dir
                 keeper_name
             with
             | Keeper_registry.Signaled -> ()
             | Keeper_registry.Deferred_unregistered ->
               Log.Server.info
                 "connector attention durably queued; wake deferred for unregistered Keeper (keeper=%s event=%s)"
                 keeper_name
                 event_id
             | Keeper_registry.Deferred_not_running phase ->
               Log.Server.info
                 "connector attention durably queued; wake deferred by Keeper phase (keeper=%s event=%s phase=%s)"
                 keeper_name
                 event_id
                 (Keeper_state_machine.phase_to_string phase)
             | Keeper_registry.Deferred_lifecycle denial ->
               Log.Server.info
                 "connector attention durably queued; wake deferred by lifecycle (keeper=%s event=%s reason=%s)"
                 keeper_name
                 event_id
                 (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)))
       | None -> ());
      Discord_observability.record_ambient
        Discord_observability.Ambient_recorded
    end

let on_ambient ?resolved_keeper_name ~base_dir (ev : Gw.gateway_event) =
  match ev with
  | Gw.Message_create
      { channel_id; guild_id; message_id; author_id; author_name; content; _ }
    ->
    handle_ambient ?resolved_keeper_name ~base_dir ~channel_id ~guild_id
      ~message_id ~author_id ~author_name ~content ()
  | Gw.Ready _ | Gw.Reaction_add _ | Gw.Thread_tracked _ | Gw.Threads_bulk_tracked _ | Gw.Thread_removed _ | Gw.Ignored _ -> ()

let submit_ingress ingress ~lane ~event_id run =
  match Connector_ingress_lane.submit ingress ~lane ~event_id run with
  | Ok () -> ()
  | Error error ->
    Log.Server.error
      "Discord ingress submission rejected lane=%s event=%s: %s"
      (Connector_ingress_lane.lane_to_string lane)
      (Connector_ingress_lane.event_id_to_string event_id)
      (Connector_ingress_lane.submit_error_to_string error)
;;

let submit_triggered_event ?deliver ingress ~dispatch_for_delivery ~base_dir
    (ev : Gw.gateway_event) =
  match ev with
  | Gw.Message_create
      { channel_id; message_id; message_reference_channel_id; _ } ->
    (match
       resolve_binding_for_message ~channel_id ~message_reference_channel_id
     with
     | None ->
       ignore
         (accept_event ~resolved_binding:None ~dispatch_for_delivery ~base_dir ev)
     | Some ((resolution, _) as resolved_binding) ->
       (match
          accept_event
            ~resolved_binding:(Some resolved_binding)
            ~dispatch_for_delivery ~base_dir ev
        with
        | None -> ()
        | Some accepted_delivery ->
          submit_ingress
            ingress
            ~lane:(Connector_ingress_lane.Keeper_lane resolution.State.keeper_name)
            ~event_id:{ source = "discord_triggered"; opaque_id = message_id }
            (* DET-OK: override-vs-admitted delivery, both from one typed
               admission — deterministic, not an unknown-input default. *)
            (Option.value deliver ~default:accepted_delivery)))
  | Gw.Ready _
  | Gw.Reaction_add _
  | Gw.Thread_tracked _
  | Gw.Threads_bulk_tracked _
  | Gw.Thread_removed _
  | Gw.Ignored _ ->
    ignore
      (accept_event ~resolved_binding:None ~dispatch_for_delivery ~base_dir ev)
;;

module For_testing = struct
  let submit_triggered_event = submit_triggered_event
end

let submit_ambient_event ingress ~base_dir (ev : Gw.gateway_event) =
  match ev with
  | Gw.Message_create { channel_id; message_id; _ } ->
    (match State.keeper_for_channel ~channel_id with
     | None -> on_ambient ~base_dir ev
     | Some keeper_name ->
       submit_ingress
         ingress
         ~lane:(Connector_ingress_lane.Keeper_lane keeper_name)
         ~event_id:{ source = "discord_ambient"; opaque_id = message_id }
         (fun () -> on_ambient ~resolved_keeper_name:keeper_name ~base_dir ev))
  | Gw.Ready _
  | Gw.Reaction_add _
  | Gw.Thread_tracked _
  | Gw.Threads_bulk_tracked _
  | Gw.Thread_removed _
  | Gw.Ignored _ -> on_ambient ~base_dir ev
;;

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
    let ingress =
      Connector_ingress_lane.create
        ~sw
        ~on_failure:(fun failure ->
          Log.Server.error
            "Discord ingress callback failed lane=%s event=%s: %s"
            (Connector_ingress_lane.lane_to_string failure.lane)
            (Connector_ingress_lane.event_id_to_string failure.event_id)
            (Connector_ingress_lane.failure_reason_to_string failure.reason))
        ()
    in
    let dispatch_for_config config delivery =
      Gate_keeper_backend.accept_connector ~delivery ~clock ~config
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
            let config = Mcp_server.workspace_config state in
            submit_triggered_event
              ingress
              ~dispatch_for_delivery:(dispatch_for_config config)
              ~base_dir:config.base_path
              ev)
          ~on_ambient:(fun ev ->
            let config = Mcp_server.workspace_config state in
            submit_ambient_event ingress ~base_dir:config.base_path ev)
          ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.error
          "RFC-0203: in-process Discord gateway crashed: %s"
          (Printexc.to_string exn))
