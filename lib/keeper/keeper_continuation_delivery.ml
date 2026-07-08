(* RFC-0320 W3c — deterministic delivery of a wake-turn response to the
   originating channel captured on a Hitl_resolved wake. The send calls mirror
   Keeper_tool_in_process_runtime.handle_surface_post (the keeper_surface_post
   tool) so a wake-turn reply lands exactly like a tool-authored reply. *)

type outcome =
  | Delivered of { kind : string }
  | Skipped_unrouted
  | Skipped_already_replied
  | Skipped_empty
  | Failed of { kind : string; error : string }

let describe_outcome = function
  | Delivered { kind } -> Printf.sprintf "delivered:%s" kind
  | Skipped_unrouted -> "skipped:unrouted"
  | Skipped_already_replied -> "skipped:already_replied"
  | Skipped_empty -> "skipped:empty"
  | Failed { kind; error } -> Printf.sprintf "failed:%s:%s" kind error

(* The originating surface identity captured by W2b (thread/session/parent
   coordinates) is preserved end-to-end so the reply lands in — and is audited
   against — the same conversation thread, not a fresh top-level post. *)

let deliver_dashboard ~config ~keeper_name ~thread_id ~content =
  Keeper_chat_store.append_assistant_message
    ~base_dir:config.Workspace.base_path ~keeper_name ~content
    ~surface:(Surface_ref.Dashboard { session_id = Some thread_id }) ();
  Keeper_chat_broadcast.chat_appended ~keeper_name ~source:"dashboard" ~content ();
  Delivered { kind = "dashboard" }

let deliver_discord ~config ~keeper_name ~guild_id ~channel_id
    ~parent_channel_id ~thread_id ~content =
  (* Discord threads are channels: post to the thread id when the conversation
     was in a thread, else the channel id. *)
  let send_channel_id = Option.value thread_id ~default:channel_id in
  match Channel_gate_discord_state.send_message ~channel_id:send_channel_id ~content () with
  | Error send_error ->
      Failed
        {
          kind = "discord";
          error =
            Format.asprintf "%a" Channel_gate_discord_state.pp_send_error
              send_error;
        }
  | Ok _message_id ->
      Keeper_chat_store.append_assistant_message
        ~base_dir:config.Workspace.base_path ~keeper_name ~content
        ~surface:
          (Surface_ref.Discord
             { guild_id; channel_id; parent_channel_id; thread_id })
        ();
      Keeper_chat_broadcast.chat_appended ~keeper_name ~source:"discord"
        ~content ();
      Delivered { kind = "discord" }

let deliver_slack ~config ~keeper_name ~team_id ~channel_id ~thread_ts ~content =
  (* [Channel_gate_slack_state.send_message] threads the reply via
     [reply_to_message_id] (a Slack [ts]) and resolves the bot token internally,
     so a continuation lands in the originating thread rather than a fresh
     top-level message. Plain content (no Block Kit) is the accepted trade-off
     for thread continuity. *)
  match
    Channel_gate_slack_state.send_message ~channel_id ~content
      ?reply_to_message_id:thread_ts ()
  with
  | Error send_error ->
      Failed
        {
          kind = "slack";
          error =
            Format.asprintf "%a" Channel_gate_slack_state.pp_send_error
              send_error;
        }
  | Ok _ts ->
      Keeper_chat_store.append_assistant_message
        ~base_dir:config.Workspace.base_path ~keeper_name ~content
        ~surface:(Surface_ref.Slack { team_id; channel_id; thread_ts })
        ();
      Keeper_chat_broadcast.chat_appended ~keeper_name ~source:"slack"
        ~content ();
      Delivered { kind = "slack" }

type gate =
  | Deliver
  | Skip of outcome

let gate_decision ~channel ~already_replied ~content : gate =
  if String.trim content = "" then Skip Skipped_empty
  else if already_replied then Skip Skipped_already_replied
  else
    match (channel : Keeper_continuation_channel.t) with
    | Keeper_continuation_channel.Unrouted _ -> Skip Skipped_unrouted
    | Keeper_continuation_channel.Dashboard _
    | Keeper_continuation_channel.Discord _
    | Keeper_continuation_channel.Slack _ ->
        Deliver

let maybe_deliver ~config ~keeper_name ~channel ~already_replied ~content =
  match gate_decision ~channel ~already_replied ~content with
  | Skip outcome -> outcome
  | Deliver -> (
      match (channel : Keeper_continuation_channel.t) with
      | Keeper_continuation_channel.Dashboard { thread_id } ->
          deliver_dashboard ~config ~keeper_name ~thread_id ~content
      | Keeper_continuation_channel.Discord
          { guild_id; channel_id; parent_channel_id; thread_id; user_id = _ } ->
          deliver_discord ~config ~keeper_name ~guild_id ~channel_id
            ~parent_channel_id ~thread_id ~content
      | Keeper_continuation_channel.Slack
          { team_id; channel_id; thread_ts; user_id = _ } ->
          deliver_slack ~config ~keeper_name ~team_id ~channel_id ~thread_ts
            ~content
      (* [gate_decision] returns [Skip] for [Unrouted]; this arm keeps the
         match exhaustive and is unreachable via [Deliver]. *)
      | Keeper_continuation_channel.Unrouted _ -> Skipped_unrouted)
