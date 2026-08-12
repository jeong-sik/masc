type rich_block = Yojson.Safe.t

type post_target =
  | To_dashboard
  | To_discord of { channel_id : string }
  | To_slack of
      { channel_id : string
      ; thread_ts : string option
      ; blocks : rich_block list option
      }

let dashboard_label = "dashboard"
let discord_label = "discord"
let slack_label = "slack"

type delivery_target =
  | Delivered_to_dashboard
  | Delivered_to_discord of { channel_id : string }
  | Delivered_to_slack of { channel_id : string; thread_ts : string option }

let delivery_target_of_post_target = function
  | To_dashboard -> Delivered_to_dashboard
  | To_discord { channel_id } -> Delivered_to_discord { channel_id }
  | To_slack { channel_id; thread_ts; blocks = _ } ->
    Delivered_to_slack { channel_id; thread_ts }

let delivery_target_to_yojson = function
  | Delivered_to_dashboard -> `Assoc [ "kind", `String dashboard_label ]
  | Delivered_to_discord { channel_id } ->
    `Assoc [ "kind", `String discord_label; "channel_id", `String channel_id ]
  | Delivered_to_slack { channel_id; thread_ts } ->
    `Assoc
      ([ "kind", `String slack_label; "channel_id", `String channel_id ]
       @ match thread_ts with
         | None -> []
         | Some thread_ts -> [ "thread_ts", `String thread_ts ])

let delivery_target_of_yojson json =
  let field key fields =
    match List.assoc_opt key fields with
    | Some (`String value) when String.trim value <> "" -> Ok value
    | Some _ ->
      Error
        (Printf.sprintf "delivery target %s must be a non-empty string" key)
    | None -> Error (Printf.sprintf "delivery target is missing %s" key)
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) when String.equal kind dashboard_label ->
       Ok Delivered_to_dashboard
     | Some (`String kind) when String.equal kind discord_label ->
       Result.map
         (fun channel_id -> Delivered_to_discord { channel_id })
         (field "channel_id" fields)
     | Some (`String kind) when String.equal kind slack_label ->
       Result.bind (field "channel_id" fields) (fun channel_id ->
           match List.assoc_opt "thread_ts" fields with
           | None -> Ok (Delivered_to_slack { channel_id; thread_ts = None })
           | Some (`String thread_ts) when String.trim thread_ts <> "" ->
             Ok (Delivered_to_slack { channel_id; thread_ts = Some thread_ts })
           | Some _ ->
             Error "delivery target thread_ts must be a non-empty string")
     | Some (`String kind) ->
       Error (Printf.sprintf "unknown delivery target kind %S" kind)
     | Some _ -> Error "delivery target kind must be a string"
     | None -> Error "delivery target is missing kind")
  | _ -> Error "delivery target must be a JSON object"

let delivery_target_wire_key = "external_effect_target"

let resolve_target ~surface ~channel_id ?continuation_channel
    ?(bound_discord_channels = [])
    ?(bound_slack_channels = []) () : (post_target, string) result =
  let surface = String.trim surface in
  let ( continuation_channel_id
      , continuation_parent_channel_id
      , continuation_slack_thread_ts )
    =
    match continuation_channel with
    | Some
        (Keeper_continuation_channel.Discord
           { channel_id; parent_channel_id; thread_id; _ })
      when String.equal surface discord_label ->
      ( Some channel_id
      , (match thread_id, parent_channel_id with
         | Some thread_id, Some parent_channel_id
           when String.equal thread_id channel_id -> Some parent_channel_id
         | _ -> None)
      , None )
    | Some (Keeper_continuation_channel.Slack { channel_id; thread_ts; _ })
      when String.equal surface slack_label ->
      Some channel_id, None, thread_ts
    | Some
        ( Keeper_continuation_channel.Dashboard _
        | Keeper_continuation_channel.Discord _
        | Keeper_continuation_channel.Slack _
        | Keeper_continuation_channel.Unrouted _ )
    | None ->
      None, None, None
  in
  (* A Slack [thread_ts] names a conversation inside one channel, so it only
     travels with a post that lands on the continuation's own channel; an
     explicit different channel gets a root post (a foreign thread_ts would be
     rejected by Slack). *)
  let slack_thread_ts_for ~channel_id =
    match continuation_channel_id with
    | Some continuation_id when String.equal channel_id continuation_id ->
      continuation_slack_thread_ts
    | Some _ | None -> None
  in
  let channel_id =
    match channel_id with
    | Some _ as explicit -> explicit
    | None -> continuation_channel_id
  in
  if String.equal surface dashboard_label then Ok To_dashboard
  else if String.equal surface discord_label then
    let bound = List.map String.trim bound_discord_channels in
    let is_bound_channel requested =
      List.exists (String.equal requested) bound
      ||
      match continuation_channel_id, continuation_parent_channel_id with
      | Some continuation_id, Some parent_id
        when String.equal requested continuation_id ->
        List.exists (String.equal parent_id) bound
      | _ -> false
    in
    match (channel_id, bound) with
    | _, [] ->
        Error
          "this keeper has no Discord channel binding; bind a channel first \
           (posting to an unbound surface is an error, not a no-op)"
    | None, [ only ] -> Ok (To_discord { channel_id = only })
    | None, _ :: _ :: _ ->
        Error
          (Printf.sprintf
             "multiple Discord channels are bound (%s); pass channel_id to \
              pick one"
             (String.concat ", " bound))
    | Some requested, bound ->
        let requested = String.trim requested in
        if is_bound_channel requested then
          Ok (To_discord { channel_id = requested })
        else
          Error
            (Printf.sprintf
               "channel_id %s is not bound to this keeper (bound: %s)"
               requested
               (String.concat ", " bound))
  else if String.equal surface slack_label then
    let bound = List.map String.trim bound_slack_channels in
    match (channel_id, bound) with
    | _, [] ->
        Error
          "this keeper has no Slack channel binding; bind a channel first \
           (posting to an unbound surface is an error, not a no-op)"
    | None, [ only ] ->
        Ok
          (To_slack
             { channel_id = only
             ; thread_ts = slack_thread_ts_for ~channel_id:only
             ; blocks = None
             })
    | None, _ :: _ :: _ ->
        Error
          (Printf.sprintf
             "multiple Slack channels are bound (%s); pass channel_id to \
              pick one"
             (String.concat ", " bound))
    | Some requested, bound ->
        let requested = String.trim requested in
        if List.exists (String.equal requested) bound then
          Ok
            (To_slack
               { channel_id = requested
               ; thread_ts = slack_thread_ts_for ~channel_id:requested
               ; blocks = None
               })
        else
          Error
            (Printf.sprintf
               "channel_id %s is not bound to this keeper (bound: %s)"
               requested
               (String.concat ", " bound))
  else
    Error
      (Printf.sprintf
         "posting to %S is not supported: discord, dashboard, and slack only \
          in this phase (generic gate connectors have no send surface yet)"
         surface)

let set_blocks target blocks_opt =
  match target with
  | To_slack s -> To_slack { s with blocks = blocks_opt }
  | other -> other

let matches_continuation_route target channel =
  match target, channel with
  | ( To_discord { channel_id = posted }
    , Keeper_continuation_channel.Discord { channel_id; _ } ) ->
    (* Discord [channel_id] is the innermost conversation locus — a thread's id
       is its own channel_id (server_discord_in_process_gateway.discord_delivery)
       — and the surface-post tool posts to that channel_id, so a same-channel
       post reaches the continuation's conversation whether or not the inbound
       was a reply. [reply_to_message_id] names the triggering message, not a
       different destination, so it does not gate delivery. Every Discord
       continuation now carries [reply_to_message_id = Some _], so requiring
       [= None] here quarantined all of them (PR #28225 review). *)
    String.equal posted channel_id
  | ( To_slack { channel_id = posted; thread_ts = posted_thread_ts; _ }
    , Keeper_continuation_channel.Slack { channel_id; thread_ts; _ } ) ->
    (* Slack differs from Discord: [thread_ts] is a destination distinct from
       the channel root, so delivery is proven only when the post carried the
       continuation's exact thread coordinate — both unthreaded, or both the
       same thread. A root post never proves delivery for a threaded
       continuation (that still settles through the recovery publisher). *)
    String.equal posted channel_id
    && Option.equal String.equal posted_thread_ts thread_ts
  | ( To_dashboard
    , Keeper_continuation_channel.Dashboard _ ) ->
    (* Dashboard posts are currently keeper-global ([session_id=None]), so
       they cannot prove delivery to one exact continuation thread. *)
    false
  | ( To_dashboard | To_discord _ | To_slack _ )
    , ( Keeper_continuation_channel.Dashboard _
      | Keeper_continuation_channel.Discord _
      | Keeper_continuation_channel.Slack _
      | Keeper_continuation_channel.Unrouted _ ) ->
    false

let ok_json ~surface ?message_id () =
  let fields =
    [ ("status", `String "posted"); ("surface", `String surface) ]
    @ match message_id with
      | Some id -> [ ("message_id", `String id) ]
      | None -> []
  in
  Yojson.Safe.to_string (`Assoc fields)

let error_json message =
  Yojson.Safe.to_string (`Assoc [ ("error", `String message) ])
