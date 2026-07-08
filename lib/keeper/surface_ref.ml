(* See the interface.  The type and JSON codec are moved verbatim from
   Keeper_external_attention (RFC-0232 §3.6); [Agent] and [lane_label]
   are the additions that let the chat lane drop its open [source]
   strings. *)

type t =
  | Dashboard of { session_id : string option }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
    }
  | Github of { repo : string; notification_id : string option }
  | Webhook of { source : string; event_id : string }
  | Agent
  | Gate of { label : string; address : (string * string) list }

let equal (a : t) (b : t) = a = b
let compare (a : t) (b : t) = Stdlib.compare a b

let lane_label = function
  | Dashboard _ -> "dashboard"
  | Discord _ -> "discord"
  | Slack _ -> "slack"
  | Github _ -> "github"
  | Webhook _ -> "webhook"
  | Agent -> "agent"
  | Gate { label; _ } -> label

(* ── JSON codec ── *)

let opt_string_field key = function
  | None -> []
  | Some value -> [ (key, `String value) ]

let string_assoc_json fields =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) fields)

let string_assoc_of_json = function
  | `Assoc fields ->
      Ok
        (List.filter_map
           (fun (key, value) ->
             match value with
             | `String s -> Some (key, s)
             | _ -> None)
           fields)
  | _ -> Error "expected string object"

let required_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | _ -> Error (Printf.sprintf "missing string field %s" key))
  | _ -> Error "expected object"

let optional_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | Some (`String _) | Some `Null | None -> None
      | Some _ -> None)
  | _ -> None

let optional_object key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc _ as obj) -> Some obj
      | Some `Null | None -> None
      | Some _ -> None)
  | _ -> None

let ( let* ) = Result.bind

let to_json = function
  | Dashboard { session_id } ->
      `Assoc
        ([ ("kind", `String "dashboard") ]
        @ opt_string_field "session_id" session_id)
  | Discord { guild_id; channel_id; parent_channel_id; thread_id } ->
      `Assoc
        ([ ("kind", `String "discord"); ("channel_id", `String channel_id) ]
        @ opt_string_field "guild_id" guild_id
        @ opt_string_field "parent_channel_id" parent_channel_id
        @ opt_string_field "thread_id" thread_id)
  | Slack { team_id; channel_id; thread_ts } ->
      `Assoc
        ([ ("kind", `String "slack"); ("channel_id", `String channel_id) ]
        @ opt_string_field "team_id" team_id
        @ opt_string_field "thread_ts" thread_ts)
  | Github { repo; notification_id } ->
      `Assoc
        ([ ("kind", `String "github"); ("repo", `String repo) ]
        @ opt_string_field "notification_id" notification_id)
  | Webhook { source; event_id } ->
      `Assoc
        [
          ("kind", `String "webhook");
          ("source", `String source);
          ("event_id", `String event_id);
        ]
  | Agent -> `Assoc [ ("kind", `String "agent") ]
  | Gate { label; address } ->
      `Assoc
        [
          ("kind", `String "gate");
          ("label", `String label);
          ("address", string_assoc_json address);
        ]

let of_json json =
  let* kind = required_string "kind" json in
  match kind with
  | "dashboard" ->
      Ok (Dashboard { session_id = optional_string "session_id" json })
  | "discord" ->
      let* channel_id = required_string "channel_id" json in
      Ok
        (Discord
           {
             guild_id = optional_string "guild_id" json;
             channel_id;
             parent_channel_id = optional_string "parent_channel_id" json;
             thread_id = optional_string "thread_id" json;
           })
  | "slack" ->
      let* channel_id = required_string "channel_id" json in
      Ok
        (Slack
           {
             team_id = optional_string "team_id" json;
             channel_id;
             thread_ts = optional_string "thread_ts" json;
           })
  | "github" ->
      let* repo = required_string "repo" json in
      Ok
        (Github { repo; notification_id = optional_string "notification_id" json })
  | "webhook" ->
      let* source = required_string "source" json in
      let* event_id = required_string "event_id" json in
      Ok (Webhook { source; event_id })
  | "agent" -> Ok Agent
  | "gate" ->
      let* label = required_string "label" json in
      let address =
        match optional_object "address" json with
        | None -> Ok []
        | Some obj -> string_assoc_of_json obj
      in
      let* address = address in
      Ok (Gate { label; address })
  | other -> Error (Printf.sprintf "unknown surface kind %s" other)

let to_continuation_channel = function
  | Dashboard { session_id } ->
    Keeper_continuation_channel.Dashboard { thread_id = Option.value ~default:"" session_id }
  | Discord { guild_id; channel_id; parent_channel_id; thread_id } ->
    Keeper_continuation_channel.Discord
      { guild_id; channel_id; parent_channel_id; thread_id; user_id = "" }
  | Slack { team_id; channel_id; thread_ts } ->
    Keeper_continuation_channel.Slack { team_id; channel_id; thread_ts; user_id = "" }
  | Github { repo = _; notification_id = _ } ->
    Keeper_continuation_channel.Unrouted
      { reason = "GitHub notifications do not support continuation wake" }
  | Webhook { source; event_id = _ } ->
    Keeper_continuation_channel.Unrouted
      { reason = Printf.sprintf "webhook source %s does not support continuation wake" source }
  | Agent ->
    Keeper_continuation_channel.Unrouted
      { reason = "agent-initiated lane has no external surface" }
  | Gate { label; address = _ } ->
    Keeper_continuation_channel.Unrouted
      { reason = Printf.sprintf "gate channel %s does not support continuation wake" label }
