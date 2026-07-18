(** See [keeper_goal_assignment_wake.mli] for the contract. *)

let added_goal_ids ~(old_ids : string list) ~(new_ids : string list) :
    string list =
  List.filter (fun id -> not (List.mem id old_ids)) new_ids

let enqueue_goal_assigned_wakes
    ~(config : Workspace.config)
    ~(keeper_name : string)
    ~(assigned_by : string)
    ~(old_ids : string list)
    ~(new_ids : string list)
    () : (string list, string) result =
  let added = added_goal_ids ~old_ids ~new_ids in
  let rec enqueue committed = function
    | [] -> Ok (List.rev committed)
    | goal_id :: rest ->
      let title =
        (* Unknown ids are rejected upstream (turn_up validates against
           Goal_store); this fallback only labels a race where the goal was
           deleted between validation and enqueue. *)
        match Goal_store.get_goal config ~goal_id with
        | Some { Goal_store.title; _ } -> title
        | None -> goal_id
      in
      let ga : Keeper_event_queue.goal_assignment =
        { ga_goal_id = goal_id
        ; ga_goal_title = title
        ; ga_assigned_by = assigned_by
        }
      in
      let stimulus : Keeper_event_queue.stimulus =
        { post_id = Keeper_event_queue.goal_assignment_post_id ga
        ; urgency = Keeper_event_queue.Normal
        ; arrived_at = Time_compat.now ()
        ; payload = Keeper_event_queue.Goal_assigned ga
        }
      in
      (match
         Keeper_registry_event_queue.enqueue_stimulus_durable_result
           ~base_path:config.base_path
           keeper_name
           stimulus
       with
       | Keeper_registry_event_queue.Stimulus_storage_error detail ->
         Error
           (Printf.sprintf
              "goal assignment durable admission failed keeper=%S goal_id=%S: %s"
              keeper_name
              goal_id
              detail)
       | Keeper_registry_event_queue.Stimulus_enqueued _
       | Keeper_registry_event_queue.Stimulus_already_present _ ->
         (match
            Keeper_registry.wakeup_running
              ~intent:Keeper_registry.Goal_signal
              ~base_path:config.base_path
              keeper_name
          with
          | Keeper_registry.Signaled -> ()
          | Keeper_registry.Deferred_unregistered ->
            Log.Keeper.info
              "goal assignment wake persisted for unregistered keeper=%s goal_id=%s"
              keeper_name
              goal_id
          | Keeper_registry.Deferred_not_running phase ->
            Log.Keeper.info
              "goal assignment wake deferred by registry phase contract keeper=%s \
               phase=%s goal_id=%s"
              keeper_name
              (Keeper_state_machine.phase_to_string phase)
              goal_id
          | Keeper_registry.Deferred_lifecycle denial ->
            Log.Keeper.info
              "goal assignment wake deferred by lifecycle keeper=%s reason=%s \
               goal_id=%s"
              keeper_name
              (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
              goal_id);
         enqueue (goal_id :: committed) rest)
  in
  enqueue [] added
