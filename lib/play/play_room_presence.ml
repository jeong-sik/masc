open Result.Syntax

type scope = {
  play_client : string;
  machine : Machine_lane.t;
}

type connection_outcome = Connected | Stale

type lease = {
  sse_client_id : int;
  machine : Machine_lane.t;
}

let leases : (string * string * string, lease) Hashtbl.t = Hashtbl.create 31
let lease_mutex = Eio.Mutex.create ()
let permission = ref Masc_domain.has_permission
let perform_action_with = ref Play_room.perform_with_change

let key ~base_path ~agent_name ~play_client = base_path, agent_name, play_client

let permitted role =
  if !permission role Masc_domain.CanPlayMachine then Ok ()
  else Error (Play_room.Invalid_request "play room presence is not permitted")

let speaker_of_role = function
  | Masc_domain.Worker | Masc_domain.Admin -> Play_room.Keeper
  | Masc_domain.Player -> Play_room.Participant

let presence_action operation (scope : scope) =
  let action = match operation with Play_room.Join -> "join" | Play_room.Leave -> "leave" in
  Play_room.parse_action (`Assoc [
    "action", `String action;
    "client_id", `String scope.play_client;
    "machine", `String (Machine_lane.to_wire scope.machine);
  ])

let with_lease_lock fn = Eio.Mutex.use_rw ~protect:true lease_mutex fn

let announce_change ~base_path = function
  | Some (change : Play_room.change)
    when change.message_committed || change.membership_changed ->
    Workspace_dataset_event.announce ~base_path
      (Workspace_dataset_event.Play_room { machine = change.machine })
  | Some _ | None -> ()

let perform_action ~base_path ~agent_name ~speaker action =
  !perform_action_with ~base_path ~who:agent_name ~speaker ~now:(Time_compat.now ()) action
  |> Result.map (fun (snapshot, change) -> snapshot, Some change)

let current_snapshot ~base_path =
  Play_room.read ~base_path ~now:(Time_compat.now ()) ~before:None
  |> Result.map (fun snapshot -> snapshot, None)

let finish result ~base_path =
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
    | Some current when current.sse_client_id > sse_client_id -> Ok (None, Stale)
    | Some _ | None ->
      match perform_action ~base_path ~agent_name ~speaker action with
      | Error _ as error -> error
      | Ok (_, change) ->
        Hashtbl.replace leases key { sse_client_id; machine = scope.machine };
        Ok (change, Connected))
  |> Result.map (fun (change, outcome) ->
    announce_change ~base_path change;
    outcome)

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
  let result = Eio.Cancel.protect (fun () ->
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
      ())) in
  Eio.Fiber.check ();
  result

let perform_with_change ~base_path ~who ~speaker action =
  match Play_room.presence action with
  | None -> perform_action ~base_path ~agent_name:who ~speaker action
  | Some (operation, play_client) ->
    let key = key ~base_path ~agent_name:who ~play_client in
    with_lease_lock (fun () ->
      match Hashtbl.find_opt leases key with
      | Some _ -> current_snapshot ~base_path
      | None ->
        (match operation with
         | Play_room.Join | Play_room.Leave ->
           perform_action ~base_path ~agent_name:who ~speaker action))

let perform_http ~base_path ~agent_name ~role action =
  let* () = permitted role in
  perform_with_change ~base_path ~who:agent_name ~speaker:Play_room.Participant action
  |> finish ~base_path

module For_testing = struct
  let with_permission replacement fn =
    let previous = !permission in
    permission := replacement;
    Fun.protect ~finally:(fun () -> permission := previous) fn

  let with_perform replacement fn =
    let previous = !perform_action_with in
    perform_action_with := replacement;
    Fun.protect ~finally:(fun () -> perform_action_with := previous) fn
end
