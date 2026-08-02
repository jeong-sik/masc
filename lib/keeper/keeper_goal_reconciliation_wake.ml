type enqueue_outcome =
  | Not_ready
  | No_keeper_target of { goal_id : string }
  | Enqueued of { goal_id : string; keeper_name : string }
  | Already_present of { goal_id : string; keeper_name : string }
  | Enqueue_failed of { goal_id : string; keeper_name : string; detail : string }

type reconciliation_summary = {
  ready_count : int;
  enqueued_count : int;
  already_present_count : int;
  unresolved_count : int;
  failed_count : int;
}

type keeper_target_resolution =
  | Assigned_keeper of string
  | No_assigned_keeper
  | Ambiguous_assigned_keepers of string list
  | Assigned_keeper_lookup_failed of string

type durable_assignment_scan = {
  keeper_names : string list;
  errors : string list;
}

let registered_assigned_keepers ~base_path goal_id =
  Keeper_registry.all ~base_path ()
  |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
       if
         (not entry.meta.paused)
         && List.mem goal_id entry.meta.active_goal_ids
       then Some entry.name
       else None)
  |> List.sort_uniq String.compare
;;

let durable_assigned_keepers config goal_id =
  let rec collect keeper_names errors = function
    | [] ->
      { keeper_names = List.sort_uniq String.compare keeper_names
      ; errors = List.rev errors
      }
    | keeper_name :: rest ->
      (match Keeper_meta_store.read_effective_meta_resolved config keeper_name with
       | Error detail ->
         collect
           keeper_names
           (Printf.sprintf "keeper=%s: %s" keeper_name detail :: errors)
           rest
       | Ok None -> collect keeper_names errors rest
       | Ok (Some (canonical_keeper_name, meta)) ->
         if
           (not meta.Keeper_meta_contract.paused)
           && List.mem goal_id meta.active_goal_ids
         then collect (canonical_keeper_name :: keeper_names) errors rest
         else collect keeper_names errors rest)
  in
  match Keeper_meta_store.persisted_keeper_names_result config with
  | Error detail -> { keeper_names = []; errors = [ detail ] }
  | Ok keeper_names -> collect [] [] keeper_names
;;

let assigned_keeper_resolution ~(config : Workspace.config) goal_id =
  let registered =
    registered_assigned_keepers ~base_path:config.Workspace.base_path goal_id
  in
  let durable = durable_assigned_keepers config goal_id in
  if durable.errors <> []
  then
    Log.Keeper.error
      "goal reconciliation Keeper assignment scan incomplete goal_id=%s errors=%s"
      goal_id
      (String.concat "; " durable.errors);
  match List.sort_uniq String.compare (registered @ durable.keeper_names) with
  | [ keeper_name ] -> Assigned_keeper keeper_name
  | [] when durable.errors <> [] ->
    Assigned_keeper_lookup_failed (String.concat "; " durable.errors)
  | [] -> No_assigned_keeper
  | keeper_names -> Ambiguous_assigned_keepers keeper_names
;;

let exact_producer_keeper_name ~config ~completing_agent_name =
  match
    Keeper_identity_binding.resolve
      ~config
      ~agent_name:completing_agent_name
  with
  | Keeper_identity_binding.Not_found -> Ok None
  | Keeper_identity_binding.Unique keeper_name -> Ok (Some keeper_name)
  | Keeper_identity_binding.Ambiguous keeper_names ->
    Error
      (Printf.sprintf
         "multiple registered or persisted Keepers share agent_name=%s: %s"
         completing_agent_name
         (String.concat "," keeper_names))
  | Keeper_identity_binding.Lookup_failed detail -> Error detail
;;

let target_keeper_name ~config ~completing_agent_name ~goal_id =
  match assigned_keeper_resolution ~config goal_id with
  | Assigned_keeper keeper_name -> Some keeper_name
  | Ambiguous_assigned_keepers keeper_names ->
    Log.Keeper.error
      "goal reconciliation has ambiguous active Goal assignment goal_id=%s keepers=%s"
      goal_id
      (String.concat "," keeper_names);
    None
  | Assigned_keeper_lookup_failed detail ->
    Log.Keeper.error
      "goal reconciliation Keeper assignment lookup failed goal_id=%s detail=%s"
      goal_id
      detail;
    None
  | No_assigned_keeper ->
    (match exact_producer_keeper_name ~config ~completing_agent_name with
     | Ok (Some keeper_name) -> Some keeper_name
     | Ok None -> None
     | Error detail ->
       Log.Keeper.error
         "goal reconciliation producer identity lookup failed goal_id=%s producer=%s detail=%s"
         goal_id
         completing_agent_name
         detail;
       None)

let wake_keeper ~base_path keeper_name goal_id =
  match
    Keeper_registry.wakeup_running
      ~intent:Keeper_registry.Goal_signal
      ~base_path
      keeper_name
  with
  | Keeper_registry.Signaled -> ()
  | Keeper_registry.Deferred_unregistered ->
    Log.Keeper.info
      "goal reconciliation wake persisted for unregistered keeper=%s goal_id=%s"
      keeper_name
      goal_id
  | Keeper_registry.Deferred_not_running phase ->
    Log.Keeper.info
      "goal reconciliation wake deferred by registry phase contract keeper=%s \
       phase=%s goal_id=%s"
      keeper_name
      (Keeper_state_machine.phase_to_string phase)
      goal_id
  | Keeper_registry.Deferred_lifecycle denial ->
    Log.Keeper.info
      "goal reconciliation wake deferred by lifecycle keeper=%s reason=%s goal_id=%s"
      keeper_name
      (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
      goal_id

let enqueue_ready ?(wake_if_present = false) ~config ~completing_agent_name
      ({ Masc_task_handlers.Task_goal_reconciliation.goal_id; triggering_task_id } as ready_fact)
  =
  match target_keeper_name ~config ~completing_agent_name ~goal_id with
     | None ->
       Log.Keeper.warn
         "goal reconciliation ready but no unambiguous Keeper target goal_id=%s \
          triggering_task_id=%s completing_agent=%s"
         goal_id
         triggering_task_id
         completing_agent_name;
       No_keeper_target { goal_id }
     | Some keeper_name ->
       let ready : Keeper_event_queue.goal_reconciliation_ready =
         { gr_goal_id = ready_fact.goal_id
         ; gr_triggering_task_id = ready_fact.triggering_task_id
         }
       in
       let stimulus : Keeper_event_queue.stimulus =
         { post_id = Keeper_event_queue.goal_reconciliation_ready_post_id ready
         ; urgency = Keeper_event_queue.Immediate
         ; arrived_at = Time_compat.now ()
         ; payload = Keeper_event_queue.Goal_reconciliation_ready ready
         }
       in
       match
         Keeper_registry_event_queue.enqueue_stimulus_durable_result
           ~base_path:config.base_path
           keeper_name
           stimulus
       with
       | Keeper_registry_event_queue.Stimulus_enqueued ->
         wake_keeper ~base_path:config.base_path keeper_name goal_id;
         Enqueued { goal_id; keeper_name }
       | Keeper_registry_event_queue.Stimulus_already_present ->
         if wake_if_present
         then wake_keeper ~base_path:config.base_path keeper_name goal_id;
         Already_present { goal_id; keeper_name }
       | Keeper_registry_event_queue.Stimulus_storage_error detail ->
         Log.Keeper.error
           "goal reconciliation durable enqueue failed keeper=%s goal_id=%s \
            triggering_task_id=%s: %s"
           keeper_name
           goal_id
           triggering_task_id
           detail;
         Enqueue_failed { goal_id; keeper_name; detail }
;;

let enqueue_if_ready ~config ~completing_agent_name ~task_id =
  match
    Masc_task_handlers.Task_goal_reconciliation.ready_after_terminal_task
      ~config
      ~task_id
  with
  | None -> Not_ready
  | Some ready -> enqueue_ready ~config ~completing_agent_name ready
;;

let reconcile_startup ~config =
  let ready =
    Masc_task_handlers.Task_goal_reconciliation.ready_executing_goals ~config
  in
  List.fold_left
    (fun
       summary
       (candidate :
         Masc_task_handlers.Task_goal_reconciliation.startup_ready) ->
       let outcome =
         enqueue_ready
           ~wake_if_present:true
           ~config
           ~completing_agent_name:candidate.completing_agent_name
           candidate.ready
       in
       match outcome with
       | Not_ready -> summary
       | Enqueued _ ->
         { summary with enqueued_count = summary.enqueued_count + 1 }
       | Already_present _ ->
         { summary with
           already_present_count = summary.already_present_count + 1
         }
       | No_keeper_target _ ->
         { summary with unresolved_count = summary.unresolved_count + 1 }
       | Enqueue_failed _ ->
         { summary with failed_count = summary.failed_count + 1 })
    { ready_count = List.length ready
    ; enqueued_count = 0
    ; already_present_count = 0
    ; unresolved_count = 0
    ; failed_count = 0
    }
    ready
;;
