open Result.Syntax

type room_scope = {
  play_client : string;
  machine : Machine_lane.t;
}

type lease = {
  sse_client_id : int;
  machine : Machine_lane.t;
}

let leases : (string * string * string, lease) Hashtbl.t = Hashtbl.create 31
let lease_mutex = Eio.Mutex.create ()
let permission = ref Masc_domain.has_permission
let perform = ref Play_room.perform_with_change

let key ~base_path ~agent_name ~play_client = base_path, agent_name, play_client

let permitted role =
  if !permission role Masc_domain.CanPlayMachine then Ok ()
  else Error (Play_room.Invalid_request "play room presence is not permitted")

let speaker_of_role = function
  | Masc_domain.Worker | Masc_domain.Admin -> Play_room.Keeper
  | Masc_domain.Player -> Play_room.Participant

let machine_name = function
  | Machine_lane.Msx -> "msx"
  | Machine_lane.Dos -> "dos"

let presence_action operation (scope : room_scope) =
  let action = match operation with Play_room.Join -> "join" | Play_room.Leave -> "leave" in
  Play_room.parse_action (`Assoc [
    "action", `String action;
    "client_id", `String scope.play_client;
    "machine", `String (machine_name scope.machine);
  ])

let with_lease_lock fn = Eio.Mutex.use_rw ~protect:true lease_mutex fn

let announce_change ~base_path = function
  | Some (change : Play_room.change)
    when change.message_committed || change.membership_changed ->
    Workspace_dataset_event.announce ~base_path
      (Workspace_dataset_event.Play_room { machine = change.machine })
  | Some _ | None -> ()

let perform_action ~base_path ~agent_name ~speaker action =
  !perform ~base_path ~who:agent_name ~speaker ~now:(Time_compat.now ()) action
  |> Result.map (fun (snapshot, change) -> snapshot, Some change)

let current_snapshot ~base_path =
  Play_room.read ~base_path ~now:(Time_compat.now ()) ~before:None
  |> Result.map (fun snapshot -> snapshot, None)

let finish_http ~base_path result =
  Result.map (fun (snapshot, change) ->
    announce_change ~base_path change;
    snapshot) result

let connect ~base_path ~agent_name ~role ~scope ~sse_client_id =
  let* () = permitted role in
  let* action = presence_action Play_room.Join scope in
  let speaker = speaker_of_role role in
  let key = key ~base_path ~agent_name ~play_client:scope.play_client in
  with_lease_lock (fun () ->
    match Hashtbl.find_opt leases key with
    | Some current when current.sse_client_id > sse_client_id -> Ok None
    | Some _ | None ->
      match perform_action ~base_path ~agent_name ~speaker action with
      | Error _ as error -> error
      | Ok (_, change) ->
        Hashtbl.replace leases key { sse_client_id; machine = scope.machine };
        Ok change)
  |> Result.map (fun change ->
    announce_change ~base_path change;
    ())

let renew ~base_path ~agent_name ~role ~scope ~sse_client_id =
  let* () = permitted role in
  let speaker = speaker_of_role role in
  let key = key ~base_path ~agent_name ~play_client:scope.play_client in
  with_lease_lock (fun () ->
    match Hashtbl.find_opt leases key with
    | Some current when current.sse_client_id = sse_client_id ->
      (match presence_action Play_room.Join { scope with machine = current.machine } with
       | Error _ as error -> error
       | Ok action ->
         (match perform_action ~base_path ~agent_name ~speaker action with
          | Error _ as error -> error
          | Ok (_, change) -> Ok change))
    | Some _ | None -> Ok None)
  |> Result.map (fun change ->
    announce_change ~base_path change;
    ())

let disconnect ~base_path ~agent_name ~role ~scope ~sse_client_id =
  let* () = permitted role in
  let speaker = speaker_of_role role in
  let key = key ~base_path ~agent_name ~play_client:scope.play_client in
  Eio.Cancel.protect (fun () ->
    with_lease_lock (fun () ->
      match Hashtbl.find_opt leases key with
      | Some current when current.sse_client_id = sse_client_id ->
        Hashtbl.remove leases key;
        (match presence_action Play_room.Leave { scope with machine = current.machine } with
         | Error _ as error -> error
         | Ok action ->
           (match perform_action ~base_path ~agent_name ~speaker action with
            | Error _ as error -> error
            | Ok (_, change) -> Ok change))
      | Some _ | None -> Ok None)
    |> Result.map (fun change ->
      announce_change ~base_path change;
      ()))

let guarded_http ~base_path ~agent_name ~play_client operation action =
  let key = key ~base_path ~agent_name ~play_client in
  with_lease_lock (fun () ->
    match Hashtbl.find_opt leases key with
    | Some _ -> current_snapshot ~base_path
    | None ->
      (match operation with
       | Play_room.Join | Play_room.Leave ->
         perform_action ~base_path ~agent_name ~speaker:Play_room.Participant action))

let perform_http ~base_path ~agent_name ~role action =
  let* () = permitted role in
  let result = match Play_room.presence action with
    | None -> perform_action ~base_path ~agent_name ~speaker:Play_room.Participant action
    | Some (operation, play_client) ->
      guarded_http ~base_path ~agent_name ~play_client operation action
  in
  finish_http ~base_path result

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
       (match presence_action Play_room.Join scope with
        | Ok _ -> Ok (Some scope)
        | Error error -> Error (Play_room.error_message error)))
  | [], _ | _, [] -> Error "play_client_id and play_machine must be provided together"
  | _, _ -> Error "play_client_id and play_machine must each appear exactly once"

module For_testing = struct
  let with_permission replacement fn =
    let previous = !permission in
    permission := replacement;
    Fun.protect ~finally:(fun () -> permission := previous) fn

  let with_perform replacement fn =
    let previous = !perform in
    perform := replacement;
    Fun.protect ~finally:(fun () -> perform := previous) fn
end
