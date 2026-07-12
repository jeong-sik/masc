(* See .mli for high-level shape.

   RFC-0317 PR-3: the in-process Slack Socket Mode gateway. Mirrors
   {!Server_discord_in_process_gateway}: fork a long-running fiber that runs
   {!Slack_socket_client.run} and, for each triggered event, looks up the
   channel→keeper binding, runs the keeper turn through
   {!Channel_gate.handle_inbound_streaming}, and projects redacted text
   snapshots by posting/editing one threaded Slack reply.

   Differences from the Discord gateway:
   - No typing indicator: Slack has no bot-typing surface, so the streaming
     reply itself (initial post + edits) is the progress projection.
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

type authenticated_workspace =
  { bot_user_id : string
  ; team_id : string
  }

type auth_workspace_error =
  | Bot_token_missing
  | Auth_test_failed of Slack_rest_client.error
  | Workspace_provenance_missing of { bot_user_id : string }

let resolve_authenticated_workspace
    ~(auth_test :
       token:string ->
       (Slack_rest_client.auth_test_ok, Slack_rest_client.error) result)
    ~bot_token =
  match bot_token with
  | None -> Error Bot_token_missing
  | Some token ->
    (match auth_test ~token with
     | Error error -> Error (Auth_test_failed error)
     | Ok { user_id; team_id = None } ->
       Error (Workspace_provenance_missing { bot_user_id = user_id })
     | Ok { user_id; team_id = Some team_id } ->
       let team_id = String.trim team_id in
       if String.equal team_id ""
       then Error (Workspace_provenance_missing { bot_user_id = user_id })
       else Ok { bot_user_id = user_id; team_id })
;;

let auth_workspace_error_to_string = function
  | Bot_token_missing -> "SLACK_BOT_TOKEN is unset or empty"
  | Auth_test_failed error ->
    Format.asprintf "Slack auth.test failed: %a" Slack_rest_client.pp_error error
  | Workspace_provenance_missing { bot_user_id } ->
    Printf.sprintf
      "Slack auth.test omitted team_id for bot_user_id=%s; workspace provenance is required"
      bot_user_id
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

let slack_team_provenance_metadata = State.team_provenance_metadata

(* Slack threads share the parent channel id, so the conversation id is keyed
   on the channel alone (unlike Discord's guild:channel). Consumed by the gate
   recorder to thread the persisted user line. *)
let slack_conversation_id ~channel_id = Printf.sprintf "slack:channel:%s" channel_id

(* ---------------------------------------------------------------- *)
(* Streaming reply projection                                       *)
(* ---------------------------------------------------------------- *)

type slack_stream_reply =
  { channel_id : string
  ; reply_to_thread_ts : string
      (* Slack ts of the thread root to post the reply under: the triggering
         message's own ts for a top-level message, or the existing thread_ts
         when the trigger already sits in a thread. *)
  ; mutable message_ts : string option
  ; mutable last_edit_time : float
  ; mutable last_edited_text : string
  ; mutable disabled : bool
  }

let make_slack_stream_reply ~channel_id ~reply_to_thread_ts =
  { channel_id
  ; reply_to_thread_ts
  ; message_ts = None
  ; last_edit_time = 0.0
  ; last_edited_text = ""
  ; disabled = false
  }

(* Redact provider secrets and clamp to Slack's per-message limit on a codepoint
   boundary. Reuses the Discord REST client's pure UTF-8 splitter (the same
   duplication-avoidance the Slack socket client already applies by reusing
   Discord_wss_connection for transport); the [~limit] argument makes it
   connector-neutral. *)
let slack_stream_content snapshot =
  let redacted = Observability_redact.redact_text snapshot in
  let head, _ =
    Discord_rest_client.split_at_codepoint redacted
      ~limit:Slack_rest_client.message_text_limit
  in
  head

let log_stream_error stage state error =
  Log.Server.warn
    "slack streaming %s failed (channel=%s thread=%s): %s"
    stage state.channel_id state.reply_to_thread_ts
    (Format.asprintf "%a" State.pp_send_error error)

let publish_slack_stream_snapshot ~clock state snapshot =
  if not state.disabled then begin
    let content = slack_stream_content snapshot in
    if
      not
        (String.equal content ""
        || String.equal content state.last_edited_text)
    then
      (* Wall-clock, read once per snapshot to throttle the streaming edit
         cadence (a minimum interval between chat.update calls); it gates I/O
         frequency only and never branches deterministic policy. NDT-OK. *)
      let now = Unix.gettimeofday () in
      match state.message_ts with
      | None -> (
        match
          State.send_message ~clock ~channel_id:state.channel_id ~content
            ~reply_to_message_id:state.reply_to_thread_ts ()
        with
        | Ok ts ->
          state.message_ts <- Some ts;
          state.last_edit_time <- now;
          state.last_edited_text <- content
        | Error error ->
          state.disabled <- true;
          log_stream_error "initial send" state error)
      | Some ts ->
        let elapsed = now -. state.last_edit_time in
        if elapsed >= Slack_rest_client.streaming_update_min_interval_sec then
          match
            State.edit_message ~clock ~channel_id:state.channel_id ~message_id:ts
              ~content ()
          with
          | Ok () ->
            state.last_edit_time <- now;
            state.last_edited_text <- content
          | Error error -> log_stream_error "edit" state error
  end

type stream_finish =
  | Stream_not_started
  | Stream_completed
  | Stream_final_edit_failed of State.send_error
  | Stream_overflow_send_failed of State.send_error

let finish_slack_stream_reply ~clock state ~final_content =
  match state.message_ts with
  | None -> Stream_not_started
  | Some ts ->
    let redacted = Observability_redact.redact_text final_content in
    let head, overflow =
      Discord_rest_client.split_at_codepoint redacted
        ~limit:Slack_rest_client.message_text_limit
    in
    let edit_result =
      if String.equal head state.last_edited_text then Ok ()
      else
        State.edit_message ~clock ~channel_id:state.channel_id ~message_id:ts
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
           State.send_message ~clock ~channel_id:state.channel_id
             ~content:overflow
             ~reply_to_message_id:state.reply_to_thread_ts ()
         with
         | Ok _ -> Stream_completed
         | Error error ->
           log_stream_error "overflow send" state error;
           Stream_overflow_send_failed error)

let replace_slack_stream_with_terminal ~clock state ~content =
  match finish_slack_stream_reply ~clock state ~final_content:content with
  | Stream_completed -> Ok ()
  | Stream_not_started ->
    Result.map
      (fun (_ : string) -> ())
      (State.send_message ~clock ~channel_id:state.channel_id ~content
         ~reply_to_message_id:state.reply_to_thread_ts ())
  | Stream_final_edit_failed error | Stream_overflow_send_failed error ->
    Error error

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

let handle_inbound ~dispatch ~clock ~team_id ~channel_id ~thread_ts ~user_id
    ~user_name ~text ~ts ~mentions_bot ~is_app_mention =
  match State.resolve_keeper_for_channel ~channel_id with
  | None ->
    (* No binding for this channel — drop quietly. The bot may sit in channels
       it isn't bound to. *)
    Slack_observability.record_inbound_dispatch
      Slack_observability.Dropped_unbound
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
      @ slack_team_provenance_metadata (Some team_id)
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
    let stream_reply = make_slack_stream_reply ~channel_id ~reply_to_thread_ts in
    let on_text_snapshot = publish_slack_stream_snapshot ~clock stream_reply in
    (match
     Channel_gate.handle_inbound_streaming
       ~admission_source:(Channel_gate.Slack { team_id; channel_id })
       ~dispatch ~on_text_snapshot msg
     with
     | Error gate_err -> (
       match Channel_gate.inbound_error_notice gate_err with
       | Channel_gate.Offline_notice ->
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
       | Channel_gate.Retry_notice ->
         let notice =
           Printf.sprintf
             "⚠️ `%s` 메시지를 처리하지 못했습니다. 잠시 후 다시 보내 주세요."
             keeper_name
         in
         Slack_observability.record_inbound_dispatch
           Slack_observability.Gate_error;
         (match
            State.send_message ~clock ~channel_id ~content:notice
              ~reply_to_message_id:reply_to_thread_ts ()
          with
          | Ok _ ->
            Slack_observability.record_reply Slack_observability.Reply_send_ok
          | Error e ->
            Slack_observability.record_reply
              Slack_observability.Reply_send_failed;
            Log.Server.error
              "slack send retry notice failed (channel=%s keeper=%s): %s"
              channel_id keeper_name
              (Format.asprintf "%a" State.pp_send_error e));
         Log.Server.warn
           "slack inbound -> keeper failed, retry notice attempted (channel=%s keeper=%s): %s"
           channel_id keeper_name
           (Channel_gate.gate_error_to_string gate_err)
       | Channel_gate.Accepted_failure_notice ->
         let notice =
           Printf.sprintf
             "⚠️ `%s` 메시지는 기록됐지만 이번 턴이 실패했습니다. 같은 메시지를 다시 보내지 말고 대시보드 상태를 확인해 주세요."
             keeper_name
         in
         Slack_observability.record_inbound_dispatch
           Slack_observability.Gate_error;
         (match
            replace_slack_stream_with_terminal ~clock stream_reply ~content:notice
          with
          | Ok () ->
            Slack_observability.record_reply Slack_observability.Reply_send_ok
          | Error e ->
            Slack_observability.record_reply
              Slack_observability.Reply_send_failed;
            Log.Server.error
              "slack replace stream with accepted-failure notice failed (channel=%s keeper=%s): %s"
              channel_id keeper_name
              (Format.asprintf "%a" State.pp_send_error e));
         Log.Server.warn
           "slack inbound -> accepted Keeper turn failed; dashboard notice attempted (channel=%s keeper=%s): %s"
           channel_id keeper_name
           (Channel_gate.gate_error_to_string gate_err)
       | Channel_gate.No_notice ->
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
           finish_slack_stream_reply ~clock stream_reply
             ~final_content:out.content
         with
         | Stream_completed ->
           Slack_observability.record_inbound_dispatch
             Slack_observability.Reply_sent;
           Slack_observability.record_reply Slack_observability.Reply_send_ok
         | Stream_not_started | Stream_final_edit_failed _ -> (
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
             Slack_observability.record_reply
               Slack_observability.Reply_send_failed;
             Log.Server.error "slack send_message failed (channel=%s): %s"
               channel_id
               (Format.asprintf "%a" State.pp_send_error e))
         | Stream_overflow_send_failed _ ->
           Slack_observability.record_inbound_dispatch
             Slack_observability.Reply_send_error;
           Slack_observability.record_reply
             Slack_observability.Reply_send_failed)

let on_event ~dispatch ~clock ~team_id (ev : Gw.slack_event) =
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
        Slack_observability.Ignored
    | None ->
      Slack_observability.record_gateway_event
        ~route:Slack_observability.Triggered Slack_observability.Message_create;
      handle_inbound ~dispatch ~clock ~team_id ~channel_id ~thread_ts ~user_id
        ~user_name ~text ~ts ~mentions_bot ~is_app_mention:false)
  | Gw.App_mention { channel_id; thread_ts; user_id; text; ts } ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Triggered
      Slack_observability.App_mention;
    handle_inbound ~dispatch ~clock ~team_id ~channel_id ~thread_ts ~user_id
      ~user_name:None ~text ~ts ~mentions_bot:true ~is_app_mention:true
  | Gw.Reaction_added _ ->
    (* Ambient this pass: reactions are not turn-starters (RFC-0317). *)
    Slack_observability.record_gateway_event ~route:Slack_observability.Ambient
      Slack_observability.Reaction_added
  | Gw.Ignored_event _ ->
    Slack_observability.record_gateway_event ~route:Slack_observability.Control
      Slack_observability.Ignored

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
       (* One clock for the whole gateway: bounds [auth.test] at start and every
          outbound reply send/edit, and feeds the dispatch adapter. *)
       let clock = Eio.Stdenv.clock env in
       let authentication =
         resolve_authenticated_workspace
           ~auth_test:(fun ~token ->
             Slack_rest_client.auth_test ~clock ~token ())
           ~bot_token:(Env_config_slack.bot_token_opt ())
       in
       (match authentication with
        | Error error ->
          let detail = auth_workspace_error_to_string error in
          State.record_startup_error detail;
          Log.Server.error
            "RFC-0317: Slack workspace authentication rejected; gateway not \
             started (%s)"
            detail
        | Ok { bot_user_id; team_id } ->
          State.clear_startup_error ();
          State.record_ready ~bot_user_id;
          State.set_trigger_policy policy;
          Log.Server.info
            "RFC-0317: Slack auth.test ok (bot_user_id=%s team_id=%s)"
            bot_user_id team_id;
          let dispatch =
            (* Tag this dispatch as the Slack connector so a message arriving
               while the keeper is in flight enqueues onto [Keeper_chat_queue]
               (drained by the serial consumer, delivered via
               [Keeper_chat_slack.adapter_loop]) rather than the outbound-less
               async poll store. *)
             Gate_keeper_backend.dispatch_with_text_snapshot
               ~connector_kind:Gate_keeper_backend.Slack
               ~submission_owner:Gate_keeper_backend.Channel_actor
               ~sw ~clock
              ~proc_mgr:state.Mcp_server.proc_mgr ~net:state.Mcp_server.net
              ~config:(Mcp_server.workspace_config state)
          in
          let policy_label = Gw.trigger_policy_to_string policy in
          Log.Server.info
            "RFC-0317: starting in-process Slack gateway (policy=%s)"
            policy_label;
          Eio.Fiber.fork ~sw (fun () ->
            try
              Slack_socket_client.run ~sw ~env
                ~bot_user_id:(Some bot_user_id) ~app_token
                ~trigger_policy:policy
                ~on_event:(fun ev -> on_event ~dispatch ~clock ~team_id ev)
                ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
               Log.Server.error "RFC-0317: in-process Slack gateway crashed: %s"
                 (Printexc.to_string exn))))
