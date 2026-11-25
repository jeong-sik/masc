open Masc_tui_core

open Json_decode_fields

let ( let* ) = Result.bind

type origin = {
  guild_id : string option;
  channel_id : string;
  original_message_id : string;
}

type target = { keeper : string; chat_id : string; origin : origin }

type refusal = Binding_changed | Discord_unconfigured | Discord_rejected
type state = Sending | Delivered of string | Refused of refusal | Outcome_unknown

type request =
  | Send of { target : target; operation_id : string; content : string }
  | Status of { target : target; operation_id : string }

let snowflake id =
  String.length id > 0 && id.[0] <> '0' && String.for_all Char.Ascii.is_digit id

let decode_origin ~message ~surface =
  let parsed =
    let* authority = required_string_field message "speaker_authority" in
    let* channel_id = required_string_field surface "channel_id" in
    let* original_message_id = required_string_field message "external_message_id" in
    let* guild_id = optional_string_field surface "guild_id" in
    let* parent = optional_string_field surface "parent_channel_id" in
    let* thread = optional_string_field surface "thread_id" in
    let valid_thread =
      match parent with
      | None -> Option.is_none thread
      | Some p -> snowflake p && p <> channel_id && thread = Some channel_id
    in
    if authority = "external" && snowflake channel_id && snowflake original_message_id
       && Option.for_all snowflake guild_id && valid_thread
    then Ok { guild_id; channel_id; original_message_id }
    else Error "invalid recorded Discord origin"
  in
  Result.to_option parsed

let equal_target (a : target) b =
  a.keeper = b.keeper && a.chat_id = b.chat_id && a.origin = b.origin

let path = function
  | Send _ -> "/api/v1/keepers/discord/reply"
  | Status _ -> "/api/v1/keepers/discord/reply/status"

let identity = function
  | Send { target; operation_id; _ } | Status { target; operation_id } ->
      (target, operation_id)

let encode ~workspace request =
  let target, operation_id = identity request in
  let fields =
    [ "expected_workspace", Wire_work.encode_expected_workspace workspace
    ; "operation_id", `String operation_id ]
  in
  `Assoc
    (match request with
     | Status _ -> fields
     | Send { content; _ } ->
         fields @
         [ "keeper_name", `String target.keeper; "chat_id", `String target.chat_id
         ; "content", `String content ])

let decode request json =
  let target, operation_id = identity request in
  let expect field value =
    let* actual = required_string_field json field in
    if actual = value then Ok ()
    else Error (Printf.sprintf "Discord receipt %s differs from request" field)
  in
  let* () = expect "operation_id" operation_id in
  let* () = expect "keeper_name" target.keeper in
  let* () = expect "chat_id" target.chat_id in
  let* () = expect "channel_id" target.origin.channel_id in
  let* () = expect "original_message_id" target.origin.original_message_id in
  let* state = required_string_field json "state" in
  match state with
  | "sending" -> Ok Sending
  | "outcome_unknown" -> Ok Outcome_unknown
  | "delivered" ->
      let* id = required_string_field json "message_id" in
      if snowflake id then Ok (Delivered id) else Error "invalid delivered Discord message ID"
  | "refused" ->
      let* reason = required_string_field json "reason" in
      (match reason with
       | "binding_changed" -> Ok (Refused Binding_changed)
       | "discord_unconfigured" -> Ok (Refused Discord_unconfigured)
       | "discord_rejected" -> Ok (Refused Discord_rejected)
       | _ -> Error "unknown Discord reply refusal")
  | _ -> Error "unknown Discord reply state"
