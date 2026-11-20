module By_workspace = Map.Make (String)
module Registry = Runtime_exact_output_registry

let tables : Librarian_writers.t By_workspace.t Atomic.t = Atomic.make By_workspace.empty

let rec update change =
  let before = Atomic.get tables in
  if not (Atomic.compare_and_set tables before (change before)) then update change
;;

let workspace_key ~base_path = Keeper_registry_types.canonical_base_path_exn base_path

let start ~sw ~ask ~start_turn_log ~(config : Workspace.config) =
  let base_path = config.base_path in
  let key = workspace_key ~base_path in
  let memory_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let turns_dir = Workspace.keepers_runtime_dir config in
  let table =
    Librarian_writers.create
      ~sw
      ~now:Time_compat.now
      ~registered:(fun keeper -> Keeper_registry.is_registered ~base_path keeper)
      ~place:(fun keeper_id -> { memory_dir; turns_dir; keeper_id })
      ~stores:(fun keeper_name ->
        { session_dir = (fun ~session -> Keeper_types_support.keeper_session_dir config session)
        ; base_path
        ; keeper_name
        })
      ~ask
      ~start_turn_log
  in
  update (By_workspace.add key table);
  (* A later start may have replaced this table; only its own entry goes. *)
  Eio.Switch.on_release sw (fun () ->
    update (fun tables ->
      match By_workspace.find_opt key tables with
      | Some current when current == table -> By_workspace.remove key tables
      | Some _ | None -> tables));
  table
;;

let find ~base_path = By_workspace.find_opt (workspace_key ~base_path) (Atomic.get tables)

(* The lane value under the registry published now. A registry that is
   being replaced is not read: the end of the replacement signals the lane
   (§9.5). *)
let declare ~prompt ~answer_schema writers =
  let undeclared reason =
    Log.Keeper.warn "librarian memory lane has no value: %s" reason;
    Librarian_writers.declaration_changed writers None
  in
  match Registry.current () with
  | Error Publication_busy -> ()
  | Error
      (( Registry_not_published | Replacement_base_changed | Duplicate_lane_id _ | Empty_lane _
       | Blank_lane_slot _ | Duplicate_lane_slot _ | Invalid_lane_slot _
       | Lane_thinking_not_encodable _ | Required_lane_unavailable _ | Required_lane_disabled _
       | Resolver_snapshot_rejected _ | Targets_refused _ ) as error) ->
    undeclared (Registry.publication_error_to_string error)
  | Ok registry ->
    (match Librarian_memory_lane.resolve ~prompt ~answer_schema registry with
     | Ok (value, resolved) ->
       Librarian_writers.declaration_changed writers (Some { value; resolved })
     | Error why -> undeclared (Librarian_memory_lane.show_unavailable why))
;;

let follow_declaration ~sw ~prompt ~answer_schema writers =
  (* The registry calls back outside its mutex, from any domain, and the
     callback only signals. Signals that come while a value is being sent
     are one change. *)
  let lane_revision = Atomic.make 0 in
  let lane_moved = Eio.Condition.create () in
  let unsubscribe =
    Registry.subscribe_lane_changes ~lane_id:Librarian_memory_lane.lane_id (fun () ->
      Atomic.incr lane_revision;
      Eio.Condition.broadcast lane_moved)
  in
  Eio.Switch.on_release sw unsubscribe;
  let await_lane_change ~after =
    Eio.Condition.loop_no_mutex lane_moved (fun () ->
      let current = Atomic.get lane_revision in
      if current > after then Some current else None)
  in
  (* Both revisions are read before the value is: a publication after that
     read wakes the next wait at once. *)
  let rec follow ~catalogue ~lane =
    declare ~prompt ~answer_schema writers;
    let catalogue, lane =
      Eio.Fiber.first
        (fun () -> Runtime.await_catalogue_change ~after:catalogue, lane)
        (fun () -> catalogue, await_lane_change ~after:lane)
    in
    follow ~catalogue ~lane
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    follow ~catalogue:(Runtime.catalogue_revision ()) ~lane:(Atomic.get lane_revision))
;;
