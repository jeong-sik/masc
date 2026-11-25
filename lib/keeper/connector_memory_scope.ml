type t =
  | Discord of
      { account : Connector_account_ref.t
      ; guild_id : string option
      ; channel_id : string
      }

let of_surface ~account = function
  | Surface_ref.Discord { guild_id; channel_id; thread_id; _ }
    when Connector_account_ref.is_discord_snowflake channel_id
         && Option.fold ~none:true ~some:Connector_account_ref.is_discord_snowflake guild_id
         && Option.fold ~none:true ~some:(String.equal channel_id) thread_id ->
    Some (Discord { account; guild_id; channel_id })
  | Discord _ | Dashboard _ | Slack _ | Webhook _ | Agent | Broadcast | Gate _ -> None

let destination_to_json (Discord { account = _; guild_id; channel_id }) : Yojson.Safe.t =
  `Assoc
    [ "kind", `String "discord"
    ; "guild_id", Option.fold ~none:`Null ~some:(fun id -> `String id) guild_id
    ; "channel_id", `String channel_id
    ]
