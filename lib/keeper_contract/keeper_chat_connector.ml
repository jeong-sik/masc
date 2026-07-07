(** Shared keeper chat connector identity. *)

type t =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

let to_yojson = function
  | Dashboard -> `Assoc [ ("kind", `String "dashboard") ]
  | Discord { channel_id; user_id } ->
    `Assoc
      [ ("kind", `String "discord")
      ; ("channel_id", `String channel_id)
      ; ("user_id", `String user_id)
      ]
  | Slack { channel; user_id } ->
    `Assoc
      [ ("kind", `String "slack")
      ; ("channel", `String channel)
      ; ("user_id", `String user_id)
      ]
;;

let of_yojson json =
  match Json_util.get_string json "kind" with
  | Some "dashboard" -> Ok Dashboard
  | Some "discord" ->
    let channel_id =
      Json_util.get_string_with_default json ~key:"channel_id" ~default:""
    in
    let user_id = Json_util.get_string_with_default json ~key:"user_id" ~default:"" in
    if String.trim channel_id = "" || String.trim user_id = ""
    then Error "discord chat connector requires channel_id and user_id"
    else Ok (Discord { channel_id; user_id })
  | Some "slack" ->
    let channel = Json_util.get_string_with_default json ~key:"channel" ~default:"" in
    let user_id = Json_util.get_string_with_default json ~key:"user_id" ~default:"" in
    if String.trim channel = "" || String.trim user_id = ""
    then Error "slack chat connector requires channel and user_id"
    else Ok (Slack { channel; user_id })
  | Some kind -> Error (Printf.sprintf "unsupported chat connector kind: %s" kind)
  | None -> Error "chat connector requires kind"
;;

