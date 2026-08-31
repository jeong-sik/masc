type origin =
  | Connector_attention
  | Durable_chat

type authority =
  | Owner
  | External

type t = {
  origin : origin;
  channel : string;
  workspace_id : string option;
  user_id : string option;
  user_name : string option;
  authority : authority;
  content : string;
}

let origin_to_string = function
  | Connector_attention -> "connector_attention"
  | Durable_chat -> "durable_chat"
;;

let authority_to_string = function
  | Owner -> "owner"
  | External -> "external"
;;

let workspace_id_of_surface = function
  | Keeper_external_attention.Discord { guild_id; _ } -> guild_id
  | Keeper_external_attention.Slack { team_id; _ } -> team_id
  | Keeper_external_attention.Dashboard _
  | Keeper_external_attention.Webhook _
  | Keeper_external_attention.Agent
  | Keeper_external_attention.Broadcast
  | Keeper_external_attention.Gate _ -> None
;;

let authority_of_speaker = function
  | Keeper_chat_store.Owner -> Owner
  | Keeper_chat_store.External -> External
;;

let of_external_attention (item : Keeper_external_attention.item) =
  { origin = Connector_attention
  ; channel = item.source_label
  ; workspace_id = workspace_id_of_surface item.conversation.surface
  ; user_id = item.actor.actor_id
  ; user_name = item.actor.display_name
  ; authority = authority_of_speaker item.actor.authority
  ; content = item.content_preview
  }
;;

let surface_coordinates = function
  | None -> "direct", None
  | Some surface ->
    (match surface with
     | Surface_ref.Dashboard _ -> "dashboard", None
     | Surface_ref.Discord { guild_id; _ } -> "discord", guild_id
     | Surface_ref.Slack { team_id; _ } -> "slack", team_id
     | Surface_ref.Webhook { source; _ } -> source, None
     | Surface_ref.Agent -> "agent", None
     | Surface_ref.Broadcast -> "broadcast", None
     | Surface_ref.Gate { label; _ } -> label, None)
;;

let of_chat_message (message : Keeper_chat_store.chat_message) =
  match message.role, message.speaker with
  | Keeper_chat_store.Role.User, Some speaker ->
    let channel, surface_workspace = surface_coordinates message.surface in
    Some
      { origin = Durable_chat
      ; channel
      ; workspace_id =
          (match message.workspace_id with
           | Some _ as workspace_id -> workspace_id
           | None -> surface_workspace)
      ; user_id = speaker.speaker_id
      ; user_name = speaker.speaker_name
      ; authority = authority_of_speaker speaker.speaker_authority
      ; content = message.content
      }
  | Keeper_chat_store.Role.User, None
  | Keeper_chat_store.Role.Assistant, _
  | Keeper_chat_store.Role.System, _
  | Keeper_chat_store.Role.Tool, _ -> None
;;

let option_string_field name = function
  | None -> name, `Null
  | Some value -> name, `String value
;;

let to_yojson observation =
  `Assoc
    [ "origin", `String (origin_to_string observation.origin)
    ; "channel", `String observation.channel
    ; option_string_field "workspace_id" observation.workspace_id
    ; option_string_field "user_id" observation.user_id
    ; option_string_field "user_name" observation.user_name
    ; "authority", `String (authority_to_string observation.authority)
    ; "content", `String observation.content
    ]
;;

let render_for_prompt observations =
  observations
  |> List.map to_yojson
  |> fun values -> `List values
  |> Yojson.Safe.pretty_to_string
;;
