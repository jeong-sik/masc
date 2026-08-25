type t =
  | Dashboard of { thread_id : string }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
      reply_to_message_id : string option;
      user_id : string;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
      user_id : string;
    }
  | Keeper of { keeper_name : string }
  | Unrouted of { reason : string }

let ( let* ) = Result.bind

let validate_nonblank field value =
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "continuation_channel: field %s must not be blank" field)
  else Ok value
;;

let validate_optional_nonblank field = function
  | None -> Ok None
  | Some value ->
    let* value = validate_nonblank field value in
    Ok (Some value)
;;

let dashboard ~thread_id =
  let* thread_id = validate_nonblank "thread_id" thread_id in
  Ok (Dashboard { thread_id })
;;

let keeper ~keeper_name =
  let* keeper_name = validate_nonblank "keeper_name" keeper_name in
  Ok (Keeper { keeper_name })
;;

let discord ~guild_id ~channel_id ~parent_channel_id ~thread_id
      ?reply_to_message_id ~user_id () =
  let* guild_id = validate_optional_nonblank "guild_id" guild_id in
  let* channel_id = validate_nonblank "channel_id" channel_id in
  let* parent_channel_id =
    validate_optional_nonblank "parent_channel_id" parent_channel_id
  in
  let* thread_id = validate_optional_nonblank "thread_id" thread_id in
  let* reply_to_message_id =
    validate_optional_nonblank "reply_to_message_id" reply_to_message_id
  in
  let* user_id = validate_nonblank "user_id" user_id in
  Ok
    (Discord
       { guild_id
       ; channel_id
       ; parent_channel_id
       ; thread_id
       ; reply_to_message_id
       ; user_id
       })
;;

let discord_thread_parent t ~parent_channel_id =
  match t with
  | Discord { guild_id; channel_id; reply_to_message_id; user_id; _ } ->
    Discord
      { guild_id
      ; channel_id
      ; parent_channel_id = Some parent_channel_id
      ; thread_id = Some channel_id
      ; reply_to_message_id
      ; user_id
      }
  | Dashboard _ | Slack _ | Keeper _ | Unrouted _ -> t
;;

let slack ~team_id ~channel_id ~thread_ts ~user_id =
  let* team_id = validate_optional_nonblank "team_id" team_id in
  let* channel_id = validate_nonblank "channel_id" channel_id in
  let* thread_ts = validate_optional_nonblank "thread_ts" thread_ts in
  let* user_id = validate_nonblank "user_id" user_id in
  Ok (Slack { team_id; channel_id; thread_ts; user_id })
;;

let unrouted reason =
  match validate_nonblank "reason" reason with
  | Ok reason -> Unrouted { reason }
  | Error message -> invalid_arg message
;;

let is_routable = function
  | Unrouted _ -> false
  | Dashboard _ | Discord _ | Slack _ | Keeper _ -> true

let kind_label = function
  | Dashboard _ -> "dashboard"
  | Discord _ -> "discord"
  | Slack _ -> "slack"
  | Keeper _ -> "keeper"
  | Unrouted _ -> "unrouted"

let describe = function
  | Dashboard { thread_id } -> Printf.sprintf "dashboard thread=%s" thread_id
  | Discord
      { guild_id
      ; channel_id
      ; parent_channel_id
      ; thread_id
      ; reply_to_message_id
      ; user_id
      } ->
    let opt label = function
      | None -> ""
      | Some value -> Printf.sprintf " %s=%s" label value
    in
    Printf.sprintf "discord%s channel=%s%s%s%s user=%s"
      (opt "guild" guild_id)
      channel_id
      (opt "parent_channel" parent_channel_id)
      (opt "thread" thread_id)
      (opt "reply_to_message" reply_to_message_id)
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
  | Keeper { keeper_name } -> Printf.sprintf "keeper name=%s" keeper_name
  | Unrouted { reason } -> Printf.sprintf "unrouted (%s)" reason

let same_string_option = Option.equal String.equal

let same_route a b =
  match a, b with
  | Dashboard { thread_id = left }, Dashboard { thread_id = right } ->
    String.equal left right
  | ( Discord
        { guild_id = left_guild
        ; channel_id = left_channel
        ; parent_channel_id = left_parent
        ; thread_id = left_thread
        ; reply_to_message_id = left_reply
        ; user_id = left_user
        }
    , Discord
        { guild_id = right_guild
        ; channel_id = right_channel
        ; parent_channel_id = right_parent
        ; thread_id = right_thread
        ; reply_to_message_id = right_reply
        ; user_id = right_user
        } ) ->
    same_string_option left_guild right_guild
    && String.equal left_channel right_channel
    && same_string_option left_parent right_parent
    && same_string_option left_thread right_thread
    && same_string_option left_reply right_reply
    && String.equal left_user right_user
  | ( Slack
        { team_id = left_team
        ; channel_id = left_channel
        ; thread_ts = left_thread
        ; user_id = left_user
        }
    , Slack
        { team_id = right_team
        ; channel_id = right_channel
        ; thread_ts = right_thread
        ; user_id = right_user
        } ) ->
    same_string_option left_team right_team
    && String.equal left_channel right_channel
    && same_string_option left_thread right_thread
    && String.equal left_user right_user
  | Keeper { keeper_name = left }, Keeper { keeper_name = right } ->
    String.equal left right
  | Unrouted _, Unrouted _ -> false
  (* Distinct-constructor pairs share no route. Listing the constructors
     explicitly (not [_]) keeps this exhaustive: a new variant forces a
     compile error here rather than silently defaulting to [false]. *)
  | ( (Dashboard _ | Discord _ | Slack _ | Keeper _ | Unrouted _)
    , (Dashboard _ | Discord _ | Slack _ | Keeper _ | Unrouted _) )
    -> false

(* RFC-0377: batching pending Connector_attention stimuli needs "is this the
   same conversation", which is deliberately looser than [same_route].
   [reply_to_message_id] (Discord) is stamped with the inbound message's own
   id at enqueue time (server_discord_in_process_gateway.handle_ambient), so
   every ambient message gets a distinct value there — comparing it would
   make two pending messages from the same channel never coalesce, which
   defeats the batch this predicate exists to build. [thread_ts] (Slack) has
   the same per-message shape at the ambient producer. [channel_id] alone is
   already the exact conversation coordinate, for both connectors:
   - Discord channel ids are Discord-global-unique snowflakes (never reused
     across guilds), so comparing [guild_id] too would be redundant, not
     more precise — [channel_id] alone is compared here. The Discord
     producer additionally sets [thread_id = Some channel_id] when
     [channel_id] is itself a tracked thread, so [channel_id] alone already
     disambiguates thread vs. parent channel too.
   - An existing comment on [slack_conversation_id] establishes the same for
     Slack ("threads share the parent channel id, so the conversation id is
     keyed on the channel alone").
   [user_id] is the message's author, not the conversation's location, so
   two different users posting into the same channel still share one
   conversation coordinate — the Keeper decides per RFC-0377 §3 whether to
   answer each individually. *)
let same_conversation a b =
  match a, b with
  | Dashboard { thread_id = left }, Dashboard { thread_id = right } ->
    String.equal left right
  | ( Discord { channel_id = left_channel; _ }
    , Discord { channel_id = right_channel; _ } ) ->
    String.equal left_channel right_channel
  | ( Slack { channel_id = left_channel; _ }
    , Slack { channel_id = right_channel; _ } ) ->
    String.equal left_channel right_channel
  | Keeper { keeper_name = left }, Keeper { keeper_name = right } ->
    String.equal left right
  | Unrouted _, Unrouted _ -> false
  (* Distinct-constructor pairs share no conversation. Listing the
     constructors explicitly (not [_]) keeps this exhaustive: a new
     connector forces a compile error here rather than silently
     defaulting to [false]. *)
  | ( (Dashboard _ | Discord _ | Slack _ | Keeper _ | Unrouted _)
    , (Dashboard _ | Discord _ | Slack _ | Keeper _ | Unrouted _) )
    -> false

let option_string_fields fields =
  List.filter_map
    (fun (name, value) -> Option.map (fun value -> name, `String value) value)
    fields

let to_yojson = function
  | Dashboard { thread_id } ->
    `Assoc [ ("kind", `String "dashboard"); ("thread_id", `String thread_id) ]
  | Discord
      { guild_id
      ; channel_id
      ; parent_channel_id
      ; thread_id
      ; reply_to_message_id
      ; user_id
      } ->
    `Assoc
      ([ ("kind", `String "discord")
       ; ("channel_id", `String channel_id)
       ; ("user_id", `String user_id)
       ]
       @ option_string_fields
           [ ("guild_id", guild_id)
           ; ("parent_channel_id", parent_channel_id)
           ; ("thread_id", thread_id)
           ; ("reply_to_message_id", reply_to_message_id)
           ])
  | Slack { team_id; channel_id; thread_ts; user_id } ->
    `Assoc
      ([ ("kind", `String "slack")
       ; ("channel_id", `String channel_id)
       ; ("user_id", `String user_id)
       ]
       @ option_string_fields [ ("team_id", team_id); ("thread_ts", thread_ts) ])
  | Keeper { keeper_name } ->
    `Assoc [ ("kind", `String "keeper"); ("keeper_name", `String keeper_name) ]
  | Unrouted { reason } ->
    `Assoc [ ("kind", `String "unrouted"); ("reason", `String reason) ]

let assoc_fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error "continuation_channel must be a JSON object"

let validate_unique_fields fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
      if List.mem name seen
      then Error (Printf.sprintf "continuation_channel: duplicate field %s" name)
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let validate_allowed_fields ~kind allowed fields =
  match List.find_opt (fun (name, _) -> not (List.mem name allowed)) fields with
  | None -> Ok ()
  | Some (name, _) ->
    Error
      (Printf.sprintf
         "continuation_channel: field %s is not allowed for kind %s"
         name
         kind)
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) when not (String.equal (String.trim s) "") -> Ok s
  | Some (`String _) ->
    Error (Printf.sprintf "continuation_channel: field %s must not be blank" name)
  | Some _ -> Error (Printf.sprintf "continuation_channel: field %s must be a string" name)
  | None -> Error (Printf.sprintf "continuation_channel: missing field %s" name)

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) when not (String.equal (String.trim s) "") -> Ok (Some s)
  | Some (`String _) ->
    Error (Printf.sprintf "continuation_channel: field %s must not be blank" name)
  | Some `Null | None -> Ok None
  | Some _ ->
    Error (Printf.sprintf "continuation_channel: field %s must be a string or null" name)

let of_yojson json =
  let* fields = assoc_fields json in
  let* () = validate_unique_fields fields in
  let* kind = string_field "kind" fields in
  match kind with
  | "dashboard" ->
    let* () = validate_allowed_fields ~kind [ "kind"; "thread_id" ] fields in
    let* thread_id = string_field "thread_id" fields in
    dashboard ~thread_id
  | "discord" ->
    let* () =
      validate_allowed_fields
        ~kind
        [ "kind"
        ; "guild_id"
        ; "channel_id"
        ; "parent_channel_id"
        ; "thread_id"
        ; "reply_to_message_id"
        ; "user_id"
        ]
        fields
    in
    let* channel_id = string_field "channel_id" fields in
    let* user_id = string_field "user_id" fields in
    let* guild_id = optional_string_field "guild_id" fields in
    let* parent_channel_id = optional_string_field "parent_channel_id" fields in
    let* thread_id = optional_string_field "thread_id" fields in
    let* reply_to_message_id =
      optional_string_field "reply_to_message_id" fields
    in
    discord
      ~guild_id
      ~channel_id
      ~parent_channel_id
      ~thread_id
      ?reply_to_message_id
      ~user_id
      ()
  | "slack" ->
    let* () =
      validate_allowed_fields
        ~kind
        [ "kind"; "team_id"; "channel_id"; "thread_ts"; "user_id" ]
        fields
    in
    let* channel_id = string_field "channel_id" fields in
    let* user_id = string_field "user_id" fields in
    let* team_id = optional_string_field "team_id" fields in
    let* thread_ts = optional_string_field "thread_ts" fields in
    slack ~team_id ~channel_id ~thread_ts ~user_id
  | "keeper" ->
    let* () = validate_allowed_fields ~kind [ "kind"; "keeper_name" ] fields in
    let* keeper_name = string_field "keeper_name" fields in
    keeper ~keeper_name
  | "unrouted" ->
    let* () = validate_allowed_fields ~kind [ "kind"; "reason" ] fields in
    let* reason = string_field "reason" fields in
    Ok (unrouted reason)
  | other -> Error (Printf.sprintf "continuation_channel: unknown kind: %s" other)
