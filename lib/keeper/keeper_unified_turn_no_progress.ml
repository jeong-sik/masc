(** No-progress loop pause helpers for the unified keeper turn. *)

let failure_reason_code = "no_progress_loop"

let recovery_post_id ~keeper_name = "no-progress-loop:" ^ keeper_name

let mark_loop_detected ~(config : Workspace.config) meta ~streak ~threshold =
  let detail =
    Printf.sprintf
      "no_progress loop detected: streak=%d threshold=%d; auto-paused after repeated no-evidence turns; operator resume clears the no-progress latch"
      streak
      threshold
  in
  let failure_reason =
    Keeper_registry.Provider_runtime_error
      { code = failure_reason_code
      ; detail
      ; provider_id = None
      ; http_status = None
      ; runtime_id = None
      ; reason = None
      }
  in
  Keeper_registry.set_failure_reason
    ~base_path:config.base_path
    meta.Keeper_meta_contract.name
    (Some failure_reason);
  let blocked_meta =
    Keeper_meta_contract.map_runtime
    (fun rt ->
       { rt with
         last_blocker =
           Some
             (Keeper_meta_contract.blocker_info_of_class
                ~detail
                Keeper_meta_contract.No_progress_loop)
       })
    meta
  in
  match
    Keeper_supervisor_pause_policy.handle_auto_pause_from_meta
      ~config
      ~meta:blocked_meta
      ~reason_tag:failure_reason_code
      ~lifecycle_detail:detail
      ~log_message:
        (Printf.sprintf
           "no_progress loop escalated to blocker and operator-resume pause \
            (streak=%d threshold=%d)"
           streak
           threshold)
      ~blocker_class:(Some Keeper_meta_contract.No_progress_loop)
      ~resume_policy:Keeper_supervisor_pause_policy.Manual_resume_required
      ()
  with
  | Ok paused_meta ->
    Log.Keeper.warn
      "%s: no_progress loop escalated to blocker and operator-resume pause \
       (streak=%d threshold=%d)"
      meta.name
	      streak
	      threshold;
	    paused_meta
  | Error pause_err ->
    (* RFC-0246 P2: a latched keeper must not receive a synthetic
       no-progress recovery wake. The stimulus carries no actionable data, so
       queuing it after a failed pause just lets the event-queue override force
       another empty turn (pause-fail -> queue -> no-progress -> pause-fail).
       Pass [~bypass_tombstone:false] so an automatic wake stays suppressed;
       an operator can still force-resume. *)
    Keeper_registry.wakeup ~bypass_tombstone:false ~base_path:config.base_path meta.name;
    Log.Keeper.error
      "%s: no_progress loop pause sync failed: %s; automatic recovery wake \
       suppressed (streak=%d threshold=%d)"
      meta.name
      pause_err
      streak
      threshold;
    blocked_meta
;;

let clear_if_recovered ~(config : Workspace.config) meta ~previous_streak ~was_latched =
  if was_latched then begin
    match Keeper_registry.get ~base_path:config.base_path meta.Keeper_meta_contract.name with
    | Some { Keeper_registry.last_failure_reason =
               Some (Keeper_registry.Provider_runtime_error { code; _ })
           ; _
           }
      when String.equal code failure_reason_code ->
      Keeper_registry.set_failure_reason
        ~base_path:config.base_path
        meta.name
        None;
      Log.Keeper.info
        "%s: no_progress loop recovered after progress turn \
         (previous_streak=%d)"
        meta.name
        previous_streak
    | _ -> ()
  end;
  match meta.runtime.last_blocker with
  | Some { Keeper_meta_contract.klass = Keeper_meta_contract.No_progress_loop; _ } ->
    Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
  | _ -> meta
;;

let clear_for_operator_resume ~base_path meta =
  let keeper_name = meta.Keeper_meta_contract.name in
  (* KLV-2 (RFC-keeper-liveness-ssot §3): dropping the recovery stimulus
     from the event queue is best-effort bookkeeping, not a precondition
     for resume. It used to gate the critical clears below (detector
     latch, registry failure_reason, meta.last_blocker) behind an [Error]
     return — a transient disk failure on this cosmetic step permanently
     blocked every operator resume path (dashboard directive, masc_keeper_up,
     keepalive persist all treat [Error] here as "resume failed"), since
     Manual_resume_required pauses have no other recovery route. Log and
     continue with an empty stimulus list instead of failing the resume. *)
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
  let was_latched = Keeper_no_progress_loop_detector.is_latched ~keeper_name in
  Keeper_no_progress_loop_detector.reset ~keeper_name;
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
    was_latched
    || cleared_failure_reason
    || cleared_meta_blocker
    || dropped_recovery_stimuli <> []
  then
    Log.Keeper.info
      "%s: operator resume cleared no_progress loop latch/blocker (latched=%b failure_reason=%b meta_blocker=%b dropped_recovery_stimuli=%d)"
      keeper_name
      was_latched
      cleared_failure_reason
      cleared_meta_blocker
      (List.length dropped_recovery_stimuli);
  Ok
    (if cleared_meta_blocker then
       Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
     else meta)
;;
