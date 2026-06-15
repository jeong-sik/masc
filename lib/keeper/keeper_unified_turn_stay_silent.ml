(** Stay-silent loop recovery helpers for the unified keeper turn. *)

(* RFC-0020: the stay-silent recovery stimulus carries no data — the consumer
   only branches on the kind. streak/threshold are recorded in the failure
   reason / blocker detail by the caller, not in the stimulus payload. *)
let recovery_stimulus ~now ~keeper_name =
  { Keeper_event_queue.post_id = "stay-silent-loop:" ^ keeper_name
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = now
  ; payload = Keeper_event_queue.Stay_silent_recovery
  }
;;

let mark_loop_detected ~(config : Workspace.config) meta ~streak ~threshold =
  let detail =
    Printf.sprintf
      "stay_silent loop detected: streak=%d threshold=%d; manual pause applied"
      streak
      threshold
  in
  let failure_reason =
    Keeper_registry.Provider_runtime_error
      { code = "stay_silent_loop"
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
  let stimulus =
    recovery_stimulus ~now:(Time_compat.now ()) ~keeper_name:meta.name
  in
  Keeper_registry_event_queue.enqueue
    ~base_path:config.base_path
    meta.name
    stimulus;
  (try
     Keeper_reaction_ledger.record_event_queue_stimulus
       ~base_path:config.base_path
       ~keeper_name:meta.name
       stimulus
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Keeper.warn
       "%s: failed to persist stay-silent recovery stimulus in reaction ledger: %s"
       meta.name
         (Printexc.to_string exn));
  let blocked_meta =
    Keeper_meta_contract.map_runtime
    (fun rt ->
       { rt with
         last_blocker =
           Some
             (Keeper_meta_contract.blocker_info_of_class
                ~detail
                Keeper_meta_contract.Stay_silent_loop)
       })
    meta
  in
  match
    Keeper_turn_runtime_budget.sync_keeper_paused_state_with_resume_policy
      ~config
      ~meta:blocked_meta
      ~paused:true
      ~resume_policy:Keeper_supervisor_pause_policy.Manual_resume_required
  with
  | Ok paused_meta ->
    Log.Keeper.warn
      "%s: stay_silent loop escalated to blocker and manual pause \
       (streak=%d threshold=%d)"
      meta.name
      streak
      threshold;
    paused_meta
  | Error pause_err ->
    Keeper_registry.wakeup ~base_path:config.base_path meta.name;
    Log.Keeper.error
      "%s: stay_silent loop pause sync failed: %s; recovery stimulus queued \
       instead (streak=%d threshold=%d)"
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
      when String.equal code "stay_silent_loop" ->
      Keeper_registry.set_failure_reason
        ~base_path:config.base_path
        meta.name
        None;
      Log.Keeper.info
        "%s: stay_silent loop recovered after non-silent turn \
         (previous_streak=%d)"
        meta.name
        previous_streak
    | _ -> ()
  end;
  match meta.runtime.last_blocker with
  | Some { Keeper_meta_contract.klass = Keeper_meta_contract.Stay_silent_loop; _ } ->
    Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
  | _ -> meta
;;
