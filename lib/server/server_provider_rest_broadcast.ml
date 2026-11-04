(* A Keeper's provider rest as its roster row draws it. *)
let shown_rest ~now keeper_name =
  match Keeper_meta_contract.runtime_route_of_keeper_name keeper_name with
  | None -> `Null
  | Some route -> Keeper_tool_surface_ops.runtime_path_rest_json ~now route
;;

(* The names the roster lists: the registry's and the persisted ones. *)
let keeper_names ~(config : Workspace.config) =
  let registered =
    Keeper_registry.all ~base_path:config.base_path ()
    |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
  in
  let persisted =
    match Keeper_meta_store.keeper_names_result config with
    | Ok names -> names
    | Error detail ->
      Log.Server.warn "provider rest broadcast: persisted Keeper names unreadable: %s" detail;
      []
  in
  registered @ persisted
  |> List.map String.trim
  |> List.filter (fun name -> not (String.equal name ""))
  |> List.sort_uniq String.compare
;;

let earliest times =
  List.fold_left
    (fun earliest at -> Some (Option.fold earliest ~none:at ~some:(Float.min at)))
    None times
;;

(* Every listed Keeper's shown rest, and the earliest dated release on any
   of their walks. *)
let recompute ~config ~now =
  let names = keeper_names ~config in
  let shown = List.map (fun name -> name, shown_rest ~now name) names in
  let next_release =
    names
    |> List.filter_map Keeper_meta_contract.runtime_route_of_keeper_name
    |> List.sort_uniq String.compare
    |> List.filter_map (Keeper_turn_driver.assignment_next_dated_release ~now)
    |> earliest
  in
  shown, next_release
;;

let moved ~before ~after =
  List.filter_map
    (fun (name, shown) ->
       match List.assoc_opt name before with
       | Some previous when Yojson.Safe.equal previous shown -> None
       | Some _ | None -> Some name)
    after
;;

(* What the runtime document shows of every runtime's standing, and the
   earliest time it changes with no write. *)
type standing =
  | Standing of Yojson.Safe.t
  | Standing_unbuilt

let read_standing ~config ~now =
  match
    ( Server_dashboard_runtime_resolved_json.standing ~now ~config
    , Server_dashboard_runtime_resolved_json.next_standing_change_at ~now )
  with
  | standing, next_change -> Ok (standing, next_change)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Server.warn "provider rest broadcast: runtime standing failed: %s" (Printexc.to_string exn);
    Error ()
;;

(* A standing that cannot be built is announced once, when it stops building,
   so a reader looks and draws the failure; while it keeps failing the reader
   retries on its own backoff. The time the last built standing said it would
   change still wakes the loop, once, unless it has passed. *)
let next_standing ~config ~now ~next_change_before =
  match read_standing ~config ~now with
  | Ok (document, next_change) -> Standing document, next_change
  | Error () ->
    let next_change =
      match next_change_before with
      | Some at when at > now -> Some at
      | Some _ | None -> None
    in
    Standing_unbuilt, next_change
;;

let standing_moved ~before ~after =
  match before, after with
  | Standing previous, Standing current -> not (Yojson.Safe.equal previous current)
  | Standing_unbuilt, Standing_unbuilt -> false
  | Standing _, Standing_unbuilt | Standing_unbuilt, Standing _ -> true
;;

let install ~sw ~clock ~(config : Workspace.config) =
  let wake = Eio.Stream.create 1 in
  let wake_mu = Stdlib.Mutex.create () in
  Runtime_path_rest_signal.install (fun () ->
    Stdlib.Mutex.protect wake_mu (fun () ->
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ()));
  let read ~before =
    match recompute ~config ~now:(Eio.Time.now clock) with
    | result -> result
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Log.Server.warn "provider rest broadcast: recompute failed: %s" (Printexc.to_string exn);
      before, None
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec watch before standing_before next_change_before =
      let after, next_release = read ~before in
      List.iter
        (fun keeper_name -> Keeper_row_broadcast.changed ~base_path:config.base_path ~keeper_name)
        (moved ~before ~after);
      let standing, next_change =
        next_standing ~config ~now:(Eio.Time.now clock) ~next_change_before
      in
      (* A runtime's quota or rate-limit standing, a reset passing included,
         changes the runtime document the Usage view reads. The history does
         not move with it, so this is announced apart from a usage report. *)
      if standing_moved ~before:standing_before ~after:standing then
        Workspace_dataset_event.announce ~base_path:config.base_path
          Workspace_dataset_event.Provider_standing;
      (match earliest (Option.to_list next_release @ Option.to_list next_change) with
       | None -> Eio.Stream.take wake
       | Some at ->
         Eio.Fiber.first
           (fun () -> Eio.Stream.take wake)
           (fun () -> Eio.Time.sleep_until clock at));
      watch after standing next_change
    in
    let initial, _ = read ~before:[] in
    let initial_standing, initial_next_change =
      next_standing ~config ~now:(Eio.Time.now clock) ~next_change_before:None
    in
    watch initial initial_standing initial_next_change)
;;
