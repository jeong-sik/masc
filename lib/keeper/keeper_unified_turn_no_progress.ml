(** Operator-resume cleanup for the unified keeper turn.

    RFC-0303 Phase 3: the no-progress loop detector is retired, so the turn path
    no longer detects loops or stamps a no-progress blocker
    ([mark_loop_detected] and [clear_if_recovered] are removed). Only
    [clear_for_operator_resume] remains: operator-resume paths (dashboard
    directive, masc_keeper_up, keepalive persist) still call it to clear any
    residual no-progress failure_reason, meta blocker, and queued recovery
    stimulus that may remain on disk from before the detector was retired. It no
    longer touches the (deleted) detector latch. *)

let failure_reason_code = "no_progress_loop"

let recovery_post_id ~keeper_name = "no-progress-loop:" ^ keeper_name

let clear_for_operator_resume ~base_path meta =
  let keeper_name = meta.Keeper_meta_contract.name in
  (* KLV-2 (RFC-keeper-liveness-ssot §3): dropping the recovery stimulus
     from the event queue is best-effort bookkeeping, not a precondition
     for resume. It used to gate the critical clears below (registry
     failure_reason, meta.last_blocker) behind an [Error] return — a transient
     disk failure on this cosmetic step permanently blocked every operator
     resume path (dashboard directive, masc_keeper_up, keepalive persist all
     treat [Error] here as "resume failed"), since Manual_resume_required pauses
     have no other recovery route. Log and continue with an empty stimulus list
     instead of failing the resume. *)
  let dropped_recovery_stimuli =
    match
      Keeper_registry_event_queue.drop_by_post_id
        ~base_path
        keeper_name
        ~post_id:(recovery_post_id ~keeper_name)
    with
    | Ok dropped -> dropped
    | Error msg ->
      Log.Keeper.info
        "%s: operator resume could not drop recovery stimulus (best-effort \
         cleanup; resume proceeds): %s"
        keeper_name
        msg;
      []
  in
  List.iter
    (fun stimulus ->
      try
        Keeper_reaction_ledger.record_event_queue_reaction
          ~base_path
          ~keeper_name
          ~reaction_kind:Keeper_reaction_ledger.Operator_escalation
          stimulus
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          "%s: failed to persist operator-resume no-progress recovery reaction: %s"
          keeper_name
          (Printexc.to_string exn))
    dropped_recovery_stimuli;
  let cleared_failure_reason =
    match Keeper_registry.get ~base_path keeper_name with
    | Some { Keeper_registry.last_failure_reason =
               Some (Keeper_registry.Provider_runtime_error { code; _ })
           ; _
           }
      when String.equal code failure_reason_code ->
      Keeper_registry.set_failure_reason ~base_path keeper_name None;
      true
    | _ -> false
  in
  let cleared_meta_blocker =
    match meta.runtime.last_blocker with
    | Some { Keeper_meta_contract.klass = Keeper_meta_contract.No_progress_loop; _ } ->
      true
    | _ -> false
  in
  if
    cleared_failure_reason
    || cleared_meta_blocker
    || dropped_recovery_stimuli <> []
  then
    Log.Keeper.info
      "%s: operator resume cleared no_progress loop blocker (failure_reason=%b meta_blocker=%b dropped_recovery_stimuli=%d)"
      keeper_name
      cleared_failure_reason
      cleared_meta_blocker
      (List.length dropped_recovery_stimuli);
  Ok
    (if cleared_meta_blocker then
       Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
     else meta)
;;
