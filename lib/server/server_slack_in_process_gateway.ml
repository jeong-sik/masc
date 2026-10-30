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

open Result.Syntax
let ingress_refusal detail = Error (Gw.Retryable_refusal detail)

type original_route = Triggered_route | Ambient_route

let original_route (original : Keeper_external_attention.item) =
  match List.filter (fun (name, _) -> String.equal name "route") original.metadata with
  | [(_, "triggered")] -> Ok Triggered_route
  | [(_, "ambient")] -> Ok Ambient_route
  | [] | _ :: _ -> ingress_refusal "original Slack attention has no unique known admission route"


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

(* Default trigger policy when none is configured (empty/unset). The
   "quiet, mention-triggered bot" baseline per RFC-0203. *)
let default_trigger_policy : Gw.trigger_policy = Gw.Mention_or_thread

(* The TOML walk lives in [Connector_trigger_policy]: this module and the
   Discord sibling each carried a byte-for-byte copy of it. A missing file or
   missing key is "unset" (default applies); an unreadable file, malformed
   TOML, wrong field type, or a value the strict grammar rejects is an explicit
   load error and the gateway does not start — never a silent fallback onto a
   policy the operator did not write (masc#25123 / PR #25126 recut).

   Both types are re-exported by type equation rather than aliased, so this
   module still publishes the constructor names its suite reads. *)

module Policy_load = Connector_trigger_policy.Make (struct
  type policy = Gw.trigger_policy

  let table = Runtime_toml_namespace.(key Slack)
  let parse = Gw.parse_trigger_policy
  let default = default_trigger_policy
end)

type trigger_policy_toml_load = Policy_load.load =
  | Runtime_toml_missing
  | Trigger_policy_missing
  | Trigger_policy_loaded of Gw.trigger_policy

type trigger_policy_load_error = Connector_trigger_policy.load_error =
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

let load_trigger_policy_from_toml ~path = Policy_load.load_from_toml ~path

(* runtime.toml > default — the precedence config/runtime.toml documents for
   this key. A missing file, a missing key and a blank value all mean unset. *)
let resolved_trigger_policy () = Policy_load.resolve ()

(* What the gateway judges by right now: the operator's override when the
   params surface holds one, otherwise what runtime.toml said at boot. Read
   per step by the client, so a change lands on the next message. *)
let current_trigger_policy () =
  Runtime_params.get Connector_trigger_params.slack
;;
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

let slack_delivery ~team_id ~channel_id ~channel_name ~thread_ts
    ~reply_to_thread_ts ~user_id ~user_name:_ ~ts
  : (Gate_keeper_backend.connector_delivery, string) result
  =
  Result.map
    (fun continuation_channel ->
       { Gate_keeper_backend.continuation_channel
       ; surface =
           Surface_ref.Slack
             { team_id
             ; channel_id
             ; channel_name
             ; thread_ts = Some reply_to_thread_ts
             }
       ; conversation_id = Some (slack_conversation_id ~channel_id)
       ; external_message_id = Some ts
       ; workspace_id = team_id
       })
    (Keeper_continuation_channel.slack
       ~team_id ~channel_id ~thread_ts:(Some reply_to_thread_ts) ~user_id)

(* ---------------------------------------------------------------- *)
(* Ambient lane (RFC-0226 parity with the Discord gateway)          *)
(* ---------------------------------------------------------------- *)

(* What a channel is called, for the label a reader sees. [conversations.info]
   answers it once and the name is written down; a workspace without
   [channels:read] never answers, and then the id stands in for the room the
   way it always did.

   Asked at most once per channel per process: the store is the cache. A
   keeper bound to five channels showed the same [discord]/[slack] badge on
   all five before this, so the id was already better than nothing -- a name
   is better still. *)
let resolve_channel_name ~base_dir ~token ~channel_id =
  match
    Keeper_connector_names.recall ~base_dir ~connector:State.channel
      ~scope:Keeper_connector_names.Channel ~id:channel_id
  with
  | Some _ as known -> known
  | None -> (
    match token with
    | None -> None
    | Some token -> (
      match Slack_rest_client.conversations_info ~token ~channel_id () with
      | Error _ ->
        (* A missing scope, a rate limit, a private channel the bot is not in.
           None of those is a reason to stop the message: the id keeps
           standing in, and the next inbound retries. *)
        None
      | Ok { channel_name = None; _ } -> None
      | Ok { channel_name = Some name; _ } ->
        Keeper_connector_names.remember ~base_dir ~connector:State.channel
          ~scope:Keeper_connector_names.Channel ~id:channel_id ~name ();
        Some name))

let slack_attention_surface ~team_id ~channel_id ~channel_name ~thread_ts =
  Keeper_external_attention.Slack
    { team_id; channel_id; channel_name; thread_ts }

let slack_attention_key ~channel_id ~ts =
  Printf.sprintf "slack:%s:%s" (slack_conversation_id ~channel_id) ts

let record_external_attention ~base_dir ~keeper_name ~team_id ~channel_id
    ~channel_name ~thread_ts ~ts ~user_id ~user_name ~content ~mentions_bot
    ~route ~urgency =
  let surface =
    slack_attention_surface ~team_id ~channel_id ~channel_name ~thread_ts
  in
  let conversation_id = slack_conversation_id ~channel_id in
  let dedupe_key = slack_attention_key ~channel_id ~ts in
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
  let* () = match Keeper_external_attention.record ~base_path:base_dir item with
    | `Recorded | `Duplicate _ -> Ok ()
    | `Error error ->
      Log.Server.warn "slack external attention record failed (channel=%s keeper=%s): %s"
        channel_id keeper_name error;
      Error error
  in
  (* [record]'s bounded tail is an append optimization, not authority for
     original route absence. Resolve the earliest original from the strict
     whole log, including after the tail no longer contains this event. *)
  let* originals = Keeper_external_attention.recorded_items_by_event_ids
    ~base_path:base_dir ~keeper_name ~event_ids:[event_id]
    |> Result.map_error Keeper_external_attention.read_error_to_string in
  match originals with
  | [(id, original)] when String.equal id event_id -> Ok original
  | [] | _ :: _ -> Error "recorded Slack original is absent from its strict complete attention log"


let restore_original_source ~keeper_name ~team_id ~channel_id ~thread_ts ~ts ~user_id
    (original : Keeper_external_attention.item) =
  let* source = match original.conversation.surface, original.actor.actor_id, original.external_message with
    | Surface_ref.Slack surface, Some stored_user, Some message
      when String.equal original.keeper_name keeper_name
        && String.equal original.dedupe_key (slack_attention_key ~channel_id ~ts)
        && String.equal original.event_id (Keeper_external_attention.event_id_of_dedupe_key original.dedupe_key)
        && original.actor.authority = Keeper_chat_store.External
        && String.equal original.source_label State.channel
        && String.equal original.conversation.conversation_id (slack_conversation_id ~channel_id)
        && String.equal stored_user user_id
        && surface.thread_ts = thread_ts
        && String.equal surface.channel_id channel_id
        && String.equal message.message_id ts
        && Surface_ref.equal message.surface original.conversation.surface
        && (match team_id, surface.team_id with
            | Some expected, Some observed -> String.equal expected observed
            | None, None | Some _, None | None, Some _ -> true) ->
      Ok (surface.team_id, surface.channel_id, surface.thread_ts, stored_user, message.message_id)
    | (Surface_ref.Slack _ | Surface_ref.Dashboard _ | Surface_ref.Discord _
      | Surface_ref.Webhook _ | Surface_ref.Agent | Surface_ref.Broadcast | Surface_ref.Gate _),
      (Some _ | None), (Some _ | None) ->
      ingress_refusal "original attention does not identify this Slack source and Keeper"
  in
  let* mentioned = match List.filter (fun (key, _) -> String.equal key "mentions_bot") original.metadata with
    | [(_, "true")] -> Ok true | [(_, "false")] -> Ok false
    | [] | _ :: _ -> ingress_refusal "original Slack attention has no unique boolean mention fact" in
  Ok (source, mentioned)

let finish_ambient_original ~base_dir ~keeper_name ~team_id ~channel_id ~thread_ts ~ts ~user_id
    (original : Keeper_external_attention.item) =
  let* (original_team, original_channel, original_thread, original_user, original_message), _ =
    restore_original_source ~keeper_name ~team_id ~channel_id ~thread_ts ~ts ~user_id original in
  let* request_id = Keeper_chat_delivery_identity.Request_id.of_string original.event_id
    |> Result.map_error (fun detail -> Gw.Retryable_refusal detail) in
  let* _ = Keeper_chat_store.append_user_message_once
    ~base_dir ~keeper_name ~content:original.content_preview
    ~delivery_key:(Keeper_chat_delivery_identity.Connector_message request_id)
    ~surface:original.conversation.surface
    ~conversation_id:original.conversation.conversation_id ~external_message_id:original_message
    ~speaker:{Keeper_chat_store.speaker_id=Some original_user;
      speaker_name=original.actor.display_name; speaker_authority=original.actor.authority} ()
    |> Result.map_error (fun detail -> Gw.Retryable_refusal detail) in
  let* channel = Keeper_continuation_channel.slack ~team_id:original_team
    ~channel_id:original_channel ~thread_ts:original_thread ~user_id:original_user
    |> Result.map_error (fun detail -> Gw.Retryable_refusal detail) in
  let* () = Server_connector_attention_delivery.deliver ~base_path:base_dir
    ~keeper_name ~event_id:original.event_id ~channel
    |> Result.map_error (fun detail -> Gw.Retryable_refusal detail) in
  Keeper_chat_broadcast.chat_appended ~keeper_name ~source:State.channel ();
  Slack_observability.record_ambient Slack_observability.Ambient_recorded;
  Ok Gw.Durable_accepted

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

type accepted_inbound =
  { channel_id : string
  ; reply_to_thread_ts : string
  ; keeper_name : string
  ; attention_event_id : (Keeper_external_attention.item, string) result
  ; operation_id : string
  ; outcome : (Channel_gate.outbound_message, Channel_gate.gate_error) result
  }

let accept_inbound ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id ~channel_id
    ~thread_ts ~user_id ~user_name ~text ~ts ~mentions_bot ~is_app_mention =
  Option.iter State.record_workspace_id team_id;
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
    (* [user_name] stays an option from here down. It used to be collapsed to
       [user_id] and then wrapped back into [Some], which reads as "Slack told
       us this person is called U09L0RHPW7P".

       The comment above called that rendering-only. It is not: the value
       reaches [display_name], the durable chat row's [speaker_name], and the
       pane, where an id sits in the place a name goes. 12 of one person's 24
       messages arrived that way -- the same human, named half the time.

       [display_name] is already [string option], so absence has a place to
       live. Only the gate's [channel_user_name] needs a string, and that one
       keeps its documented fallback. *)
    let urgency =
      if mentions_bot || is_app_mention then Keeper_external_attention.Mention
      else
        (* A Slack DM is indistinguishable from a channel message at this
           layer (the FSM does not decode [channel_type]); a non-mention
           triggered message in a bound channel is ambient-grade attention.
           [Direct_message] stays for a future channel_type-aware event. *)
        Keeper_external_attention.Ambient
    in
    let channel_name =
      resolve_channel_name ~base_dir
        ~token:(Env_config_slack.bot_token_opt ()) ~channel_id
    in
    let attention_event_id =
      record_external_attention ~base_dir ~keeper_name ~team_id ~channel_id
        ~channel_name ~thread_ts ~ts ~user_id ~user_name ~content:text
        ~mentions_bot:(mentions_bot || is_app_mention) ~route:"triggered"
        ~urgency
    in
    let outcome =
      match attention_event_id with
      | Error detail -> Error (Channel_gate.Internal detail)
      | Ok original ->
        (match original_route original with
         | Error (Gw.Retryable_refusal detail) -> Error (Channel_gate.Internal detail)
         | Ok Ambient_route -> Error (Channel_gate.Internal "original Slack event belongs to ambient admission")
         | Ok Triggered_route ->
           match restore_original_source ~keeper_name ~team_id ~channel_id ~thread_ts ~ts ~user_id original with
           | Error (Gw.Retryable_refusal detail) -> Error (Channel_gate.Internal detail)
           | Ok ((stored_team, stored_channel, stored_thread, stored_user, stored_message), stored_mentioned) ->
             let stored_name = original.actor.display_name in
             let stored_channel_name = match original.conversation.surface with
               | Surface_ref.Slack {channel_name;_} -> channel_name
               | Surface_ref.Dashboard _ | Surface_ref.Discord _ | Surface_ref.Webhook _
               | Surface_ref.Agent | Surface_ref.Broadcast | Surface_ref.Gate _ -> None in
             let metadata = msg.metadata
               |> List.remove_assoc "slack.team_id"
               |> List.remove_assoc "slack.mentions_bot"
               |> List.remove_assoc "mentions_bound_keeper" in
             let msg = { msg with channel_user_id=stored_user;
               channel_user_name=Option.value stored_name ~default:stored_user;
               channel_workspace_id=Option.value stored_team ~default:"";
               content=original.content_preview;
               metadata=metadata @ metadata_opt "slack.team_id" stored_team
                 @ metadata_bool "slack.mentions_bot" stored_mentioned
                 @ metadata_bool "mentions_bound_keeper" stored_mentioned } in
             match slack_delivery ~team_id:stored_team ~channel_id:stored_channel
               ~channel_name:stored_channel_name ~thread_ts:stored_thread ~reply_to_thread_ts
               ~user_id:stored_user ~user_name:stored_name ~ts:stored_message with
             | Error detail -> Error (Channel_gate.Internal detail)
             | Ok delivery -> Channel_gate.handle_inbound ~dispatch:(dispatch_for_delivery delivery) msg)
    in
    Some
      { channel_id
      ; reply_to_thread_ts
      ; keeper_name
      ; attention_event_id
      ; operation_id = msg.idempotency_key
      ; outcome
      }

let deliver_inbound ~clock ~base_dir accepted =
  let { channel_id; reply_to_thread_ts; keeper_name; attention_event_id = _
      ; operation_id = _; outcome } = accepted
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
      ; bot_id; files } -> (
    (* Files posted with no message arrive with [text] empty; the files are
       then the whole message. Both lanes compose the same body. *)
    let text = Gw.text_with_files ~text ~files in
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
  | Gw.App_mention { channel_id; thread_ts; user_id; text; ts; files } ->
    let text = Gw.text_with_files ~text ~files in
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

(* Inbound identity rendering (issue #28376): resolve the author's display
   label and rewrite [<@U…>] mention escapes before the event reaches the
   triggered/ambient lanes, so keeper prompts and durable transcripts carry
   names instead of raw ids. Rendering only — [user_id] stays the identity
   key everywhere (dedup, speaker_id, continuation channels). Runs after
   [decode_event], so [mentions_bot] was already detected on the raw wire
   text. Without a directory (no bot token) events pass through unchanged. *)
let resolve_event_identity ?user_directory (ev : Gw.slack_event) =
  match user_directory with
  | None -> ev
  | Some directory ->
    (match ev with
     | Gw.Message_create ({ user_id; user_name; text; _ } as message) ->
       let user_name =
         match user_name with
         | Some _ as supplied -> supplied
         | None -> Slack_user_directory.display_label directory ~user_id
       in
       Gw.Message_create
         { message with
           user_name
         ; text = Slack_user_directory.rewrite_mentions directory text
         }
     | Gw.App_mention ({ text; _ } as mention) ->
       Gw.App_mention
         { mention with
           text = Slack_user_directory.rewrite_mentions directory text
         }
     | Gw.Reaction_added _ | Gw.Ignored_event _ -> ev)

(* What the directory found, written down, and what it did not find, read back.

   [Slack_user_directory] caches in memory: an hour for a name, five minutes
   for a failure, and nothing at all across a restart. So the same person
   arrives named on one message and id-shaped on the next -- one channel had
   twelve of each from one human.

   A live answer always wins and is remembered. Recall speaks only where there
   is no live answer and there was one before: a name we have seen, not a name
   we are asserting. Kept out of [resolve_event_identity] because that one is
   rendering-only by contract and this reaches the disk. *)
let remember_resolved_names ~base_dir (ev : Gw.slack_event) =
  match ev with
  | Gw.Message_create ({ user_id; user_name; _ } as message) -> (
    match user_name with
    | Some name ->
      Keeper_connector_names.remember ~base_dir ~connector:State.channel
        ~scope:Keeper_connector_names.Person ~id:user_id ~name ();
      ev
    | None ->
      (match
         Keeper_connector_names.recall ~base_dir ~connector:State.channel
           ~scope:Keeper_connector_names.Person ~id:user_id
       with
       | None -> ev
       | Some name -> Gw.Message_create { message with user_name = Some name }))
  | Gw.App_mention _ | Gw.Reaction_added _ | Gw.Ignored_event _ -> ev

let accepted_receipt (accepted : accepted_inbound) =
  let* _ = accepted.attention_event_id |> Result.map_error (fun detail -> Gw.Retryable_refusal detail) in
  match accepted.outcome with
  | Error error ->
    (match error with
     | Channel_gate.Validation Gate_protocol.Empty_content ->
       Ok (Gw.Intentionally_ignored Gw.Empty_message)
     | Channel_gate.Validation (Gate_protocol.Content_too_long _) ->
       Ok (Gw.Intentionally_ignored Gw.Oversized_message)
     | Channel_gate.Validation (Gate_protocol.Empty_keeper_name
         | Gate_protocol.Empty_channel_user_id | Gate_protocol.Empty_idempotency_key)
     | Channel_gate.Keeper_error _ | Channel_gate.Dispatch_unavailable | Channel_gate.Internal _ ->
       ingress_refusal (Channel_gate.gate_error_to_string error))
  | Ok { message_request = None; _ } ->
    ingress_refusal "connector dispatch returned no durable operation receipt"
  | Ok { message_request = Some request; _ } ->
    if not (String.equal request.request_id accepted.operation_id
      && String.equal request.destination_type "keeper"
      && String.equal request.destination_id accepted.keeper_name
      && String.equal request.channel State.channel) then
      ingress_refusal "connector operation receipt does not identify its original event and Keeper"
    else
      match request.status with
      | Gate_protocol.Accepted | Gate_protocol.Queued | Gate_protocol.Running
      | Gate_protocol.Done | Gate_protocol.Failed | Gate_protocol.Cancelled -> Ok Gw.Durable_accepted
      | Gate_protocol.Acceptance_uncertain | Gate_protocol.Lost ->
        ingress_refusal "connector operation acceptance is unconfirmed"

let submit_event ?deliver ?team_id ?user_directory ingress ~dispatch_for_delivery
    ~clock ~base_dir (ev : Gw.slack_event) =
  let ev = resolve_event_identity ?user_directory ev in
  let ev = remember_resolved_names ~base_dir ev in
  let submit ~channel_id ~event_id =
    match State.resolve_keeper_for_channel_result ~channel_id with
    | Error reason ->
      Slack_observability.record_inbound_dispatch Slack_observability.Gate_error;
      let detail = Channel_gate_binding_store.binding_store_error_to_string reason in
      Log.Server.error "Slack ingress binding unavailable channel=%s event=%s: %s" channel_id event_id detail;
      ingress_refusal detail
    | Ok resolved_binding ->
      match accept_event ~resolved_binding ~dispatch_for_delivery ~base_dir ~team_id ev with
      | None -> Ok (Gw.Intentionally_ignored Gw.Unbound_channel)
      | Some accepted ->
        let* receipt = match accepted.attention_event_id with
          | Error detail -> ingress_refusal detail
          | Ok original ->
            let* route = original_route original in
            match route with
            | Triggered_route -> accepted_receipt accepted
            | Ambient_route ->
              (match ev with
               | Gw.Message_create {user_id;thread_ts;_} | Gw.App_mention {user_id;thread_ts;_} ->
                 finish_ambient_original ~base_dir ~keeper_name:accepted.keeper_name ~team_id
                   ~channel_id ~thread_ts ~ts:event_id ~user_id original
               | Gw.Reaction_added _ | Gw.Ignored_event _ -> ingress_refusal "expected original Slack message")
        in
        (match receipt with
         | Gw.Intentionally_ignored _ -> ()
         | Gw.Durable_accepted ->
           (match accepted.attention_event_id with
            | Ok original ->
              (match original_route original with
               | Ok Ambient_route | Error _ -> ()
               | Ok Triggered_route ->
           let lane = Connector_ingress_lane.Keeper_lane accepted.keeper_name in
           let ingress_event_id = Connector_ingress_lane.{source="slack_triggered"; opaque_id=event_id} in
           let delivery = match deliver with Some deliver -> deliver
             | None -> fun () -> deliver_inbound ~clock ~base_dir accepted in
           (* The durable Keeper operation owns the actual reply. This lane
              only projects its status notice; failure is not lost ingress. *)
           match Connector_ingress_lane.submit ingress ~lane ~event_id:ingress_event_id delivery with
           | Ok () -> ()
           | Error error ->
             Log.Server.error "Slack status notice handoff failed after durable accept: %s"
               (Connector_ingress_lane.submit_error_to_string error))
            | Error _ -> ()));
        Ok receipt
  in
  match ev with
  | Gw.Message_create { bot_id = Some _; _ } ->
    ignore (accept_event ~resolved_binding:None ~dispatch_for_delivery ~base_dir ~team_id ev);
    Ok (Gw.Intentionally_ignored Gw.Bot_echo)
  | Gw.Message_create { channel_id; ts; bot_id = None; _ }
  | Gw.App_mention { channel_id; ts; _ } -> submit ~channel_id ~event_id:ts
  | Gw.Reaction_added _ | Gw.Ignored_event _ ->
    ignore (accept_event ~resolved_binding:None ~dispatch_for_delivery ~base_dir ~team_id ev);
    Ok (Gw.Intentionally_ignored Gw.Observational_event)
;;

(* Ambient lane recording: a bound-channel message that failed the trigger
   policy is still conversation the keeper sits in. Persist durable attention
   plus a single user line, commit the exact event as a durable
   [Connector_attention] stimulus, then offer a best-effort wake hint — no
   dispatch, no turn. Unbound channels drop, as on the dispatch path. *)
let handle_ambient ~recover_triggered ~base_dir ~team_id ~channel_id
    ~thread_ts ~user_id ~user_name ~text ~ts ~mentions_bot () =
  match State.resolve_keeper_for_channel_result ~channel_id with
  | Error reason ->
    Slack_observability.record_ambient Slack_observability.Ambient_binding_store_error;
    ingress_refusal (Channel_gate_binding_store.binding_store_error_to_string reason)
  | Ok None ->
    Slack_observability.record_ambient Slack_observability.Ambient_dropped_unbound;
    Ok (Gw.Intentionally_ignored Gw.Unbound_channel)
  | Ok (Some resolution) ->
    let keeper_name = resolution.State.keeper_name in
    if String.equal (String.trim text) "" then begin
      Slack_observability.record_ambient Slack_observability.Ambient_dropped_empty;
      Ok (Gw.Intentionally_ignored Gw.Empty_message)
    end else if String.length text > Channel_gate.max_content_length () then begin
      Slack_observability.record_ambient Slack_observability.Ambient_dropped_too_long;
      Ok (Gw.Intentionally_ignored Gw.Oversized_message)
    end else
      let channel_name = resolve_channel_name ~base_dir
        ~token:(Env_config_slack.bot_token_opt ()) ~channel_id in
      let* original = record_external_attention ~base_dir ~keeper_name ~team_id ~channel_id
        ~channel_name ~thread_ts ~ts ~user_id ~user_name ~content:text ~mentions_bot
        ~route:"ambient" ~urgency:Keeper_external_attention.Ambient
        |> Result.map_error (fun detail -> Gw.Retryable_refusal detail) in
      let* _ = restore_original_source ~keeper_name ~team_id ~channel_id ~thread_ts ~ts ~user_id original in
      let* route = original_route original in
      match route with
      | Ambient_route -> finish_ambient_original ~base_dir ~keeper_name ~team_id ~channel_id ~thread_ts ~ts ~user_id original
      | Triggered_route -> recover_triggered original

let on_ambient ~recover_triggered ?team_id ~base_dir (ev : Gw.slack_event) =
  Option.iter State.record_workspace_id team_id;
  match ev with
  | Gw.Message_create {channel_id; thread_ts; user_id; user_name; text; ts; mentions_bot;
      bot_id=None; files} ->
    handle_ambient ~recover_triggered ~base_dir ~team_id ~channel_id ~thread_ts ~user_id ~user_name
      ~text:(Gw.text_with_files ~text ~files) ~ts ~mentions_bot ()
  | Gw.Message_create {bot_id=Some _;_} | Gw.App_mention _ ->
    Ok (Gw.Intentionally_ignored Gw.Bot_echo)
  | Gw.Reaction_added _ ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Ambient
      Slack_observability.Reaction_added;
    Ok (Gw.Intentionally_ignored Gw.Observational_event)
  | Gw.Ignored_event _ -> Ok (Gw.Intentionally_ignored Gw.Observational_event)

let submit_ambient_event ?team_id ?user_directory ingress ~dispatch_for_delivery ~clock ~base_dir ev =
  let ev = resolve_event_identity ?user_directory ev in
  let ev = remember_resolved_names ~base_dir ev in
  let recover_triggered (original : Keeper_external_attention.item) =
    match original.conversation.surface, original.actor.actor_id, original.external_message with
    | Surface_ref.Slack surface, Some user_id, Some message ->
      let* _, mentions_bot = restore_original_source ~keeper_name:original.keeper_name
        ~team_id:surface.team_id ~channel_id:surface.channel_id ~thread_ts:surface.thread_ts
        ~ts:message.message_id ~user_id original in
      let original_event = Gw.Message_create {channel_id=surface.channel_id;
        thread_ts=surface.thread_ts; user_id; user_name=original.actor.display_name;
        text=original.content_preview; ts=message.message_id; mentions_bot; bot_id=None; files=[]} in
      submit_event ?team_id:surface.team_id ingress ~dispatch_for_delivery ~clock ~base_dir original_event
    | (Surface_ref.Slack _ | Surface_ref.Dashboard _ | Surface_ref.Discord _ | Surface_ref.Webhook _
      | Surface_ref.Agent | Surface_ref.Broadcast | Surface_ref.Gate _), (Some _ | None), (Some _ | None) ->
      ingress_refusal "original triggered source has no complete Slack route"
  in
  on_ambient ~recover_triggered ?team_id ~base_dir ev
;;

module For_testing = struct
  let submit_event = submit_event
  let submit_ambient_event = submit_ambient_event
  let record_external_attention = record_external_attention
  let resolve_event_identity = resolve_event_identity
end

(* ---------------------------------------------------------------- *)
(* Start                                                            *)
(* ---------------------------------------------------------------- *)

let start ~sw ~env ~state =
  match resolved_trigger_policy () with
  | Error error ->
    let detail = trigger_policy_load_error_to_string error in
    State.record_startup_error detail;
    Log.Server.error
      "RFC-0317: Slack trigger-policy configuration rejected; gateway not \
       started (%s)"
      detail
  | Ok configured ->
    (* Publish configuration before disabled/token admission; transport state
       must not substitute a baseline for the operator's configured policy. *)
    Connector_trigger_params.set_slack_configured configured;
    State.clear_startup_error ();
    match Env_config_slack.app_token_opt () with
    | None ->
      (match Env_config_slack.connector_state () with
       | Invalid_configuration detail ->
         State.record_startup_error detail;
         Log.Server.error "%s; Slack gateway not started" detail
       | Disabled ->
         Log.Server.info "Slack connector disabled by [slack] enabled=false"
       | Enabled ->
         Log.Server.warn
           "RFC-0317: SLACK_APP_TOKEN is unset; in-process Slack gateway not \
            started")
    | Some app_token ->
       (* An override left on the params surface outlives a restart, so what
          this gateway judges by is the param, not [configured] alone. *)
       let policy = current_trigger_policy () in
       (* One clock for the whole gateway: bounds [auth.test], durable accept,
          and outbound ACK sends. *)
       let clock = Eio.Stdenv.clock env in
       (* Resolve the bot's own identity for mention detection. Non-fatal:
          without it, [app_mention] events still trigger (a mention by
          construction); only plain-message mention detection on the [message]
          event degrades. *)
       State.clear_workspace_id ();
       let bot_user_id, team_id, user_directory =
         match Env_config_slack.bot_token_opt () with
         | None ->
           Log.Server.warn
             "RFC-0317: SLACK_BOT_TOKEN unset; Slack plain-message mention \
              detection disabled (app_mention still triggers)";
           None, None, None
         | Some bot_token ->
           (* Inbound identity rendering (issue #28376) shares the bot token:
              the directory resolves author ids to display labels through
              users.info, bounded by the same gateway clock. *)
           let user_directory =
             Some
               (Slack_user_directory.create
                  ~fetch:(fun ~user_id ->
                    Slack_rest_client.users_info ~clock ~token:bot_token
                      ~user_id ())
                  ~now:Unix.gettimeofday
                    (* NDT-OK: cache-expiry clock only *)
                  ())
           in
           (match Slack_rest_client.auth_test ~clock ~token:bot_token () with
            | Ok { user_id; team_id } ->
              State.record_ready ~bot_user_id:user_id;
              Option.iter State.record_workspace_id team_id;
              Log.Server.info "RFC-0317: Slack auth.test ok (bot_user_id=%s)"
                user_id;
              Some user_id, team_id, user_directory
            | Error e ->
              Log.Server.warn
                "RFC-0317: Slack auth.test failed (%s); proceeding without \
                 bot_user_id"
                (Format.asprintf "%a" Slack_rest_client.pp_error e);
              None, None, user_directory)
       in
       let gateway_base_path = (Mcp_server.workspace_config state).Workspace.base_path in
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
             ~trigger_policy:current_trigger_policy
             ~on_event:(fun ev ->
               let config = Mcp_server.workspace_config state in
               if not (String.equal config.Workspace.base_path gateway_base_path) then
                 ingress_refusal "Slack gateway workspace changed; reconnect its owner before accepting events"
               else submit_event
                 ingress
                 ~dispatch_for_delivery:(dispatch_for_config config)
                 ?team_id
                 ?user_directory
                 ~clock
                 ~base_dir:config.base_path
                 ev)
             ~on_ambient:(fun ev ->
               let config = Mcp_server.workspace_config state in
               if not (String.equal config.Workspace.base_path gateway_base_path) then
                 ingress_refusal "Slack gateway workspace changed; reconnect its owner before accepting events"
               else submit_ambient_event ?team_id ?user_directory ingress
                 ~dispatch_for_delivery:(dispatch_for_config config) ~clock
                 ~base_dir:config.base_path ev)
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.error "RFC-0317: in-process Slack gateway crashed: %s"
             (Printexc.to_string exn))
