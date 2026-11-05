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
    let rec watch before =
      let after, next_release = read ~before in
      List.iter
        (fun keeper_name -> Keeper_row_broadcast.changed ~base_path:config.base_path ~keeper_name)
        (moved ~before ~after);
      (match next_release with
       | None -> Eio.Stream.take wake
       | Some at ->
         Eio.Fiber.first
           (fun () -> Eio.Stream.take wake)
           (fun () -> Eio.Time.sleep_until clock at));
      watch after
    in
    let initial, _ = read ~before:[] in
    watch initial)
;;
