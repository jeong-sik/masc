(* See .mli for high-level shape.

   RFC-0317 PR-3: the in-process Slack Socket Mode gateway. Mirrors
   {!Server_discord_in_process_gateway}: fork a long-running fiber that runs
   {!Slack_socket_client.run} and, for each triggered event, looks up the
   channel→keeper binding and durably accepts the exact event before the socket
   callback returns. The connector lane then projects only the threaded ACK;
   the durable queue consumer owns the Keeper turn and final reply.

   Differences from the Discord gateway:
   - No ambient/wake path this pass: the FSM only surfaces policy-passing
     Message_create / App_mention and (ambient) Reaction_added. Recording
     ambient user lines and waking idle keepers on them is RFC-0317 follow-up
     scope, matching the Discord gateway's staged rollout. *)

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

let slack_delivery ~channel_id ~thread_ts ~reply_to_thread_ts ~user_id
    ~user_name ~ts : Gate_keeper_backend.connector_delivery =
  { source =
      Keeper_chat_queue.Slack
        { channel_id
        ; user_id
        ; user_name
        ; team_id = None
        ; thread_ts = Some reply_to_thread_ts
        }
  ; surface = Surface_ref.Slack { team_id = None; channel_id; thread_ts }
  ; conversation_id = Some (slack_conversation_id ~channel_id)
  ; external_message_id = Some ts
  }

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

type accepted_inbound =
  { channel_id : string
  ; reply_to_thread_ts : string
  ; keeper_name : string
  ; outcome : (Channel_gate.outbound_message, Channel_gate.gate_error) result
  }

let accept_inbound ~resolved_binding ~dispatch_for_delivery ~channel_id
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
      ; channel_workspace_id = channel_id
      ; keeper_name
      ; content = text
      ; idempotency_key = Printf.sprintf "slack-msg-%s" ts
        (* Slack sends both [message] and [app_mention] for an @mention; keying
           on the shared [ts] makes the gate's dedup collapse them to one turn. *)
      ; metadata
      }
    in
    let user_name = Option.value user_name ~default:user_id in
    let delivery =
      slack_delivery ~channel_id ~thread_ts ~reply_to_thread_ts ~user_id
        ~user_name ~ts
    in
    Some
      { channel_id
      ; reply_to_thread_ts
      ; keeper_name
      ; outcome =
          Channel_gate.handle_inbound
            ~dispatch:(dispatch_for_delivery delivery) msg
      }

let deliver_inbound ~clock accepted =
  let { channel_id; reply_to_thread_ts; keeper_name; outcome } = accepted in
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

let accept_event ~resolved_binding ~dispatch_for_delivery
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
      accept_inbound ~resolved_binding ~dispatch_for_delivery ~channel_id ~thread_ts
        ~user_id ~user_name ~text ~ts ~mentions_bot ~is_app_mention:false)
  | Gw.App_mention { channel_id; thread_ts; user_id; text; ts } ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Triggered
      Slack_observability.App_mention;
    accept_inbound ~resolved_binding ~dispatch_for_delivery ~channel_id ~thread_ts
      ~user_id
      ~user_name:None ~text ~ts ~mentions_bot:true ~is_app_mention:true
  | Gw.Reaction_added _ ->
    (* Ambient this pass: reactions are not turn-starters (RFC-0317). *)
    Slack_observability.record_gateway_event ~route:Slack_observability.Ambient
      Slack_observability.Reaction_added;
    None
  | Gw.Ignored_event _ ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Control
      Slack_observability.Ignored;
    None

let slack_event_opaque_id : Gw.slack_event -> string = function
  | Gw.Message_create { ts; _ }
  | Gw.App_mention { ts; _ } -> ts
  | Gw.Reaction_added { message_ts; _ } -> message_ts
  | Gw.Ignored_event reason -> reason
;;

let submit_event ?deliver ingress ~dispatch_for_delivery ~clock
    (ev : Gw.slack_event) =
  let submit ~channel_id ~event_id =
    match State.resolve_keeper_for_channel_result ~channel_id with
    | Error reason ->
      Slack_observability.record_inbound_dispatch Slack_observability.Gate_error;
      Log.Server.error
        "Slack ingress binding unavailable channel=%s event=%s: %s"
        channel_id event_id reason
    | Ok resolved_binding ->
      let lane =
        match resolved_binding with
        | Some resolution ->
          Connector_ingress_lane.Keeper_lane resolution.State.keeper_name
        | None -> Connector_ingress_lane.Connector_lane State.channel
      in
      (match
         Connector_ingress_lane.run_isolated
           ingress
           ~lane
           ~event_id:
             { source = "slack_triggered_accept"; opaque_id = event_id }
           (fun () ->
             accept_event ~resolved_binding ~dispatch_for_delivery ev)
       with
       | Error _ | Ok None -> ()
       | Ok (Some accepted) ->
        Connector_ingress_lane.submit
          ingress
          ~lane:(Connector_ingress_lane.Keeper_lane accepted.keeper_name)
          ~event_id:{ source = "slack_triggered"; opaque_id = event_id }
          (match deliver with
           | Some deliver -> deliver
           | None -> fun () -> deliver_inbound ~clock accepted))
  in
  match ev with
  | Gw.Message_create { bot_id = Some _; _ } ->
    ignore
      (Connector_ingress_lane.run_isolated
         ingress
         ~lane:(Connector_ingress_lane.Connector_lane State.channel)
         ~event_id:
           { source = "slack_control"; opaque_id = slack_event_opaque_id ev }
         (fun () ->
           accept_event ~resolved_binding:None ~dispatch_for_delivery ev))
  | Gw.Message_create { channel_id; ts; bot_id = None; _ }
  | Gw.App_mention { channel_id; ts; _ } -> submit ~channel_id ~event_id:ts
  | Gw.Reaction_added _ | Gw.Ignored_event _ ->
    ignore
      (Connector_ingress_lane.run_isolated
         ingress
         ~lane:(Connector_ingress_lane.Connector_lane State.channel)
         ~event_id:
           { source = "slack_control"; opaque_id = slack_event_opaque_id ev }
         (fun () ->
           accept_event ~resolved_binding:None ~dispatch_for_delivery ev))
;;

module For_testing = struct
  let submit_event = submit_event
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
       let bot_user_id =
         match Env_config_slack.bot_token_opt () with
         | None ->
           Log.Server.warn
             "RFC-0317: SLACK_BOT_TOKEN unset; Slack plain-message mention \
              detection disabled (app_mention still triggers)";
           None
         | Some bot_token -> (
           match Slack_rest_client.auth_test ~clock ~token:bot_token () with
           | Ok { user_id; team_id = _ } ->
             State.record_ready ~bot_user_id:user_id;
             Log.Server.info "RFC-0317: Slack auth.test ok (bot_user_id=%s)"
               user_id;
             Some user_id
           | Error e ->
             Log.Server.warn
               "RFC-0317: Slack auth.test failed (%s); proceeding without \
                bot_user_id"
               (Format.asprintf "%a" Slack_rest_client.pp_error e);
             None)
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
               failure.reason)
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
                 ~clock
                 ev)
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.error "RFC-0317: in-process Slack gateway crashed: %s"
             (Printexc.to_string exn)))
