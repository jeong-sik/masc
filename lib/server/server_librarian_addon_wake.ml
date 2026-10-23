module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate = Keeper_librarian_admission_gate
module Owner = Lane_addon_tool_request_owner
module Runtime = Lane_addon_runtime
module History = Keeper_librarian_durable_request
let ( let* ) = Result.bind
type namespace = Admission of string | History of string | Other
let namespace id = match Capture.scope_of_request_id id with
  | Ok scope -> Admission scope
  | Error _ -> match History.scope_of_request_id id with
    | Ok scope -> History scope
    | Error _ -> Other
type discovery = {keepers:string list;refusals:string list}
let admission_keeper ~store ~base_path ~keepers_dir original =
  let* owner=Capture.observe_record_owner ~base_path ~keepers_dir original in
  let* inventory=Parts.discover ~store ~owner ~restore_gate:(Gate.restore_size_evidence ~store ~owner) in
  let* capture=Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) original in
  Ok (Capture.keeper_id owner,(Capture.destination capture).installation_id)
let history_keeper ~base_path ~keepers_dir original =
  let* owner=History.observe_record_owner ~base_path ~keepers_dir original in
  let* capture=History.restore ~owner original in
  Ok (History.keeper_id owner,(History.destination capture).installation_id)
let install ~sw ~config =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let stopped=Atomic.make false in
  let discover = function
    | Runtime.Configuration_observed | Export_inventory_changed ->
      let* queued=Keeper_memory_admission_queue.list_keeper_ids ~keepers_dir in
      let* originals=Owner.discover_all ~store |> Result.map_error Owner.error_to_string in
      let found=List.fold_left (fun found (original:Owner.retained) ->
        let keeper=match namespace original.request_id with
          | Admission scope when scope=original.scope ->
            admission_keeper ~store ~base_path ~keepers_dir original |> Result.map Option.some
          | History scope when scope=original.scope ->
            history_keeper ~base_path ~keepers_dir original |> Result.map Option.some
          (* Gate/partition journals have their own domains. Only the exact
             execution scope derived by its typed ID decoder is this owner. *)
          | Admission _ | History _ | Other -> Ok None in
        match keeper with
        | Ok None -> found
        | Ok (Some (keeper,_installation)) -> {found with keepers=keeper::found.keepers}
        | Error detail -> {found with refusals=detail::found.refusals})
        {keepers=queued;refusals=[]} originals in
      Ok {keepers=List.sort_uniq String.compare found.keepers;refusals=List.rev found.refusals}
    | Exact_result_delivered {installation_id;instance_id=_;request_id} ->
      let* scope=match namespace request_id with
        | Admission scope | History scope -> Ok scope
        | Other -> Error "Librarian result hint has no original execution namespace" in
      let* original=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
      let* original=Option.to_result ~none:"Librarian result hint has no original owner" original in
      let* keeper,original_installation=match namespace request_id with
        | Admission _ -> admission_keeper ~store ~base_path ~keepers_dir original
        | History _ -> history_keeper ~base_path ~keepers_dir original
        | Other -> Error "Librarian result hint has no original execution namespace" in
      if installation_id=original_installation
      then Ok {keepers=[keeper];refusals=[]}
      else Error "Librarian result hint belongs to a different original installation" in
  let signal event =
    if not (Atomic.get stopped) then (
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Fiber.yield ();
        if not (Atomic.get stopped) then
          match Domain_pool_ref.submit_io_or_inline (fun () -> discover event) with
          | Error detail -> Log.Server.warn "Librarian Addon wake discovery: %s" detail
          | Ok found ->
            List.iter (fun detail -> Log.Server.warn "Librarian Addon original wake refused: %s" detail) found.refusals;
            if not (Atomic.get stopped) then List.iter (fun keeper_name ->
              Keeper_librarian_queue_signal.changed ~base_path ~keeper_name) found.keepers)) in
  let unsubscribe=Runtime.subscribe_owner_events ~config ~package_id:Capture.package_id signal in
  Eio.Switch.on_release sw (fun () -> Atomic.set stopped true;unsubscribe ())
