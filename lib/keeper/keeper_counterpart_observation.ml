type origin =
  | Connector_attention

type authority =
  | Owner
  | External
  | Keeper

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
;;

let authority_to_string = function
  | Owner -> "owner"
  | External -> "external"
  | Keeper -> "keeper"
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
  | Keeper_chat_store.Keeper -> Keeper
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
