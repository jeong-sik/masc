module Intent = Keeper_continuation_delivery_intent
module Store = Keeper_continuation_delivery_store

type connector_request =
  | Discord of
      { channel_id : string
      ; content : string
      ; reply_to_message_id : string option
      }
  | Slack of
      { channel_id : string
      ; content : string
      ; reply_to_message_id : string option
      }

type connector_outcome =
  | Sent of { message_id : string }
  | Rejected of { detail : string }
  | Indeterminate of { detail : string }

type transcript_outcome =
  | Appended of { row_id : string }
  | Already_present of { row_id : string }

type adapter =
  { now : unit -> float
  ; append_transcript :
      config:Workspace.config ->
      Intent.t ->
      (transcript_outcome, string) result
  ; send_connector : connector_request -> connector_outcome
  }

type outcome =
  | Delivered of Intent.t
  | Failed of Intent.t
  | Ambiguous of Intent.t

type error =
  | Store_failed of Store.error
  | Intent_transition_failed of Intent.error
  | Transcript_failed of string
  | Invalid_delivery_identity of string

let ( let* ) = Result.bind

let error_to_string = function
  | Store_failed error -> Store.error_to_string error
  | Intent_transition_failed error -> Intent.error_to_string error
  | Transcript_failed detail ->
    "continuation delivery transcript failed: " ^ detail
  | Invalid_delivery_identity detail ->
    "continuation delivery identity failed: " ^ detail
;;

let persist ~config intent =
  Store.persist ~config intent
  |> Result.map (fun _ -> intent)
  |> Result.map_error (fun error -> Store_failed error)
;;

let transition transition intent =
  transition intent |> Result.map_error (fun error -> Intent_transition_failed error)
;;

let terminal_outcome intent =
  match intent.Intent.state with
  | Intent.Delivered _ -> Ok (Delivered intent)
  | Intent.Failed _ -> Ok (Failed intent)
  | Intent.Ambiguous _ -> Ok (Ambiguous intent)
  | Intent.Pending | Intent.Attempting _ ->
    Error
      (Intent_transition_failed
         (Intent.Invalid_transition
            "publisher terminal outcome retained a non-terminal state"))
;;

let mark_delivered ~adapter ~config ?connector_message_id intent =
  let* delivered =
    transition
      (Intent.mark_delivered
         ~completed_at:(adapter.now ())
         ?connector_message_id)
      intent
  in
  let* delivered = persist ~config delivered in
  Ok (Delivered delivered)
;;

let mark_failed ~adapter ~config ~detail intent =
  let* failed =
    transition
      (Intent.mark_failed
         ~completed_at:(adapter.now ())
         ~kind:Intent.Adapter_rejected
         ~detail)
      intent
  in
  let* failed = persist ~config failed in
  Ok (Failed failed)
;;

let mark_ambiguous ~adapter ~config ~detail intent =
  let* ambiguous =
    transition
      (Intent.mark_ambiguous ~detected_at:(adapter.now ()) ~detail)
      intent
  in
  let* ambiguous = persist ~config ambiguous in
  Ok (Ambiguous ambiguous)
;;

let connector_request_of_channel channel ~content =
  match channel with
  | Keeper_continuation_channel.Discord
      { channel_id; reply_to_message_id; _ } ->
    Some (Discord { channel_id; content; reply_to_message_id })
  | Keeper_continuation_channel.Slack { channel_id; thread_ts; _ } ->
    Some
      (Slack
         { channel_id; content; reply_to_message_id = thread_ts })
  | Keeper_continuation_channel.Dashboard _
  | Keeper_continuation_channel.Unrouted _ ->
    None
;;

let append_dashboard ~adapter ~config intent =
  match adapter.append_transcript ~config intent with
  | Error detail -> Error (Transcript_failed detail)
  | Ok (Appended _ | Already_present _) -> mark_delivered ~adapter ~config intent
;;

let publish_external ~adapter ~config intent request =
  match adapter.send_connector request with
  | Rejected { detail } -> mark_failed ~adapter ~config ~detail intent
  | Indeterminate { detail } -> mark_ambiguous ~adapter ~config ~detail intent
  | Sent { message_id } ->
    (match adapter.append_transcript ~config intent with
     | Error detail ->
       mark_ambiguous
         ~adapter
         ~config
         ~detail:("connector sent but transcript settlement failed: " ^ detail)
         intent
     | Ok (Appended _ | Already_present _) ->
       mark_delivered ~adapter ~config ~connector_message_id:message_id intent)
;;

let resume_attempt ~adapter ~config intent =
  match intent.Intent.origin.channel with
  | Keeper_continuation_channel.Dashboard _ ->
    append_dashboard ~adapter ~config intent
  | Keeper_continuation_channel.Discord _
  | Keeper_continuation_channel.Slack _ ->
    mark_ambiguous
      ~adapter
      ~config
      ~detail:
        "recovered an external connector attempt without a durable receipt; automatic resend suppressed"
      intent
  | Keeper_continuation_channel.Unrouted _ ->
    mark_failed
      ~adapter
      ~config
      ~detail:"continuation intent retained an unroutable channel"
      intent
;;

let publish_pending ~adapter ~config intent =
  let* _ = persist ~config intent in
  let* attempting =
    transition (Intent.start_attempt ~started_at:(adapter.now ())) intent
  in
  let* attempting = persist ~config attempting in
  match attempting.Intent.origin.channel with
  | Keeper_continuation_channel.Dashboard _ ->
    append_dashboard ~adapter ~config attempting
  | (Keeper_continuation_channel.Discord _ | Keeper_continuation_channel.Slack _)
    as channel ->
    (match
       connector_request_of_channel
         channel
         ~content:attempting.Intent.response.text
     with
     | Some request -> publish_external ~adapter ~config attempting request
     | None ->
       mark_failed
         ~adapter
         ~config
         ~detail:"routable connector did not produce a send request"
         attempting)
  | Keeper_continuation_channel.Unrouted _ ->
    mark_failed
      ~adapter
      ~config
      ~detail:"continuation intent retained an unroutable channel"
      attempting
;;

let publish_with_adapter ~adapter ~config intent =
  match intent.Intent.state with
  | Intent.Pending -> publish_pending ~adapter ~config intent
  | Intent.Attempting _ -> resume_attempt ~adapter ~config intent
  | Intent.Delivered _ | Intent.Failed _ | Intent.Ambiguous _ ->
    let* stored = persist ~config intent in
    terminal_outcome stored
;;

let delivery_key intent =
  Keeper_chat_delivery_identity.Request_id.of_string
    (Intent.Intent_id.to_string intent.Intent.intent_id)
  |> Result.map (fun id -> Keeper_chat_delivery_identity.Continuation id)
  |> Result.map_error (fun detail -> Invalid_delivery_identity detail)
;;

let discord_conversation_id ~guild_id ~channel_id =
  let guild_label =
    match guild_id with
    | Some guild_id -> guild_id
    | None -> "dm"
  in
  Printf.sprintf "discord:%s:channel:%s" guild_label channel_id
;;

let surface_coordinates intent =
  match intent.Intent.origin.channel with
  | Keeper_continuation_channel.Dashboard { thread_id } ->
    Surface_ref.Dashboard { session_id = Some thread_id }, Some thread_id
  | Keeper_continuation_channel.Discord
      { guild_id; channel_id; parent_channel_id; thread_id; _ } ->
    ( Surface_ref.Discord
        { guild_id; channel_id; parent_channel_id; thread_id }
    , Some (discord_conversation_id ~guild_id ~channel_id) )
  | Keeper_continuation_channel.Slack
      { team_id; channel_id; thread_ts; _ } ->
    ( Surface_ref.Slack { team_id; channel_id; thread_ts }
    , Some (Printf.sprintf "slack:channel:%s" channel_id) )
  | Keeper_continuation_channel.Unrouted _ ->
    Surface_ref.Agent, None
;;

let append_transcript ~config intent =
  let* delivery_key = delivery_key intent |> Result.map_error error_to_string in
  let surface, conversation_id = surface_coordinates intent in
  match
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:config.Workspace.base_path
      ~keeper_name:intent.Intent.keeper_name
      ~delivery_key
      ~content:intent.Intent.response.text
      ~surface
      ?conversation_id
      ()
  with
  | Error detail -> Error detail
  | Ok (Keeper_chat_store.Appended { row_id }) ->
    Keeper_chat_broadcast.chat_appended
      ~keeper_name:intent.Intent.keeper_name
      ~source:"continuation"
      ~content:intent.Intent.response.text
      ();
    Ok (Appended { row_id })
  | Ok (Keeper_chat_store.Already_present { row_id }) ->
    Ok (Already_present { row_id })
;;

let send_connector = function
  | Discord { channel_id; content; reply_to_message_id } ->
    (match
       Channel_gate_discord_state.send_message
         ~channel_id
         ~content
         ?reply_to_message_id
         ()
     with
     | Ok message_id -> Sent { message_id }
     | Error Channel_gate_discord_state.Missing_token ->
       Rejected { detail = "Discord bot token is unavailable" }
     | Error (Channel_gate_discord_state.Rest_error error) ->
       Indeterminate
         { detail = Format.asprintf "Discord send failed: %a" Discord_rest_client.pp_error error })
  | Slack { channel_id; content; reply_to_message_id } ->
    (match
       Channel_gate_slack_state.send_message
         ~channel_id
         ~content
         ?reply_to_message_id
         ()
     with
     | Ok message_id -> Sent { message_id }
     | Error Channel_gate_slack_state.Missing_token ->
       Rejected { detail = "Slack bot token is unavailable" }
     | Error (Channel_gate_slack_state.Rest_error error) ->
       Indeterminate
         { detail = Format.asprintf "Slack send failed: %a" Slack_rest_client.pp_error error })
;;

let production_adapter =
  { now = Time_compat.now; append_transcript; send_connector }
;;

let publish ~config intent =
  publish_with_adapter ~adapter:production_adapter ~config intent
;;

module For_testing = struct
  let publish_with_adapter = publish_with_adapter
end
