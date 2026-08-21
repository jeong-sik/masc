type enqueue_outcome =
  | Not_ready
  | Backlog_read_failed of { detail : string }
  | No_keeper_target of { goal_id : string }
  | Keeper_target_lookup_failed of { goal_id : string; detail : string }
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

(* A wake is a message into a keeper's queue, not a contract, so several
   recipients is an ordinary outcome rather than a condition to fail on.
   Several keepers carrying one goal is what a collaboration mission looks
   like, and every one of them wants to know its Task finished -- so every one
   of them hears. Nothing narrows the list: narrowing would need a declared
   responsible keeper, and a Goal names none. *)

(* A Goal names no keeper, so the wake goes to whoever just finished the Task
   that moved it. That is the one identity the event actually carries. *)
let target_keeper_names ~config ~completing_agent_name ~goal_id =
  ignore goal_id;
  match exact_producer_keeper_name ~config ~completing_agent_name with
  | Ok (Some keeper_name) -> Ok [ keeper_name ]
  | Ok None -> Ok []
  | Error detail -> Error detail

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
  match target_keeper_names ~config ~completing_agent_name ~goal_id with
     | Error detail ->
       Log.Keeper.error
         "goal reconciliation Keeper target lookup failed goal_id=%s \
          triggering_task_id=%s completing_agent=%s detail=%s"
         goal_id
         triggering_task_id
         completing_agent_name
         detail;
       Keeper_target_lookup_failed { goal_id; detail }
     | Ok [] ->
       Log.Keeper.warn
         "goal reconciliation ready but nobody carries the Goal goal_id=%s \
          triggering_task_id=%s completing_agent=%s"
         goal_id
         triggering_task_id
         completing_agent_name;
       No_keeper_target { goal_id }
     | Ok keeper_names ->
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
       let enqueue_one keeper_name =
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
       in
       let outcomes = List.map enqueue_one keeper_names in
       (* Every recipient is enqueued; the caller's single outcome reports the
          strongest one so a partial storage failure never reads as total
          success. Enqueued outranks Already_present, which outranks a failure. *)
       let rank = function
         | Enqueued _ -> 0
         | Already_present _ -> 1
         | _ -> 2
       in
       (match List.stable_sort (fun a b -> Int.compare (rank a) (rank b)) outcomes with
        | best :: _ -> best
        | [] -> No_keeper_target { goal_id })
;;

let enqueue_if_ready ~config ~completing_agent_name ~task_id =
  match
    Masc_task_handlers.Task_goal_reconciliation.ready_after_terminal_task
      ~config
      ~task_id
  with
  | Error detail -> Backlog_read_failed { detail }
  | Ok None -> Not_ready
  | Ok (Some ready) -> enqueue_ready ~config ~completing_agent_name ready
;;

let reconcile_startup ~config =
  match Masc_task_handlers.Task_goal_reconciliation.ready_executing_goals ~config with
  | Error detail ->
    Log.Keeper.error "goal reconciliation startup backlog read failed: %s" detail;
    { ready_count = 0
    ; enqueued_count = 0
    ; already_present_count = 0
    ; unresolved_count = 0
    ; failed_count = 1
    }
  | Ok ready ->
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
       | Backlog_read_failed _ ->
         { summary with failed_count = summary.failed_count + 1 }
       | Enqueued _ ->
         { summary with enqueued_count = summary.enqueued_count + 1 }
       | Already_present _ ->
         { summary with
           already_present_count = summary.already_present_count + 1
         }
       | No_keeper_target _ ->
         { summary with unresolved_count = summary.unresolved_count + 1 }
       | Keeper_target_lookup_failed _ ->
         { summary with failed_count = summary.failed_count + 1 }
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
