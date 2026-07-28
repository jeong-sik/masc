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

let registered_assigned_keepers goal_id =
  Keeper_registry.all ()
  |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
       if List.mem goal_id entry.meta.active_goal_ids then Some entry.name else None)
;;

let durable_assigned_keepers config goal_id =
  Keeper_meta_store.keepalive_keeper_names config
  |> List.filter_map (fun keeper_name ->
       match Keeper_meta_store.read_effective_meta config keeper_name with
       | Ok (Some meta)
         when not meta.Keeper_meta_contract.paused
              && List.mem goal_id meta.active_goal_ids ->
         Some meta.name
       | Ok (Some _) | Ok None | Error _ -> None)
;;

let sole_assigned_keeper ~config goal_id =
  registered_assigned_keepers goal_id @ durable_assigned_keepers config goal_id
  |> List.sort_uniq String.compare
  |> function
  | [ keeper_name ] -> Some keeper_name
  | [] | _ :: _ :: _ -> None

let target_keeper_name ~config ~completing_agent_name ~goal_id =
  match Keeper_identity.canonical_keeper_name_from_agent_name completing_agent_name with
  | Some keeper_name -> Some keeper_name
  | None -> sole_assigned_keeper ~config goal_id

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
