(** Stay-silent loop recovery helpers for the unified keeper turn. *)

let recovery_stimulus ~now ~keeper_name ~streak ~threshold =
  let payload =
    `Assoc
      [ "source", `String "stay_silent_recovery"
      ; "keeper", `String keeper_name
      ; "streak", `Int streak
      ; "threshold", `Int threshold
      ; ( "message"
        , `String
            "stay_silent loop threshold crossed; run a recovery cycle instead of \
             remaining silent" )
      ]
    |> Yojson.Safe.to_string
  in
  { Keeper_event_queue.post_id = "stay-silent-loop:" ^ keeper_name
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = now
  ; payload
  }
;;

let mark_loop_detected ~(config : Coord.config) meta ~streak ~threshold =
  let detail =
    Printf.sprintf
      "stay_silent loop detected: streak=%d threshold=%d; recovery stimulus queued"
      streak
      threshold
  in
  let failure_reason =
    Keeper_registry.Tool_required_unsatisfied
      { code = "stay_silent_loop"; detail }
  in
  Keeper_registry.set_failure_reason
    ~base_path:config.base_path
    meta.Keeper_types.name
    (Some failure_reason);
  let stimulus =
    recovery_stimulus
      ~now:(Time_compat.now ())
      ~keeper_name:meta.Keeper_types.name
      ~streak
      ~threshold
  in
  Keeper_registry.enqueue_event
    ~base_path:config.base_path
    meta.Keeper_types.name
    stimulus;
  Keeper_registry.wakeup ~base_path:config.base_path meta.Keeper_types.name;
  (try
     Keeper_reaction_ledger.record_event_queue_stimulus
       ~base_path:config.base_path
       ~keeper_name:meta.Keeper_types.name
       stimulus
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Keeper.warn
       "%s: failed to persist stay-silent recovery stimulus in reaction ledger: %s"
       meta.Keeper_types.name
       (Printexc.to_string exn));
  Log.Keeper.warn
    "%s: stay_silent loop escalated to blocker and recovery stimulus \
     (streak=%d threshold=%d)"
    meta.Keeper_types.name
    streak
    threshold;
  Keeper_types.map_runtime
    (fun rt ->
       { rt with
         last_blocker =
           Some
             (Keeper_meta_contract.blocker_info_of_class
                ~detail
                Keeper_types.Stay_silent_loop)
       })
    meta
;;

let clear_if_recovered ~(config : Coord.config) meta ~previous_streak ~was_latched =
  if was_latched then begin
    match Keeper_registry.get ~base_path:config.base_path meta.Keeper_types.name with
    | Some { Keeper_registry.last_failure_reason =
               Some (Keeper_registry.Tool_required_unsatisfied { code; _ })
           ; _
           }
      when String.equal code "stay_silent_loop" ->
      Keeper_registry.set_failure_reason
        ~base_path:config.base_path
        meta.Keeper_types.name
        None;
      Log.Keeper.info
        "%s: stay_silent loop recovered after non-silent turn \
         (previous_streak=%d)"
        meta.Keeper_types.name
        previous_streak
    | _ -> ()
  end;
  match meta.Keeper_types.runtime.last_blocker with
  | Some { Keeper_meta_contract.klass = Keeper_types.Stay_silent_loop; _ } ->
    Keeper_types.map_runtime (fun rt -> { rt with last_blocker = None }) meta
  | _ -> meta
;;
