type t = Discord_user of int64

let discord_user user_id =
  match Int64.of_string_opt ("0u" ^ user_id) with
  | Some id when id <> 0L && String.equal (Printf.sprintf "%Lu" id) user_id ->
    Some (Discord_user id)
  | Some _ | None -> None

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
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "discord_user"; "user_id", `String user_id; "version", `Int 1 ] ->
       (match discord_user user_id with
        | Some account -> Ok account
        | None -> Error "invalid Discord account snowflake")
     | _ -> Error "invalid connector account key")
  | _ -> Error "invalid connector account key"
