let observed_mu = Stdlib.Mutex.create ()

(* The pending inputs the last committed pass was shown, beside the
   working-context version that pass wrote and how many stores it could not read.
   A snapshot stores only the sources its pockets reference, and a pass that
   could not read one store keeps history it cannot confirm settled, so the
   stored references can differ from the pending ones on every capture while
   nothing changed. Compared against this record instead, an unchanged
   capture ends without a model call; a pass is still needed once the
   inputs change, a pocket needs reconsideration, or a store unread at the
   last pass can be read. The record lives in this process's memory only:
   another writer's version or a restart falls back to the stored
   references, at the cost of at most one pass. *)
type observed_inputs =
  { version : Keeper_librarian_context.version
  ; references : string list
  ; unreadable_stores : int
      (** How many stores the capture could not read. A store read again
          may settle sources the snapshot still holds, so fewer unreadable
          stores than last time asks for a pass. Counted, not compared by
          their failure text. *)
  }

let observed_inputs : ((string * string), observed_inputs) Hashtbl.t = Hashtbl.create 16

let context_references (sources : Keeper_librarian_context.source list) =
  List.map (fun (s : Keeper_librarian_context.source) -> s.reference) sources
  |> List.sort String.compare
;;

let remember ~keepers_dir ~keeper_name
    (working_context : Keeper_librarian_context.input) version =
  let observed =
    { version
    ; references = context_references working_context.sources
    ; unreadable_stores = List.length working_context.unavailable
    }
  in
  Stdlib.Mutex.protect observed_mu (fun () ->
    Hashtbl.replace observed_inputs (keepers_dir, keeper_name) observed)
;;

let needed ~keepers_dir ~keeper_name
    (working_context : Keeper_librarian_context.input) =
  let references = context_references working_context.sources in
  match working_context.previous with
  | None -> references <> []
  | Some snapshot ->
    let needs_reconsideration = List.exists (fun (p : Keeper_librarian_context.pocket) ->
      p.completeness = Keeper_librarian_context.Needs_reconsideration) snapshot.pockets in
    let observed = Stdlib.Mutex.protect observed_mu (fun () ->
      Hashtbl.find_opt observed_inputs (keepers_dir, keeper_name)) in
    let changed = match observed with
      | Some observed when observed.version = Keeper_librarian_context.version snapshot ->
        references <> observed.references
        || List.length working_context.unavailable < observed.unreadable_stores
      | Some _ | None -> references <> context_references snapshot.sources in
    changed || needs_reconsideration
;;

let goal_context_for_task ~config = function
  | None -> Keeper_librarian.No_task
  | Some task ->
    let task_id = Keeper_id.Task_id.to_string task in
    let open Result.Syntax in
    let criteria =
      let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config in
      let ids =
        List.filter_map
          (fun (goal_id, tasks) -> if List.mem task_id tasks then Some goal_id else None)
          links
      in
      let* goals_by_id =
        Result.map_error Goal_store.unavailable_to_string
          (Goal_store.load_goals_by_id_result config)
      in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | id :: rest ->
          (match Goal_store.Goal_id_map.find_opt id goals_by_id with
           | None -> Error ("Linked Goal is missing: " ^ id)
           | Some goal ->
             loop ((id, goal.phase, Goal_store.criterion_of_goal goal) :: acc) rest)
      in
      loop [] ids
    in
    Keeper_librarian.Task_goals { task_id; criteria }
;;

(* The pass organizes the inputs pending now, with no turn range, so the
   Keeper's current task is the task these inputs belong to. It organizes
   pending sources only and reads no Memory, so its input carries no current
   selection. *)
let input ~config ~keeper_id ~(meta : Keeper_meta_contract.keeper_meta)
    ~working_context : Keeper_librarian.input =
  { keeper_id
  ; turn_ref = Ids.Turn_ref.make
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~absolute_turn:meta.runtime.last_turn_id
  ; historical_task_contexts = []
  ; goal_context =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        goal_context_for_task ~config meta.current_task_id)
  ; keeper_instructions = meta.instructions
  ; current = None
  ; working_context
  ; messages = []; tool_observations = []; counterpart_observations = [] }

exception Blank_keeper_name

let run ~base_path ~keeper_name ~keeper_id =
  match
    ( (if Runtime_account_access.is_multi_account ()
       then Env_config.KeeperMemoryOs.Disabled
       else Env_config.KeeperMemoryOs.librarian_config_state ())
    , Keeper_owner_projection.lookup ~base_path ~keeper_name )
  with
  | Enabled, Owner_projection { meta = Some meta; stopping = false } ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let working_context =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Keeper_librarian_context_io.capture ~base_path ~keepers_dir ~keeper_name)
    in
    if needed ~keepers_dir ~keeper_name working_context
    then
      Keeper_librarian_runtime.run_best_effort
        ~write_scope:Keeper_librarian_runtime.Context_only
        ~on_context_committed:(remember ~keepers_dir ~keeper_name working_context)
        ~base_path
        ~keepers_dir
        ~keeper_id:keeper_name
        ~expected_revision:None
        (input ~config:(Workspace.default_config base_path) ~keeper_id ~meta ~working_context)
  | (Disabled | Invalid), _
  | ( Enabled
    , ( Owner_absent
      | Owner_projection { meta = None; _ }
      | Owner_projection { stopping = true; _ } ) ) -> ()
;;

let install () =
  Keeper_working_context_signal.install (fun ~base_path ~keeper_name ->
    if Runtime_account_access.is_multi_account ()
    then ()
    else
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled | Invalid -> ()
    | Enabled ->
      (* A signal can come from an HTTP or IO domain. Only the short submission
         crosses to the root switch owner; the model call is detached. *)
      Eio_context.run_on_owner_domain (fun () ->
        let (_ : Keeper_memory_lane.outcome) =
          Keeper_memory_lane.submit ~base_path ~keeper_name (fun () ->
            match Keeper_identity.Keeper_id.of_string keeper_name with
            | Some keeper_id -> run ~base_path ~keeper_name ~keeper_id
            | None -> raise Blank_keeper_name)
        in
        ()))
;;
