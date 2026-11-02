(* See the interface.  The type and JSON codec are moved verbatim from
   Keeper_external_attention (RFC-0232 §3.6); [Agent] and [lane_label]
   are the additions that let the chat lane drop its open [source]
   strings. *)

type t =
  | Dashboard of { session_id : string option }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      channel_name : string option;
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      channel_name : string option;
          (** What the room is called, where the workspace let us ask. The id
              is the identity and stays; the name is for the reader, who has
              no way to tell [C09TK9L4DV4] from [C09TK9L4DV5]. *)
      thread_ts : string option;
    }
  | Webhook of { source : string; event_id : string }
  | Agent
  | Broadcast
  | Gate of { label : string; address : (string * string) list }

let equal (a : t) (b : t) = a = b

let compare_string_pair (k1, v1) (k2, v2) =
  let c = String.compare k1 k2 in
  if c <> 0 then c else String.compare v1 v2

let surface_rank = function
  | Dashboard _ -> 0
  | Discord _ -> 1
  | Slack _ -> 2
  | Webhook _ -> 3
  | Agent -> 4
  | Broadcast -> 5
  | Gate _ -> 6

let compare (a : t) (b : t) =
  match a, b with
  | Dashboard { session_id = a }, Dashboard { session_id = b } ->
    Option.compare String.compare a b
  | Discord a, Discord b ->
    let c = Option.compare String.compare a.guild_id b.guild_id in
    if c <> 0 then c
    else
      let c = String.compare a.channel_id b.channel_id in
      if c <> 0 then c
      else
        let c = Option.compare String.compare a.channel_name b.channel_name in
        if c <> 0 then c
        else
          let c = Option.compare String.compare a.parent_channel_id b.parent_channel_id in
          if c <> 0 then c
          else Option.compare String.compare a.thread_id b.thread_id
  | Slack a, Slack b ->
    let c = Option.compare String.compare a.team_id b.team_id in
    if c <> 0 then c
    else
      let c = String.compare a.channel_id b.channel_id in
      if c <> 0 then c
      else
        let c = Option.compare String.compare a.channel_name b.channel_name in
        if c <> 0 then c
        else Option.compare String.compare a.thread_ts b.thread_ts
  | Webhook a, Webhook b ->
    let c = String.compare a.source b.source in
    if c <> 0 then c else String.compare a.event_id b.event_id
  | Agent, Agent | Broadcast, Broadcast -> 0
  | Gate a, Gate b ->
    let c = String.compare a.label b.label in
    if c <> 0 then c else List.compare compare_string_pair a.address b.address
  | (Dashboard _ | Discord _ | Slack _ | Webhook _ | Agent | Broadcast | Gate _),
    (Dashboard _ | Discord _ | Slack _ | Webhook _ | Agent | Broadcast | Gate _) ->
    Int.compare (surface_rank a) (surface_rank b)

let lane_label = function
  | Dashboard _ -> "dashboard"
  | Discord _ -> "discord"
  | Slack _ -> "slack"
  | Webhook _ -> "webhook"
  | Agent -> "agent"
  | Broadcast -> "broadcast"
  | Gate { label; _ } -> label

(* ── JSON codec ── *)

open Result.Syntax

let to_json = function
  | Dashboard { session_id } ->
      `Assoc
        ([ ("kind", `String "dashboard") ]
        @ Json_util.string_field_if_present "session_id" session_id)
  | Discord { guild_id; channel_id; channel_name; parent_channel_id; thread_id }
    ->
      `Assoc
        ([ ("kind", `String "discord"); ("channel_id", `String channel_id) ]
        @ Json_util.string_field_if_present "channel_name" channel_name
        @ Json_util.string_field_if_present "guild_id" guild_id
        @ Json_util.string_field_if_present "parent_channel_id" parent_channel_id
        @ Json_util.string_field_if_present "thread_id" thread_id)
  | Slack { team_id; channel_id; channel_name; thread_ts } ->
      `Assoc
        ([ ("kind", `String "slack"); ("channel_id", `String channel_id) ]
        @ Json_util.string_field_if_present "channel_name" channel_name
        @ Json_util.string_field_if_present "team_id" team_id
        @ Json_util.string_field_if_present "thread_ts" thread_ts)
  | Webhook { source; event_id } ->
      `Assoc
        [
          ("kind", `String "webhook");
          ("source", `String source);
          ("event_id", `String event_id);
        ]
  | Agent -> `Assoc [ ("kind", `String "agent") ]
  | Broadcast -> `Assoc [ ("kind", `String "broadcast") ]
  | Gate { label; address } ->
      `Assoc
        [
          ("kind", `String "gate");
          ("label", `String label);
          ("address", Json_util.string_assoc_to_json address);
        ]

let of_json json =
  let* kind = Json_util.require_string json "kind" in
  match kind with
  | "dashboard" ->
      Ok (Dashboard { session_id = Json_util.assoc_string_opt "session_id" json })
  | "discord" ->
      let* channel_id = Json_util.require_string json "channel_id" in
      Ok
        (Discord
           {
             guild_id = Json_util.assoc_string_opt "guild_id" json;
             channel_id;
             channel_name = Json_util.assoc_string_opt "channel_name" json;
             parent_channel_id = Json_util.assoc_string_opt "parent_channel_id" json;
             thread_id = Json_util.assoc_string_opt "thread_id" json;
           })
  | "slack" ->
      let* channel_id = Json_util.require_string json "channel_id" in
      Ok
        (Slack
           {
             team_id = Json_util.assoc_string_opt "team_id" json;
             channel_id;
             channel_name = Json_util.assoc_string_opt "channel_name" json;
             thread_ts = Json_util.assoc_string_opt "thread_ts" json;
           })
  | "webhook" ->
      let* source = Json_util.require_string json "source" in
      let* event_id = Json_util.require_string json "event_id" in
      Ok (Webhook { source; event_id })
  | "agent" -> Ok Agent
  | "broadcast" -> Ok Broadcast
  | "gate" ->
      let* label = Json_util.require_string json "label" in
      let address =
        match Json_util.assoc_object_opt "address" json with
        | None -> Ok []
        | Some obj -> Json_util.string_assoc_of_json obj
      in
      let* address = address in
      Ok (Gate { label; address })
  | other -> Error (Printf.sprintf "unknown surface kind %s" other)
