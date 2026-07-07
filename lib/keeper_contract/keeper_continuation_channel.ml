(** Keeper continuation-channel provenance. *)

type t =
  | Routed of Keeper_chat_connector.t
  | Unrouted of { reason : string }

let routed connector = Routed connector

let unrouted reason =
  let reason = String.trim reason in
  let reason =
    if String.equal reason "" then "continuation channel unavailable" else reason
  in
  Unrouted { reason }
;;

let to_yojson = function
  | Routed connector -> Keeper_chat_connector.to_yojson connector
  | Unrouted { reason } ->
    `Assoc [ ("kind", `String "unrouted"); ("reason", `String reason) ]
;;

let of_yojson json =
  match Json_util.get_string json "kind" with
  | Some "unrouted" ->
    let reason = Json_util.get_string_with_default json ~key:"reason" ~default:"" in
    Ok (unrouted reason)
  | Some "dashboard" | Some "discord" | Some "slack" ->
    (match Keeper_chat_connector.of_yojson json with
     | Ok connector -> Ok (Routed connector)
     | Error err -> Error err)
  | Some kind ->
    Ok (unrouted (Printf.sprintf "unsupported continuation channel kind: %s" kind))
  | None -> Error "continuation channel requires kind"
;;

let to_string = function
  | Routed Keeper_chat_connector.Dashboard -> "dashboard"
  | Routed (Keeper_chat_connector.Discord { channel_id; user_id }) ->
    Printf.sprintf "discord:%s:%s" channel_id user_id
  | Routed (Keeper_chat_connector.Slack { channel; user_id }) ->
    Printf.sprintf "slack:%s:%s" channel user_id
  | Unrouted { reason } -> "unrouted:" ^ reason
;;

