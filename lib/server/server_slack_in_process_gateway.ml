(* See .mli for high-level shape.

   RFC-0317 PR-3: the in-process Slack Socket Mode gateway. Mirrors
   {!Server_discord_in_process_gateway}: fork a long-running fiber that runs
   {!Slack_socket_client.run} and, for each triggered event, looks up the
   channel→keeper binding and durably accepts the exact event before the socket
   callback returns. The connector lane then projects only the threaded ACK;
   the durable queue consumer owns the Keeper turn and final reply.

   Ambient parity with the Discord gateway (RFC-0226): a human message that
   fails the trigger policy is delivered on the record-only ambient lane —
   persisted as external attention + one chat-store user line, committed as a
   durable [Connector_attention] stimulus, and followed by a best-effort wake
   hint. Reactions are ambient observability signal only: they never start a
   turn on either connector. *)

module State = Channel_gate_slack_state
module Gw = Slack_gateway_state

(* ---------------------------------------------------------------- *)
(* Env-driven config                                                *)
(* ---------------------------------------------------------------- *)

(* Env reads live at the config boundary ({!Env_config_slack}) so this gateway
   holds no direct process-environment lookups:
   - [Env_config_slack.app_token_opt] — [SLACK_APP_TOKEN] ([xapp-...]),
     the Socket Mode credential; absent ⇒ gateway off.
   - [Env_config_slack.bot_token_opt] — [SLACK_BOT_TOKEN] ([xoxb-...]),
     read once at start for [auth.test] (the outbound REST path re-reads it at
     send time, so a rotation does not require a restart). *)

(* Default trigger policy when none is configured: the quiet,
   mention-triggered baseline, same stance as the Discord gateway. *)
let default_trigger_policy : Gw.trigger_policy = Gw.Mention_or_thread

(* Parse a configured trigger policy. Delegates to the single strict parser in
   [Slack_gateway_state] so config and the (test-covered) canonical grammar
   cannot drift. Empty ⇒ default (unset); a non-empty value that fails to parse
   is logged and falls back to the default rather than being silently coerced
   into a policy the operator did not write. *)
let parse_trigger_policy raw : Gw.trigger_policy =
  let s = String.trim raw in
  if String.equal s "" then default_trigger_policy
  else
    match Gw.parse_trigger_policy s with
    | Ok policy -> policy
    | Error msg ->
      Log.Server.warn
        "slack trigger_policy %S rejected (%s); using default %s"
        s msg
        (Gw.trigger_policy_to_string default_trigger_policy);
      default_trigger_policy

type trigger_policy_toml_load =
  | Runtime_toml_missing
  | Trigger_policy_missing
  | Trigger_policy_loaded of Gw.trigger_policy

type trigger_policy_load_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Trigger_policy_invalid of { path : string; detail : string }

let trigger_policy_load_error_to_string = function
  | Runtime_toml_unreadable { path; detail } ->
    Printf.sprintf "cannot read %s: %s" path detail
  | Runtime_toml_invalid { path; detail } ->
    Printf.sprintf "invalid TOML in %s: %s" path detail
  | Trigger_policy_invalid { path; detail } ->
    Printf.sprintf "invalid slack.trigger_policy in %s: %s" path detail
;;

let load_trigger_policy_from_toml ~path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Runtime_toml_missing
  | exception Unix.Unix_error (code, _, _) ->
    Error
      (Runtime_toml_unreadable
         { path; detail = Unix.error_message code })
  | _ ->
    (match Safe_ops.read_file_safe path with
     | Error detail -> Error (Runtime_toml_unreadable { path; detail })
     | Ok content ->
       (match Otoml.Parser.from_string_result content with
        | Error detail -> Error (Runtime_toml_invalid { path; detail })
        | Ok toml ->
          (match
             Field_resolution.resolve_string toml [ "slack"; "trigger_policy" ]
           with
           | Field_resolution.Missing -> Ok Trigger_policy_missing
           | Field_resolution.Type_mismatch { expected; message; _ } ->
             Error
               (Trigger_policy_invalid
                  { path
                  ; detail =
                      Printf.sprintf "expected %s: %s" expected message
                  })
           | Field_resolution.Present raw ->
             let raw = String.trim raw in
             if String.equal raw ""
             then Ok Trigger_policy_missing
             else
               (match Gw.parse_trigger_policy raw with
                | Ok policy -> Ok (Trigger_policy_loaded policy)
                | Error detail ->
                  Error (Trigger_policy_invalid { path; detail })))))
;;

let resolved_trigger_policy () =
  let resolution = Config_dir_resolver.resolve () in
  let toml_path =
    Filename.concat resolution.Config_dir_resolver.config_root.path
      Config_dir_resolver.runtime_toml_filename
  in
  match load_trigger_policy_from_toml ~path:toml_path with
  | Error _ as error -> error
  | Ok (Trigger_policy_loaded policy) -> Ok policy
  | Ok (Runtime_toml_missing | Trigger_policy_missing) ->
    Ok
      (match Env_config_slack.trigger_policy_opt () with
       | None -> default_trigger_policy
       | Some raw -> parse_trigger_policy raw)
;;

(* ---------------------------------------------------------------- *)
(* Metadata helpers (mirror the Discord gateway)                    *)
(* ---------------------------------------------------------------- *)

let metadata_opt key = function
  | None -> []
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then [] else [ (key, value) ]

let metadata_bool key value = [ (key, string_of_bool value) ]

(* Slack threads share the parent channel id, so the conversation id is keyed
   on the channel alone (unlike Discord's guild:channel). Consumed by the gate
   recorder to thread the persisted user line. *)
let slack_conversation_id ~channel_id = Printf.sprintf "slack:channel:%s" channel_id

let slack_delivery ~team_id ~channel_id ~thread_ts ~reply_to_thread_ts ~user_id
    ~user_name ~ts : Gate_keeper_backend.connector_delivery =
  { source =
      Keeper_chat_queue.Slack
        { channel_id
        ; user_id
        ; user_name
        ; team_id
        ; thread_ts = Some reply_to_thread_ts
        }
  ; surface = Surface_ref.Slack { team_id; channel_id; thread_ts }
  ; conversation_id = Some (slack_conversation_id ~channel_id)
  ; external_message_id = Some ts
    (* The team IS the workspace identity; when auth.test could not resolve
       it, the typed delivery carries explicit absence ([None]), never an
       empty string. *)
  ; workspace_id = team_id
  }

(* ---------------------------------------------------------------- *)
(* Ambient lane (RFC-0226 parity with the Discord gateway)          *)
(* ---------------------------------------------------------------- *)

let slack_attention_surface ~team_id ~channel_id ~thread_ts =
  Keeper_external_attention.Slack { team_id; channel_id; thread_ts }

let record_external_attention ~base_dir ~keeper_name ~team_id ~channel_id
    ~thread_ts ~ts ~user_id ~user_name ~content ~mentions_bot ~route ~urgency =
  let surface = slack_attention_surface ~team_id ~channel_id ~thread_ts in
  let conversation_id = slack_conversation_id ~channel_id in
  let dedupe_key = Printf.sprintf "slack:%s:%s" conversation_id ts in
  let event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key in
  let item : Keeper_external_attention.item =
    { event_id
    ; dedupe_key
    ; keeper_name
    ; conversation = { conversation_id; surface }
    ; external_message =
        Some { surface; message_id = ts; reply_to_message_id = thread_ts }
    ; source_label = State.channel
    ; actor =
        { actor_id = Some user_id
        ; display_name = user_name
        ; authority = Keeper_chat_store.External
        }
    ; urgency
    ; content_preview = content
    ; content_ref = None
    ; received_at =
        Unix.gettimeofday ()
        (* NDT-OK: Slack ingress wall-clock timestamp. The value is persisted
           as event evidence and for pending-order projection; it does not
           branch deterministic policy. *)
    ; metadata =
        [ "route", route
        ; "mentions_bot", string_of_bool mentions_bot
        ; "slack_channel_id", channel_id
        ]
        @ metadata_opt "slack_team_id" team_id
        @ metadata_opt "slack_thread_ts" thread_ts
    }
  in
  match Keeper_external_attention.record ~base_path:base_dir item with
  | `Recorded -> Some event_id
  | `Duplicate item -> Some item.event_id
  | `Error error ->
    Log.Server.warn
      "slack external attention record failed (channel=%s keeper=%s): %s"
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
      "slack external attention resolve failed (keeper=%s event=%s): %s"
      keeper_name event_id error

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

type accepted_inbound =
  { channel_id : string
  ; reply_to_thread_ts : string
  ; keeper_name : string
  ; attention_event_id : string option
  ; outcome : (Channel_gate.outbound_message, Channel_gate.gate_error) result
  }

let accept_inbound ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id ~channel_id
    ~thread_ts ~user_id ~user_name ~text ~ts ~mentions_bot ~is_app_mention =
  match resolved_binding with
  | None ->
    (* No binding for this channel — drop quietly. The bot may sit in channels
       it isn't bound to. *)
    Slack_observability.record_inbound_dispatch
      Slack_observability.Dropped_unbound;
    None
  | Some resolution ->
    let keeper_name = resolution.State.keeper_name in
    (* Reply into the triggering message's thread. [thread_ts]=None is a
       top-level message (a known state, not a parse failure); rooting the reply
       thread at the message's own ts is the intended Slack behavior, so the
       default is total, not permissive. sound-partial: allow *)
    let reply_to_thread_ts = Option.value thread_ts ~default:ts in
    let metadata =
      [ ("conversation_id", slack_conversation_id ~channel_id)
      ; ("external_message_id", ts)
      ; ("slack.channel_id", channel_id)
      ; ("slack.message_ts", ts)
      ; ("slack.bound_channel_id", resolution.State.bound_channel_id)
      ; ("slack.binding_via_parent", string_of_bool resolution.State.via_parent)
      ]
      @ metadata_opt "slack.team_id" team_id
      @ metadata_opt "slack.thread_ts" thread_ts
      @ metadata_bool "slack.mentions_bot" mentions_bot
      @ metadata_bool "slack.is_app_mention" is_app_mention
      (* Connector-neutral key consumed by the gate recorder: the message named
         this channel's bound keeper, so the persisted user line carries an
         explicit mention even when the text has no literal "@name" token. *)
      @ metadata_bool "mentions_bound_keeper" (mentions_bot || is_app_mention)
    in
    let msg : Channel_gate.inbound_message =
      { channel = State.channel
      ; channel_user_id = user_id
        (* The gate contract requires a non-empty display name; [user_id] is a
           valid fallback when Slack omits [user_name] (a known case, mirroring
           the Discord gateway's id fallback). sound-partial: allow *)
      ; channel_user_name = Option.value user_name ~default:user_id
      ; channel_workspace_id = Option.value team_id ~default:""
        (* sound-partial: allow — [team_id]=None means auth.test could not
           resolve the team (a known state, not a parse failure), so the ""
           default at the stringly gate layer is total, not permissive; the
           typed [delivery.workspace_id] carries the explicit absence
           ([None]). *)
      ; keeper_name
      ; content = text
      ; idempotency_key = Printf.sprintf "slack-msg-%s" ts
        (* Slack sends both [message] and [app_mention] for an @mention; keying
           on the shared [ts] makes the gate's dedup collapse them to one turn. *)
      ; metadata
      }
    in
    (* DET-OK: rendering-only fallback to stable [user_id]; identity keys
       use [user_id] directly. *)
    let user_name = Option.value user_name ~default:user_id in
    let urgency =
      if mentions_bot || is_app_mention then Keeper_external_attention.Mention
      else
        (* A Slack DM is indistinguishable from a channel message at this
           layer (the FSM does not decode [channel_type]); a non-mention
           triggered message in a bound channel is ambient-grade attention.
           [Direct_message] stays for a future channel_type-aware event. *)
        Keeper_external_attention.Ambient
    in
    let attention_event_id =
      record_external_attention ~base_dir ~keeper_name ~team_id ~channel_id
        ~thread_ts ~ts ~user_id ~user_name:(Some user_name) ~content:text
        ~mentions_bot:(mentions_bot || is_app_mention) ~route:"triggered"
        ~urgency
    in
    let delivery =
      slack_delivery ~team_id ~channel_id ~thread_ts ~reply_to_thread_ts ~user_id
        ~user_name ~ts
    in
    Some
      { channel_id
      ; reply_to_thread_ts
      ; keeper_name
      ; attention_event_id
      ; outcome =
          Channel_gate.handle_inbound
            ~dispatch:(dispatch_for_delivery delivery) msg
      }

let deliver_inbound ~clock ~base_dir accepted =
  let { channel_id; reply_to_thread_ts; keeper_name; attention_event_id
      ; outcome } = accepted
  in
  match outcome with
     | Error gate_err -> (
       match gate_err with
       | Channel_gate.Dispatch_unavailable ->
         let notice = Printf.sprintf "⚠️ `%s` 오프라인" keeper_name in
         (match
            State.send_message ~clock ~channel_id ~content:notice
              ~reply_to_message_id:reply_to_thread_ts ()
          with
          | Ok _ ->
            Slack_observability.record_inbound_dispatch
              Slack_observability.Dispatch_unavailable;
            Slack_observability.record_reply Slack_observability.Reply_send_ok
          | Error e ->
            Slack_observability.record_inbound_dispatch
              Slack_observability.Dispatch_unavailable;
            Slack_observability.record_reply
              Slack_observability.Reply_send_failed;
            Log.Server.error
              "slack send unavailable notice failed (channel=%s): %s" channel_id
              (Format.asprintf "%a" State.pp_send_error e));
         Log.Server.info
           "slack inbound -> keeper unavailable, notice sent (channel=%s \
            keeper=%s)"
           channel_id keeper_name
       | Channel_gate.Validation _ | Channel_gate.Keeper_error _
       | Channel_gate.Internal _ ->
         Slack_observability.record_inbound_dispatch
           Slack_observability.Gate_error;
         Log.Server.warn
           "slack inbound -> keeper failed (channel=%s keeper=%s): %s" channel_id
           keeper_name
           (Channel_gate.gate_error_to_string gate_err))
     | Ok out ->
       if String.equal out.content "" then begin
         (match attention_event_id with
          | Some event_id ->
            mark_attention_resolved ~base_dir ~keeper_name ~event_id
              ~reason:"slack_empty_reply"
          | None -> ());
         Slack_observability.record_inbound_dispatch
           Slack_observability.Empty_reply;
         Slack_observability.record_reply Slack_observability.Reply_empty
       end
       else
         match
           State.send_message ~clock ~channel_id ~content:out.content
             ~reply_to_message_id:reply_to_thread_ts ()
         with
         | Ok _ ->
           (match attention_event_id with
            | Some event_id ->
              mark_attention_resolved ~base_dir ~keeper_name ~event_id
                ~reason:"slack_reply_sent"
            | None -> ());
           Slack_observability.record_inbound_dispatch
             Slack_observability.Reply_sent;
           Slack_observability.record_reply Slack_observability.Reply_send_ok
         | Error e ->
           Slack_observability.record_inbound_dispatch
             Slack_observability.Reply_send_error;
           Slack_observability.record_reply Slack_observability.Reply_send_failed;
           Log.Server.error "slack send_message failed (channel=%s): %s"
             channel_id
             (Format.asprintf "%a" State.pp_send_error e)

let accept_event ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id
    (ev : Gw.slack_event) =
  match ev with
  | Gw.Message_create
      { channel_id; thread_ts; user_id; user_name; text; ts; mentions_bot
      ; bot_id } -> (
    match bot_id with
    | Some _ ->
      (* Bot/app author — skip to avoid connector loops (a bot replying to a
         bot, including itself under the [All] policy). The loop guard lives
         here, where the outbound side is known, not in the pure FSM. *)
      Slack_observability.record_gateway_event ~route:Slack_observability.Control
        Slack_observability.Ignored;
      None
    | None ->
      Slack_observability.record_gateway_event
        ~route:Slack_observability.Triggered Slack_observability.Message_create;
      accept_inbound ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id
        ~channel_id ~thread_ts ~user_id ~user_name ~text ~ts ~mentions_bot
        ~is_app_mention:false)
  | Gw.App_mention { channel_id; thread_ts; user_id; text; ts } ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Triggered
      Slack_observability.App_mention;
    accept_inbound ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id
      ~channel_id ~thread_ts ~user_id
      ~user_name:None ~text ~ts ~mentions_bot:true ~is_app_mention:true
  | Gw.Reaction_added _ ->
    (* Unreachable from the FSM's triggered lane: reactions are emitted on the
       ambient lane only (see {!Slack_gateway_state.step}). Kept explicit for
       the closed sum; the ambient handler records the same observability. *)
    Slack_observability.record_gateway_event ~route:Slack_observability.Ambient
      Slack_observability.Reaction_added;
    None
  | Gw.Ignored_event _ ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Control
      Slack_observability.Ignored;
    None

let submit_event ?deliver ?team_id ingress ~dispatch_for_delivery ~clock
    ~base_dir (ev : Gw.slack_event) =
  let submit ~channel_id ~event_id =
    match State.resolve_keeper_for_channel_result ~channel_id with
    | Error reason ->
      Slack_observability.record_inbound_dispatch Slack_observability.Gate_error;
      Log.Server.error
        "Slack ingress binding unavailable channel=%s event=%s: %s"
        channel_id event_id
        (Channel_gate_binding_store.binding_store_error_to_string reason)
    | Ok resolved_binding -> (
      match accept_event ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id ev with
      | None -> ()
      | Some accepted ->
        let lane = Connector_ingress_lane.Keeper_lane accepted.keeper_name in
        let ingress_event_id =
          Connector_ingress_lane.{ source = "slack_triggered"; opaque_id = event_id }
        in
        let delivery =
          match deliver with
          | Some deliver -> deliver
          | None -> fun () -> deliver_inbound ~clock ~base_dir accepted
        in
        match
          Connector_ingress_lane.submit
            ingress
            ~lane
            ~event_id:ingress_event_id
            delivery
        with
        | Ok () -> ()
        | Error error ->
          Log.Server.error
            "Slack ingress submission rejected lane=%s event=%s: %s"
            (Connector_ingress_lane.lane_to_string lane)
            (Connector_ingress_lane.event_id_to_string ingress_event_id)
            (Connector_ingress_lane.submit_error_to_string error))
  in
  match ev with
  | Gw.Message_create { bot_id = Some _; _ } ->
    (* See [accept_event]: this variant only records observability. *)
    ignore (accept_event ~resolved_binding:None ~dispatch_for_delivery ~base_dir ~team_id ev)
  | Gw.Message_create { channel_id; ts; bot_id = None; _ }
  | Gw.App_mention { channel_id; ts; _ } -> submit ~channel_id ~event_id:ts
  | Gw.Reaction_added _ | Gw.Ignored_event _ ->
    (* See [accept_event]: these variants only record observability. *)
    ignore (accept_event ~resolved_binding:None ~dispatch_for_delivery ~base_dir ~team_id ev)
;;

(* Ambient lane recording: a bound-channel message that failed the trigger
   policy is still conversation the keeper sits in. Persist durable attention
   plus a single user line, commit the exact event as a durable
   [Connector_attention] stimulus, then offer a best-effort wake hint — no
   dispatch, no turn. Unbound channels drop, as on the dispatch path. *)
let handle_ambient ?resolved_keeper_name ~base_dir ~team_id ~channel_id
    ~thread_ts ~user_id ~user_name ~text ~ts ~mentions_bot () =
  let keeper_name =
    match resolved_keeper_name with
    | Some keeper_name -> Ok (Some keeper_name)
    | None -> (
      match State.resolve_keeper_for_channel_result ~channel_id with
      | Ok (Some resolution) -> Ok (Some resolution.State.keeper_name)
      | Ok None -> Ok None
      | Error _ as error -> error)
  in
  match keeper_name with
  | Error reason ->
    Log.Server.error
      "Slack ambient binding lookup failed (channel=%s): %s" channel_id
      (Channel_gate_binding_store.binding_store_error_to_string reason);
    Slack_observability.record_ambient
      Slack_observability.Ambient_binding_store_error
  | Ok None ->
    Slack_observability.record_ambient Slack_observability.Ambient_dropped_unbound
  | Ok (Some keeper_name) ->
    let trimmed = String.trim text in
    if String.equal trimmed "" then
      Slack_observability.record_ambient Slack_observability.Ambient_dropped_empty
    else if String.length trimmed > Channel_gate.max_content_length () then
      (* Same inbound bound the turn path enforces
         ([Channel_gate.handle_inbound] validation): a message this size cannot
         become a turn either; it is rejected, not truncated. *)
      Slack_observability.record_ambient
        Slack_observability.Ambient_dropped_too_long
    else begin
      let attention_event_id =
        record_external_attention ~base_dir ~keeper_name ~team_id ~channel_id
          ~thread_ts ~ts ~user_id ~user_name ~content:trimmed ~mentions_bot
          ~route:"ambient" ~urgency:Keeper_external_attention.Ambient
      in
      Keeper_chat_store.append_user_message
        ~base_dir ~keeper_name ~content:trimmed
        ~surface:(Surface_ref.Slack { team_id; channel_id; thread_ts })
        ~conversation_id:(slack_conversation_id ~channel_id)
        ~external_message_id:ts
        ~speaker:
          { Keeper_chat_store.speaker_id = Some user_id
          ; speaker_name = user_name
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
               (* RFC-0320: carry the originating Slack channel+author so a
                  woken keeper replies into the same thread, not its own state. *)
               Keeper_event_queue.Connector_attention
                 { event_id
                 ; channel =
                     (match
                        Keeper_continuation_channel.slack ~team_id ~channel_id
                          ~thread_ts ~user_id
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
      Slack_observability.record_ambient Slack_observability.Ambient_recorded
    end

let on_ambient ?resolved_keeper_name ?team_id ~base_dir (ev : Gw.slack_event) =
  match ev with
  | Gw.Message_create
      { channel_id; thread_ts; user_id; user_name; text; ts; mentions_bot
      ; bot_id = None
      } ->
    handle_ambient ?resolved_keeper_name ~base_dir ~team_id ~channel_id
      ~thread_ts ~user_id ~user_name ~text ~ts ~mentions_bot ()
  | Gw.Message_create { bot_id = Some _; _ } | Gw.App_mention _ ->
    (* Unreachable from the FSM's ambient lane: bot echoes are dropped and an
       app_mention always passes policy. Kept explicit — closed sum. *)
    ()
  | Gw.Reaction_added _ ->
    (* Reactions are observability signal only; they are not attention records
       and never start a turn (Discord parity). *)
    Slack_observability.record_gateway_event ~route:Slack_observability.Ambient
      Slack_observability.Reaction_added
  | Gw.Ignored_event _ -> ()

let submit_ambient_event ?team_id ingress ~base_dir (ev : Gw.slack_event) =
  match ev with
  | Gw.Message_create { channel_id; ts; bot_id = None; _ } -> (
    match State.resolve_keeper_for_channel_result ~channel_id with
    | Error reason ->
      Log.Server.error
        "Slack ambient binding unavailable channel=%s event=%s: %s" channel_id
        ts
        (Channel_gate_binding_store.binding_store_error_to_string reason);
      Slack_observability.record_ambient
        Slack_observability.Ambient_binding_store_error
    | Ok None -> on_ambient ?team_id ~base_dir ev
    | Ok (Some resolution) -> (
      let lane =
        Connector_ingress_lane.Keeper_lane resolution.State.keeper_name
      in
      let ingress_event_id =
        Connector_ingress_lane.{ source = "slack_ambient"; opaque_id = ts }
      in
      match
        Connector_ingress_lane.submit
          ingress
          ~lane
          ~event_id:ingress_event_id
          (fun () ->
            on_ambient
              ~resolved_keeper_name:resolution.State.keeper_name
              ?team_id ~base_dir ev)
      with
      | Ok () -> ()
      | Error error ->
        Log.Server.error
          "Slack ambient ingress submission rejected lane=%s event=%s: %s"
          (Connector_ingress_lane.lane_to_string lane)
          (Connector_ingress_lane.event_id_to_string ingress_event_id)
          (Connector_ingress_lane.submit_error_to_string error)))
  | Gw.Message_create { bot_id = Some _; _ }
  | Gw.App_mention _ | Gw.Reaction_added _ | Gw.Ignored_event _ ->
    on_ambient ?team_id ~base_dir ev
;;

module For_testing = struct
  let submit_event = submit_event
  let submit_ambient_event = submit_ambient_event
  let record_external_attention = record_external_attention
  let mark_attention_resolved = mark_attention_resolved
end

(* ---------------------------------------------------------------- *)
(* Start                                                            *)
(* ---------------------------------------------------------------- *)

let start ~sw ~env ~state =
  match Env_config_slack.app_token_opt () with
  | None ->
    State.clear_startup_error ();
    Log.Server.warn
      "RFC-0317: SLACK_APP_TOKEN is unset; in-process Slack gateway not \
       started"
  | Some app_token ->
    (match resolved_trigger_policy () with
     | Error error ->
       let detail = trigger_policy_load_error_to_string error in
       State.record_startup_error detail;
       Log.Server.error
         "RFC-0317: Slack trigger-policy configuration rejected; gateway not \
          started (%s)"
         detail
     | Ok policy ->
       State.clear_startup_error ();
       (* One clock for the whole gateway: bounds [auth.test], durable accept,
          and outbound ACK sends. *)
       let clock = Eio.Stdenv.clock env in
       (* Resolve the bot's own identity for mention detection. Non-fatal:
          without it, [app_mention] events still trigger (a mention by
          construction); only plain-message mention detection on the [message]
          event degrades. *)
       let bot_user_id, team_id =
         match Env_config_slack.bot_token_opt () with
         | None ->
           Log.Server.warn
             "RFC-0317: SLACK_BOT_TOKEN unset; Slack plain-message mention \
              detection disabled (app_mention still triggers)";
           None, None
         | Some bot_token -> (
           match Slack_rest_client.auth_test ~clock ~token:bot_token () with
           | Ok { user_id; team_id } ->
             State.record_ready ~bot_user_id:user_id;
             Log.Server.info "RFC-0317: Slack auth.test ok (bot_user_id=%s)"
               user_id;
             Some user_id, team_id
           | Error e ->
             Log.Server.warn
               "RFC-0317: Slack auth.test failed (%s); proceeding without \
                bot_user_id"
               (Format.asprintf "%a" Slack_rest_client.pp_error e);
             None, None)
       in
       State.set_trigger_policy policy;
       let ingress =
         Connector_ingress_lane.create
           ~sw
           ~on_failure:(fun failure ->
             Log.Server.error
               "Slack ingress callback failed lane=%s event=%s: %s"
               (Connector_ingress_lane.lane_to_string failure.lane)
               (Connector_ingress_lane.event_id_to_string failure.event_id)
               (Connector_ingress_lane.failure_reason_to_string failure.reason))
           ()
       in
       let dispatch_for_config config delivery =
         Gate_keeper_backend.accept_connector ~delivery ~clock ~config
       in
       let policy_label = Gw.trigger_policy_to_string policy in
       Log.Server.info
         "RFC-0317: starting in-process Slack gateway (policy=%s)"
         policy_label;
       Eio.Fiber.fork ~sw (fun () ->
         try
           Slack_socket_client.run ~sw ~env ~bot_user_id ~app_token
             ~trigger_policy:policy
             ~on_event:(fun ev ->
               let config = Mcp_server.workspace_config state in
               submit_event
                 ingress
                 ~dispatch_for_delivery:(dispatch_for_config config)
                 ?team_id
                 ~clock
                 ~base_dir:config.base_path
                 ev)
             ~on_ambient:(fun ev ->
               let config = Mcp_server.workspace_config state in
               submit_ambient_event ingress ?team_id ~base_dir:config.base_path
                 ev)
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.error "RFC-0317: in-process Slack gateway crashed: %s"
             (Printexc.to_string exn)))
