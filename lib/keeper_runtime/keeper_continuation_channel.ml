type t =
  | Dashboard of { thread_id : string }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
      user_id : string;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
      user_id : string;
    }
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
  | Discord { guild_id; channel_id; parent_channel_id; thread_id; user_id } ->
    let opt label = function
      | None -> ""
      | Some value -> Printf.sprintf " %s=%s" label value
    in
    Printf.sprintf "discord%s channel=%s%s%s user=%s"
      (opt "guild" guild_id)
      channel_id
      (opt "parent_channel" parent_channel_id)
      (opt "thread" thread_id)
      user_id
  | Slack { team_id; channel_id; thread_ts; user_id } ->
    let opt label = function
      | None -> ""
      | Some value -> Printf.sprintf " %s=%s" label value
    in
    Printf.sprintf "slack%s channel=%s%s user=%s"
      (opt "team" team_id)
      channel_id
      (opt "thread_ts" thread_ts)
      user_id
  | Unrouted { reason } -> Printf.sprintf "unrouted (%s)" reason

let same_route a b =
  match a, b with
  | Dashboard x, Dashboard y -> String.equal x.thread_id y.thread_id
  | Discord x, Discord y -> x = y
  | Slack x, Slack y -> x = y
  | Unrouted _, Unrouted _ -> false
  (* Distinct-constructor pairs share no route. Listing the constructors
     explicitly (not [_]) keeps this exhaustive: a new variant forces a
     compile error here rather than silently defaulting to [false]. *)
  | (Dashboard _ | Discord _ | Slack _ | Unrouted _), (Dashboard _ | Discord _ | Slack _ | Unrouted _)
    -> false

let option_string_fields fields =
  List.filter_map
    (fun (name, value) -> Option.map (fun value -> name, `String value) value)
    fields

let to_yojson = function
  | Dashboard { thread_id } ->
    `Assoc [ ("kind", `String "dashboard"); ("thread_id", `String thread_id) ]
  | Discord { guild_id; channel_id; parent_channel_id; thread_id; user_id } ->
    `Assoc
      ([ ("kind", `String "discord")
       ; ("channel_id", `String channel_id)
       ; ("user_id", `String user_id)
       ]
       @ option_string_fields
           [ ("guild_id", guild_id)
           ; ("parent_channel_id", parent_channel_id)
           ; ("thread_id", thread_id)
           ])
  | Slack { team_id; channel_id; thread_ts; user_id } ->
    `Assoc
      ([ ("kind", `String "slack")
       ; ("channel_id", `String channel_id)
       ; ("user_id", `String user_id)
       ]
       @ option_string_fields [ ("team_id", team_id); ("thread_ts", thread_ts) ])
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

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) when String.trim s <> "" -> Some s
  | Some (`String _) | Some `Null | None -> None
  | Some _ -> None

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
    Ok
      (Discord
         { guild_id = optional_string_field "guild_id" fields
         ; channel_id
         ; parent_channel_id = optional_string_field "parent_channel_id" fields
         ; thread_id = optional_string_field "thread_id" fields
         ; user_id
         })
  | "slack" ->
    let* channel_id =
      match string_field "channel_id" fields with
      | Ok value -> Ok value
      | Error _ -> string_field "channel" fields
    in
    let* user_id = string_field "user_id" fields in
    Ok
      (Slack
         { team_id = optional_string_field "team_id" fields
         ; channel_id
         ; thread_ts = optional_string_field "thread_ts" fields
         ; user_id
         })
  | "unrouted" ->
    let* reason = string_field "reason" fields in
    Ok (Unrouted { reason })
  | other -> Error (Printf.sprintf "continuation_channel: unknown kind: %s" other)
