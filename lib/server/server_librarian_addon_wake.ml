module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate = Keeper_librarian_admission_gate
module Owner = Lane_addon_tool_request_owner
module Runtime = Lane_addon_runtime
let ( let* ) = Result.bind
let install ~sw ~config =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let stopped=Atomic.make false in
  let discover = function
    | Runtime.Configuration_observed | Export_inventory_changed ->
      Keeper_memory_admission_queue.list_keeper_ids ~keepers_dir
    | Exact_result_delivered {installation_id;instance_id=_;request_id} ->
      let* scope=Capture.scope_of_request_id request_id in
      let* original=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
      let* original=Option.to_result ~none:"Librarian result hint has no original owner" original in
      let* owner=Capture.observe_record_owner ~base_path ~keepers_dir original in
      let* inventory=Parts.discover ~store ~owner
        ~restore_gate:(Gate.restore_size_evidence ~store ~owner) in
      let* capture=Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) original in
      if installation_id=(Capture.destination capture).installation_id
      then Ok [Capture.keeper_id owner]
      else Error "Librarian result hint belongs to a different original installation" in
  let signal event =
    if not (Atomic.get stopped) then (
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Fiber.yield ();
        if not (Atomic.get stopped) then
          match Domain_pool_ref.submit_io_or_inline (fun () -> discover event) with
          | Error detail -> Log.Server.warn "Librarian Addon wake discovery: %s" detail
          | Ok names ->
            if not (Atomic.get stopped) then List.iter (fun keeper_name ->
              Keeper_librarian_queue_signal.changed ~base_path ~keeper_name) names)) in
  let unsubscribe=Runtime.subscribe_owner_events ~config ~package_id:Capture.package_id signal in
  Eio.Switch.on_release sw (fun () -> Atomic.set stopped true;unsubscribe ())
