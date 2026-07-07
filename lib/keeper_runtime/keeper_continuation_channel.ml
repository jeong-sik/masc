type t =
  | Dashboard of { thread_id : string }
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }
  | Unrouted of { reason : string }

let unrouted reason = Unrouted { reason }

let is_routable = function
  | Unrouted _ -> false
  | Dashboard _ | Discord _ | Slack _ -> true

let kind_label = function
  | Dashboard _ -> "dashboard"
  | Discord _ -> "discord"
  | Slack _ -> "slack"
  | Unrouted _ -> "unrouted"

let describe = function
  | Dashboard { thread_id } -> Printf.sprintf "dashboard thread=%s" thread_id
  | Discord { channel_id; user_id } ->
    Printf.sprintf "discord channel=%s user=%s" channel_id user_id
  | Slack { channel; user_id } -> Printf.sprintf "slack channel=%s user=%s" channel user_id
  | Unrouted { reason } -> Printf.sprintf "unrouted (%s)" reason

let same_route a b =
  match a, b with
  | Dashboard x, Dashboard y -> String.equal x.thread_id y.thread_id
  | Discord x, Discord y ->
    String.equal x.channel_id y.channel_id && String.equal x.user_id y.user_id
  | Slack x, Slack y ->
    String.equal x.channel y.channel && String.equal x.user_id y.user_id
  | Unrouted _, Unrouted _ -> false
  (* Distinct-constructor pairs share no route. Listing the constructors
     explicitly (not [_]) keeps this exhaustive: a new variant forces a
     compile error here rather than silently defaulting to [false]. *)
  | (Dashboard _ | Discord _ | Slack _ | Unrouted _), (Dashboard _ | Discord _ | Slack _ | Unrouted _)
    -> false

let to_yojson = function
  | Dashboard { thread_id } ->
    `Assoc [ ("kind", `String "dashboard"); ("thread_id", `String thread_id) ]
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
  | Unrouted { reason } ->
    `Assoc [ ("kind", `String "unrouted"); ("reason", `String reason) ]

let ( let* ) = Result.bind

let assoc_fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error "continuation_channel must be a JSON object"

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "continuation_channel: field %s must be a string" name)
  | None -> Error (Printf.sprintf "continuation_channel: missing field %s" name)

let of_yojson json =
  let* fields = assoc_fields json in
  let* kind = string_field "kind" fields in
  match kind with
  | "dashboard" ->
    let* thread_id = string_field "thread_id" fields in
    Ok (Dashboard { thread_id })
  | "discord" ->
    let* channel_id = string_field "channel_id" fields in
    let* user_id = string_field "user_id" fields in
    Ok (Discord { channel_id; user_id })
  | "slack" ->
    let* channel = string_field "channel" fields in
    let* user_id = string_field "user_id" fields in
    Ok (Slack { channel; user_id })
  | "unrouted" ->
    let* reason = string_field "reason" fields in
    Ok (Unrouted { reason })
  | other -> Error (Printf.sprintf "continuation_channel: unknown kind: %s" other)
