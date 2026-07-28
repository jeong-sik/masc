type enqueue_outcome =
  | Not_ready
  | No_keeper_target of { goal_id : string }
  | Enqueued of { goal_id : string; keeper_name : string }
  | Already_present of { goal_id : string; keeper_name : string }
  | Enqueue_failed of { goal_id : string; keeper_name : string; detail : string }

let sole_assigned_keeper goal_id =
  Keeper_registry.all ()
  |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
       if List.mem goal_id entry.meta.active_goal_ids then Some entry.name else None)
  |> List.sort_uniq String.compare
  |> function
  | [ keeper_name ] -> Some keeper_name
  | [] | _ :: _ :: _ -> None

let target_keeper_name ~completing_agent_name ~goal_id =
  match Keeper_identity.canonical_keeper_name_from_agent_name completing_agent_name with
  | Some keeper_name -> Some keeper_name
  | None -> sole_assigned_keeper goal_id

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

let enqueue_if_ready ~config ~completing_agent_name ~task_id =
  match
    Masc_task_handlers.Task_goal_reconciliation.ready_after_terminal_task
      ~config
      ~task_id
  with
  | None -> Not_ready
  | Some { goal_id; triggering_task_id } ->
    (match target_keeper_name ~completing_agent_name ~goal_id with
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
         { gr_goal_id = goal_id; gr_triggering_task_id = triggering_task_id }
       in
       let stimulus : Keeper_event_queue.stimulus =
         { post_id = Keeper_event_queue.goal_reconciliation_ready_post_id ready
         ; urgency = Keeper_event_queue.Immediate
         ; arrived_at = Time_compat.now ()
         ; payload = Keeper_event_queue.Goal_reconciliation_ready ready
         }
       in
       let already_present =
         match
           Keeper_event_queue_persistence.load_pending_result
             ~base_path:config.base_path
             ~keeper_name
         with
         | Ok queue ->
           Keeper_event_queue.to_list queue
           |> List.exists (fun pending ->
                Keeper_event_queue.stimulus_identity_equal pending stimulus)
         | Error _ -> false
       in
       match
         Keeper_registry_event_queue.enqueue_durable_result
           ~base_path:config.base_path
           keeper_name
           stimulus
       with
       | Ok () ->
         if already_present
         then Already_present { goal_id; keeper_name }
         else (
           wake_keeper ~base_path:config.base_path keeper_name goal_id;
           Enqueued { goal_id; keeper_name })
       | Error detail ->
         Log.Keeper.error
           "goal reconciliation durable enqueue failed keeper=%s goal_id=%s \
            triggering_task_id=%s: %s"
           keeper_name
           goal_id
           triggering_task_id
           detail;
         Enqueue_failed { goal_id; keeper_name; detail })
