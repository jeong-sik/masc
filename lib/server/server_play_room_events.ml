type room_scope = Play_room_presence.scope = {
  play_client : string;
  machine : Machine_lane.t;
}

type connection_outcome = Play_room_presence.connection_outcome = Connected | Stale

let connect = Play_room_presence.connect
let renew = Play_room_presence.renew
let disconnect = Play_room_presence.disconnect
let perform_http = Play_room_presence.perform_http

let room_scope_of_request_target target =
  let query = Uri.of_string target in
  let values name =
    Uri.query query
    |> List.filter_map (fun (key, values) ->
      if String.equal key name then Some values else None)
  in
  match values "play_client_id", values "play_machine" with
  | [], [] -> Ok None
  | [ [play_client] ], [ [machine] ] ->
    let machine_target = "/mcp?machine=" ^ Uri.pct_encode machine in
    (match Server_machine_spectator.machine_of_request_target machine_target with
     | Error _ as error -> error
     | Ok None -> Error "play_machine must be msx or dos"
     | Ok (Some machine) ->
       let scope = { play_client; machine } in
       (match Play_room_presence.presence_action Play_room.Join scope with
        | Ok _ -> Ok (Some scope)
        | Error error -> Error (Play_room.error_message error)))
  | [], _ | _, [] -> Error "play_client_id and play_machine must be provided together"
  | _, _ -> Error "play_client_id and play_machine must each appear exactly once"

module For_testing = struct
  let with_permission = Play_room_presence.For_testing.with_permission
  let with_perform = Play_room_presence.For_testing.with_perform
end
