(** Shared keeper chat connector identity. *)

type t =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

type decode_error =
  | Missing_kind
  | Missing_discord_fields
  | Missing_slack_fields
  | Unsupported_kind of string

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

let decode_error_to_string = function
  | Missing_kind -> "chat connector requires kind"
  | Missing_discord_fields -> "discord chat connector requires channel_id and user_id"
  | Missing_slack_fields -> "slack chat connector requires channel and user_id"
  | Unsupported_kind kind -> Printf.sprintf "unsupported chat connector kind: %s" kind
;;

let decode_error_to_chat_queue_source_string = function
  | Missing_kind -> "chat queue source requires kind"
  | Missing_discord_fields -> "discord chat queue source requires channel_id and user_id"
  | Missing_slack_fields -> "slack chat queue source requires channel and user_id"
  | Unsupported_kind kind -> Printf.sprintf "unsupported chat queue source kind: %s" kind
;;

let of_yojson_with_error json =
  match Json_util.get_string json "kind" with
  | Some "dashboard" -> Ok Dashboard
  | Some "discord" ->
    let channel_id =
      Json_util.get_string_with_default json ~key:"channel_id" ~default:""
    in
    let user_id = Json_util.get_string_with_default json ~key:"user_id" ~default:"" in
    if String.trim channel_id = "" || String.trim user_id = ""
    then Error Missing_discord_fields
    else Ok (Discord { channel_id; user_id })
  | Some "slack" ->
    let channel = Json_util.get_string_with_default json ~key:"channel" ~default:"" in
    let user_id = Json_util.get_string_with_default json ~key:"user_id" ~default:"" in
    if String.trim channel = "" || String.trim user_id = ""
    then Error Missing_slack_fields
    else Ok (Slack { channel; user_id })
  | Some kind -> Error (Unsupported_kind kind)
  | None -> Error Missing_kind
;;

let of_yojson json =
  match of_yojson_with_error json with
  | Ok connector -> Ok connector
  | Error err -> Error (decode_error_to_string err)
;;
