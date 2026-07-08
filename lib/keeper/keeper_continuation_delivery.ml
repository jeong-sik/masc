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

let slack_token_opt () =
  match Sys.getenv_opt "MASC_SLACK_BOT_TOKEN" with
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some trimmed

let deliver_dashboard ~config ~keeper_name ~content =
  Keeper_chat_store.append_assistant_message
    ~base_dir:config.Workspace.base_path ~keeper_name ~content
    ~surface:(Surface_ref.Dashboard { session_id = None }) ();
  Keeper_chat_broadcast.chat_appended ~keeper_name ~source:"dashboard" ~content ();
  Delivered { kind = "dashboard" }

let deliver_discord ~config ~keeper_name ~channel_id ~content =
  match Channel_gate_discord_state.send_message ~channel_id ~content () with
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
             {
               guild_id = None;
               channel_id;
               parent_channel_id = None;
               thread_id = None;
             })
        ();
      Keeper_chat_broadcast.chat_appended ~keeper_name ~source:"discord"
        ~content ();
      Delivered { kind = "discord" }

let deliver_slack ~config ~keeper_name ~channel_id ~content =
  match slack_token_opt () with
  | None ->
      Failed { kind = "slack"; error = "MASC_SLACK_BOT_TOKEN is unset or empty" }
  | Some token -> (
      let blocks = Keeper_chat_slack.content_blocks_of_text content in
      match
        Keeper_chat_slack.send_message_with_blocks ~token ~channel:channel_id
          ~content ~blocks
      with
      | Error err ->
          Failed
            {
              kind = "slack";
              error = Format.asprintf "%a" Keeper_chat_slack.pp_error err;
            }
      | Ok () ->
          Keeper_chat_store.append_assistant_message
            ~base_dir:config.Workspace.base_path ~keeper_name ~content
            ~surface:
              (Surface_ref.Slack
                 { team_id = None; channel_id; thread_ts = None })
            ();
          Keeper_chat_broadcast.chat_appended ~keeper_name ~source:"slack"
            ~content ();
          Delivered { kind = "slack" })

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
      | Keeper_continuation_channel.Dashboard { thread_id = _ } ->
          deliver_dashboard ~config ~keeper_name ~content
      | Keeper_continuation_channel.Discord { channel_id; _ } ->
          deliver_discord ~config ~keeper_name ~channel_id ~content
      | Keeper_continuation_channel.Slack { channel_id; _ } ->
          deliver_slack ~config ~keeper_name ~channel_id ~content
      (* [gate_decision] returns [Skip] for [Unrouted]; this arm keeps the
         match exhaustive and is unreachable via [Deliver]. *)
      | Keeper_continuation_channel.Unrouted _ -> Skipped_unrouted)
