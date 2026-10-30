module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate = Keeper_librarian_admission_gate
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Runtime = Lane_addon_runtime
module History = Keeper_librarian_durable_request
open Result.Syntax
module Namespace = Keeper_librarian_request_namespace
module Step = Keeper_librarian_floor_step_request
type discovery = {keepers:string list;refusals:string list;original_keepers:string list}
let discover_parts ~store ~parts_by_owner owner =
  match List.assoc_opt owner !parts_by_owner with
  | Some result -> result
  | None ->
    let result=Parts.discover ~store ~owner ~restore_gate:(Gate.restore_size_evidence ~store ~owner) in
    parts_by_owner:=(owner,result):: !parts_by_owner;
    result
let admission_keeper ~store ~parts_by_owner ~base_path ~keepers_dir original =
  let* owner=Capture.observe_record_owner ~base_path ~keepers_dir original in
  let* inventory=discover_parts ~store ~parts_by_owner owner in
  let* capture=Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) original in
  Ok (Capture.keeper_id owner,(Capture.destination capture).installation_id)
let history_keeper ~base_path ~keepers_dir original =
  let* owner=History.observe_record_owner ~base_path ~keepers_dir original in
  let* capture=History.restore ~owner original in
  Ok (History.keeper_id owner,(History.destination capture).installation_id)
(* The step's header names its destination, so the wake needs neither the step's
   input nor its prompt. *)
let floor_step_keeper ~base_path ~keepers_dir original =
  let* owner=Step.observe_record_owner ~base_path ~keepers_dir original in
  let* header=Step.header ~owner original in
  Ok (History.keeper_id owner,header.destination.installation_id)
type rescan_state = Idle | Running | Rerun_needed
let rec claim_rescan state =
  match Atomic.get state with
  | Idle ->
    if Atomic.compare_and_set state Idle Running then true
    else claim_rescan state
  | Running ->
    if Atomic.compare_and_set state Running Rerun_needed then false
    else claim_rescan state
  | Rerun_needed -> false
let rec finish_rescan_pass state =
  match Atomic.get state with
  | Running ->
    if Atomic.compare_and_set state Running Idle then false
    else finish_rescan_pass state
  | Rerun_needed ->
    if Atomic.compare_and_set state Rerun_needed Running then true
    else finish_rescan_pass state
  | Idle -> false
let discover ~fold_originals ~config ~store =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  function
    | Runtime.Configuration_observed | Export_inventory_changed ->
      (* An absent dependency stops durable history before an original is
         captured. Its persisted Keeper is still a real owner to notify;
         the normal serialized lane decides whether it has unread input. *)
      let persisted,metadata_refusals=match Keeper_meta_store.persisted_keeper_names_read_only_result config with
        | Ok names -> names,[]
        | Error detail -> [],[detail] in
      let queued,queue_refusals=match Keeper_memory_admission_queue.list_keeper_ids ~keepers_dir with
        | Ok names -> names,[]
        | Error detail -> [],[detail] in
      let parts_by_owner=ref [] in
      let original_keepers,original_refusals=
        let folded = Store.with_tool_request_settlement_barrier store (fun () ->
          fold_originals ~store ~init:([],[]) ~f:(fun (keepers,refusals) (original:Owner.retained) ->
          let keeper=match Namespace.of_request_id original.request_id with
            | Namespace.Admission scope when scope=original.scope ->
              admission_keeper ~store ~parts_by_owner ~base_path ~keepers_dir original |> Result.map Option.some
            | History scope when scope=original.scope ->
              history_keeper ~base_path ~keepers_dir original |> Result.map Option.some
            | Floor_step scope when scope=original.scope ->
              floor_step_keeper ~base_path ~keepers_dir original |> Result.map Option.some
            (* Gate/partition journals have their own domains. Only the exact
               execution scope derived by its typed ID decoder is this owner. *)
            | Admission _ | History _ | Floor_step _ | Other -> Ok None in
          match keeper with
          | Ok None -> keepers,refusals
          | Ok (Some (keeper,_installation)) -> keeper::keepers,refusals
          | Error detail -> keepers,detail::refusals)) in
        match folded with
        | Error detail -> [],[detail]
        | Ok (Error error) -> [],[Owner.error_to_string error]
        | Ok (Ok (keepers,refusals)) -> List.rev keepers,List.rev refusals in
      Ok {keepers=List.sort_uniq String.compare (persisted @ queued @ original_keepers);
          refusals=metadata_refusals @ queue_refusals @ original_refusals;original_keepers}
    | Exact_result_delivered {installation_id;instance_id=_;request_id} ->
      let* scope=match Namespace.of_request_id request_id with
        | Namespace.Admission scope | History scope | Floor_step scope -> Ok scope
        | Other -> Error "Librarian result hint has no original execution namespace" in
      let* original=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
      let* original=Option.to_result ~none:"Librarian result hint has no original owner" original in
      let parts_by_owner=ref [] in
      let* keeper,original_installation=match Namespace.of_request_id request_id with
        | Namespace.Admission _ -> admission_keeper ~store ~parts_by_owner ~base_path ~keepers_dir original
        | History _ -> history_keeper ~base_path ~keepers_dir original
        | Floor_step _ -> floor_step_keeper ~base_path ~keepers_dir original
        | Other -> Error "Librarian result hint has no original execution namespace" in
      if installation_id=original_installation
      then Ok {keepers=[keeper];refusals=[];original_keepers=[keeper]}
      else Error "Librarian result hint belongs to a different original installation"
let install ~sw ~config =
  let base_path=config.Workspace.base_path in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let stopped=Atomic.make false in
  let rescan_state=Atomic.make Idle in
  let run_discovery event =
    if not (Atomic.get stopped) then
      match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        discover ~fold_originals:Owner.fold_all ~config ~store event) with
      | Error detail -> Log.Server.warn "Librarian Addon wake discovery: %s" detail
      | Ok found ->
        List.iter (fun detail -> Log.Server.warn "Librarian Addon original wake refused: %s" detail) found.refusals;
        if not (Atomic.get stopped) then List.iter (fun keeper_name ->
          Keeper_librarian_queue_signal.changed ~base_path ~keeper_name) found.keepers in
  let signal event =
    if not (Atomic.get stopped) then (
      Eio.Switch.check sw;
      match event with
      | Runtime.Configuration_observed | Export_inventory_changed ->
        if claim_rescan rescan_state then
          Eio.Fiber.fork ~sw (fun () ->
            try
              Eio.Fiber.yield ();
              let rec loop () =
                run_discovery event;
                if Atomic.get stopped then Atomic.set rescan_state Idle
                else if finish_rescan_pass rescan_state then loop () in
              loop ()
            with exn ->
              let bt=Printexc.get_raw_backtrace () in
              Atomic.set rescan_state Idle;
              Printexc.raise_with_backtrace exn bt)
      | Exact_result_delivered _ ->
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Fiber.yield ();
          run_discovery event)) in
  let unsubscribe=Runtime.subscribe_owner_events ~config ~package_id:Capture.package_id signal in
  Eio.Switch.on_release sw (fun () -> Atomic.set stopped true;unsubscribe ())
module For_testing = struct
  let discover ~config ~store ~after_inventory ~on_original ~event =
    let fold_originals ~store ~init ~f =
      Owner.For_testing.fold_all ~store ~after_inventory ~init ~f:(fun acc original ->
        on_original original; f acc original) in
    Result.map (fun found -> found.keepers,found.refusals,found.original_keepers)
      (discover ~fold_originals ~config ~store event)
end
