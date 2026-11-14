module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Closure = Keeper_librarian_admission_closure
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
    let result=Parts.discover ~store ~owner in
    parts_by_owner:=(owner,result):: !parts_by_owner;
    result
let admission_keeper ~store ~parts_by_owner ~base_path ~keepers_dir original =
  let* owner=Capture.observe_record_owner ~base_path ~keepers_dir original in
  let read ~scope ~request_id=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
  let read_scope ~scope=Owner.load_scope ~store ~scope |> Result.map_error Owner.error_to_string in
  let reader=Owner.Published_reader.create ~read_body:(fun ~scope ~request_digest ->
    Store.load_tool_request_body store ~scope ~request_digest) in
  let read_archive ~scope ~date ~request_id=Owner.load_settled ~store ~scope ~date ~request_id
    |> Result.map_error Owner.error_to_string in
  let* view=Closure.project ~owner ~read ~read_scope ~read_body:(Owner.Published_reader.request reader) ~read_archive in
  let* capture=match view.closure with
    | None ->
      let* inventory=discover_parts ~store ~parts_by_owner owner in
      Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) original
    | Some _ ->
      (* A wake grants no execution or settlement authority. A closing forest
         can have archived gates/sources, so use its verified payload parents
         only to notify the same physical owner; the lane reconfirms receipts. *)
      Capture.restore ~owner ~load_parent:(Parts.load_parent_payload ~read:view.read ~owner) original in
  Ok (Capture.keeper_id owner,(Capture.destination capture).installation_id)
(* The record's summary is the index of the history request: it names the
   owner and the destination, so the wake reads no body. The index is bound
   to the body where the Keeper's pass reads it. *)
let history_keeper ~base_path ~keepers_dir record =
  let* index=History.index_of_summary record in
  let* owner=History.observe_index_owner ~base_path ~keepers_dir index in
  let* ()=History.confirm_index_source_root index in
  Ok (History.keeper_id owner,index.destination.installation_id)
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
let discover ~fold_records ~on_original ~config ~store =
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
          fold_records ~store ~init:([],[]) ~f:(fun (keepers,refusals) record ->
          let scope=Owner.Record.scope record in
          (* An admission or a floor step is restored from its body; a body
             that cannot be read rejects the scan. *)
          let with_body keeper =
            let* original=Owner.load_listed ~store record in
            on_original original;
            Ok (keeper original |> Result.map Option.some) in
          let* keeper=match Namespace.of_request_id (Owner.Record.request_id record) with
            | Namespace.Admission owner when owner=scope ->
              with_body (admission_keeper ~store ~parts_by_owner ~base_path ~keepers_dir)
            | History owner when owner=scope ->
              Ok (history_keeper ~base_path ~keepers_dir record |> Result.map Option.some)
            | Floor_step owner when owner=scope ->
              with_body (floor_step_keeper ~base_path ~keepers_dir)
            (* Gate/partition journals have their own domains. Only the exact
               execution scope derived by its typed ID decoder is this owner. *)
            | Admission _ | History _ | Floor_step _ | Other -> Ok (Ok None) in
          Ok (match keeper with
          | Ok None -> keepers,refusals
          | Ok (Some (keeper,_installation)) -> keeper::keepers,refusals
          | Error detail -> keepers,detail::refusals))) in
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
      let with_body keeper =
        let* original=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
        let* original=Option.to_result ~none:"Librarian result hint has no original owner" original in
        keeper original in
      let parts_by_owner=ref [] in
      let* keeper,original_installation=match Namespace.of_request_id request_id with
        | Namespace.Admission _ -> with_body (admission_keeper ~store ~parts_by_owner ~base_path ~keepers_dir)
        | History _ ->
          let* record=Owner.load_record ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
          let* record=Option.to_result ~none:"Librarian result hint has no original owner" record in
          history_keeper ~base_path ~keepers_dir record
        | Floor_step _ -> with_body (floor_step_keeper ~base_path ~keepers_dir)
        | Other -> Error "Librarian result hint has no original execution namespace" in
      if installation_id=original_installation
      then Ok {keepers=[keeper];refusals=[];original_keepers=[keeper]}
      else Error "Librarian result hint belongs to a different original installation"
let install ~sw ~config =
  let base_path=config.Workspace.base_path in
  let store=Lane_addon_store.of_config config in
  let stopped=Atomic.make false in
  let rescan_state=Atomic.make Idle in
  let run_discovery event =
    if not (Atomic.get stopped) then
      match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        discover ~fold_records:Owner.fold_all_records ~on_original:ignore ~config ~store event) with
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
      | Exact_result_delivered { installation_id; _ } ->
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Fiber.yield ();
          Keeper_librarian_queue_refresh.capacity_released ~config ~installation_id;
          run_discovery event)) in
  let unsubscribe=Runtime.subscribe_owner_events ~config ~package_id:Capture.package_id signal in
  Eio.Switch.on_release sw (fun () -> Atomic.set stopped true;unsubscribe ())
module For_testing = struct
  let discover ~config ~store ~after_inventory ~on_original ~event =
    let fold_records ~store ~init ~f = Owner.For_testing.fold_all_records ~store ~after_inventory ~init ~f in
    Result.map (fun found -> found.keepers,found.refusals,found.original_keepers)
      (discover ~fold_records ~on_original ~config ~store event)
end
