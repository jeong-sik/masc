type t = Discord_user of int64

let discord_snowflake source =
  match Int64.of_string_opt ("0u" ^ source) with
  | Some id when id <> 0L && String.equal (Printf.sprintf "%Lu" id) source -> Some id
  | Some _ | None -> None

let is_discord_snowflake source = Option.is_some (discord_snowflake source)

let discord_user user_id = Option.map (fun id -> Discord_user id) (discord_snowflake user_id)

let matches_actor (Discord_user id) ~surface ~actor_id =
  match surface, actor_id with
  | Surface_ref.Discord _, Some user_id ->
    String.equal (Printf.sprintf "%Lu" id) user_id
  | (Surface_ref.Dashboard _ | Discord _ | Slack _ | Webhook _ | Agent | Broadcast | Gate _), _ ->
    false

let to_json (Discord_user id) : Yojson.Safe.t =
  `Assoc
    [ "kind", `String "discord_user"
    ; "version", `Int 1
    ; "user_id", `String (Printf.sprintf "%Lu" id)
    ]

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let sorted = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
    (match sorted with
     | [ "kind", `String "discord_user"; "user_id", `String user_id; "version", `Int 1 ] ->
       (match discord_user user_id with
        | Some account -> Ok (Some account)
        | None -> Error "invalid Discord account snowflake")
     | _ ->
       (match List.assoc_opt "kind" sorted, List.assoc_opt "version" sorted with
        | Some (`String kind), Some (`Int version)
          when kind <> "" && String.equal kind (String.trim kind) && version > 0
               && (kind <> "discord_user" || version > 1) ->
          let names = List.map fst sorted in
          if List.length names = List.length (List.sort_uniq String.compare names)
          then Ok None
          else Error "duplicate connector account key field"
        | _ -> Error "invalid connector account key"))
  | _ -> Error "invalid connector account key"
