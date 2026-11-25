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

let to_json (Discord { account; _ } as scope) : Yojson.Safe.t =
  `Assoc [ "account", Connector_account_ref.to_json account
         ; "destination", destination_to_json scope ]

let sort_fields fields = List.sort (fun (left, _) (right, _) -> String.compare left right) fields

let of_json (json : Yojson.Safe.t) =
  let open Result.Syntax in
  match json with
  | `Assoc fields ->
    (match sort_fields fields with
     | [ "account", encoded_account; "destination", `Assoc destination ] ->
       let* decoded_account = Connector_account_ref.of_json encoded_account in
       (match decoded_account, sort_fields destination with
        | Some account,
          [ "channel_id", `String channel_id; "guild_id", guild; "kind", `String "discord" ] ->
          let decode guild_id =
            match of_surface ~account
                    (Surface_ref.Discord { guild_id; channel_id; channel_name = None;
                      parent_channel_id = None; thread_id = None }) with
            | Some scope -> Ok scope
            | None -> Error "invalid Discord Memory destination"
          in
          (match guild with
           | `Null -> decode None
           | `String id -> decode (Some id)
           | _ -> Error "invalid Discord Memory guild")
        | _ -> Error "invalid connector Memory scope")
     | _ -> Error "invalid connector Memory scope")
  | _ -> Error "invalid connector Memory scope"
