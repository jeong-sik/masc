(** See [keeper_goal_stagnation_wake.mli] for the contract. *)

let stagnation_of_goal ~(now : float) ~(threshold_sec : float)
    (goal : Goal_store.goal) : Keeper_event_queue.goal_stagnation option =
  if not (Goal_phase.admits_self_directed_progress goal.phase)
  then None
  else
    match Masc_domain.parse_iso8601_opt goal.updated_at with
    | None ->
      (* Unparseable timestamp: staleness is undecidable, so do not wake.
         Fail closed rather than treat the goal as infinitely stale. *)
      None
    | Some updated_ts ->
      if now -. updated_ts < threshold_sec
      then None
      else
        Some
          { Keeper_event_queue.gs_goal_id = goal.id
          ; gs_stale_since = goal.updated_at
          ; gs_goal_title = goal.title
          }

let enqueue_goal_stagnation_wakes
    ~(config : Workspace.config)
    ~(keeper_name : string)
    ~(active_goal_ids : string list)
    ~(now : float)
    ~(threshold_sec : float)
    () : string list =
  List.filter_map
    (fun goal_id ->
      match Goal_store.get_goal config ~goal_id with
      | None -> None
      | Some goal ->
        (match stagnation_of_goal ~now ~threshold_sec goal with
         | None -> None
         | Some gs ->
           (* Pin [arrived_at] to the episode timestamp (the goal's
              updated_at) so the reaction-ledger stimulus id is stable across
              scans of the same stale episode. A re-stale goal carries a new
              updated_at and so a new episode id. Falls back to [now] only
              when the timestamp is unparseable, which [stagnation_of_goal]
              has already excluded. *)
           let episode_ts =
             Option.value
               (Masc_domain.parse_iso8601_opt gs.gs_stale_since)
               ~default:now
           in
           let stimulus : Keeper_event_queue.stimulus =
             { post_id = Keeper_event_queue.goal_stagnation_post_id gs
             ; urgency = Keeper_event_queue.Normal
             ; arrived_at = episode_ts
             ; payload = Keeper_event_queue.Goal_stagnation gs
             }
           in
           (* Fire once per episode. The live-queue [enqueue_if_missing]
              collapses repeat scans while the stimulus is still queued; this
              ledger gate covers re-scans after the keeper already took a turn
              on the episode, so an unadvanced goal does not nag every scan. *)
           let stimulus_id =
             Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus
           in
           let evidence =
             Keeper_reaction_ledger.event_queue_reaction_evidence
               ~base_path:config.base_path
               ~keeper_name
               ~stimulus_id
           in
           if evidence.turn_started_seen
           then None
           else begin
             Keeper_registry_event_queue.enqueue
               ~base_path:config.base_path
               keeper_name
               stimulus;
             (match
                Keeper_registry.get ~base_path:config.base_path keeper_name
              with
              | Some entry when entry.phase = Keeper_state_machine.Running ->
                let (_ : Keeper_registry.wakeup_outcome) =
                  Keeper_registry.wakeup
                    ~intent:Keeper_registry.Goal_signal
                    ~base_path:config.base_path
                    keeper_name
                in
                ()
              | Some entry ->
                Log.Keeper.info
                  "goal stagnation wake queued without fiber wake keeper=%s \
                   phase=%s goal_id=%s"
                  keeper_name
                  (Keeper_state_machine.phase_to_string entry.phase)
                  goal_id
              | None ->
                Log.Keeper.info
                  "goal stagnation wake persisted for unregistered keeper=%s \
                   goal_id=%s"
                  keeper_name
                  goal_id);
             Some goal_id
           end))
    active_goal_ids
