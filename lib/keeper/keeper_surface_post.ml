type post_target =
  | To_dashboard
  | To_discord of { channel_id : string }

let dashboard_label = "dashboard"
let discord_label = "discord"

let resolve_target ~surface ~channel_id ~bound_discord_channels :
    (post_target, string) result =
  let surface = String.trim surface in
  if String.equal surface dashboard_label then Ok To_dashboard
  else if String.equal surface discord_label then
    let bound = List.map String.trim bound_discord_channels in
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
        if List.exists (String.equal requested) bound then
          Ok (To_discord { channel_id = requested })
        else
          Error
            (Printf.sprintf
               "channel_id %s is not bound to this keeper (bound: %s)"
               requested
               (String.concat ", " bound))
  else
    Error
      (Printf.sprintf
         "posting to %S is not supported: discord and dashboard only in this \
          phase (generic gate connectors have no send surface yet)"
         surface)

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
