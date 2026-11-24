type delivery =
  | Queued_for_later of { keeper_name : string }
  | Signaled of { keeper_name : string }
  | Durable_deferred of {
      keeper_name : string;
      wakeup : Keeper_registry.wakeup_outcome;
    }
  | Durable_wake_failed of { keeper_name : string; detail : string }
  | Unroutable_producer of { producer : string; task_id : string }
  | Producer_identity_lookup_failed of {
      producer : string;
      task_id : string;
      detail : string;
    }
  | Durable_queue_failed of { keeper_name : string; detail : string }

let producer_keeper
      ~(config : Workspace_utils_backend_setup.config)
      ~producer
      ~task_id
  =
  match Keeper_producer_route.resolve ~config producer with
  | Error detail ->
    Error (Producer_identity_lookup_failed { producer; task_id; detail })
  | Ok Keeper_producer_route.No_keeper ->
    Error (Unroutable_producer { producer; task_id })
  | Ok (Keeper_producer_route.Keeper keeper_name) -> Ok keeper_name
;;

let wake_producer_keeper ~wake_policy ~notify ~(config : Workspace_utils_backend_setup.config)
      ~keeper_name =
  try
    notify ();
    match wake_policy with
    | Keeper_keepalive_signal.Carry -> Queued_for_later { keeper_name }
    | Keeper_keepalive_signal.At_tick ->
      if Keeper_registry.is_registered ~base_path:config.base_path keeper_name then (
        Keeper_keepalive_signal.notify_at_tick_pending
          ~base_path:config.base_path ~keeper_name ~now:(Time_compat.now ()) ();
        Queued_for_later { keeper_name })
      else Durable_deferred { keeper_name; wakeup = Keeper_registry.Deferred_unregistered }
    | Keeper_keepalive_signal.Now ->
      (match Keeper_registry.wakeup_running
               ~intent:Keeper_registry.Reactive_signal ~base_path:config.base_path keeper_name with
       | Keeper_registry.Signaled -> Signaled { keeper_name }
       | (Keeper_registry.Deferred_unregistered | Keeper_registry.Deferred_not_running _
         | Keeper_registry.Deferred_lifecycle _) as wakeup ->
         Durable_deferred { keeper_name; wakeup })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Durable_wake_failed { keeper_name; detail = Printexc.to_string exn }
;;

let wake_approved_producer
      ~(config : Workspace_utils_backend_setup.config)
      ~producer
      ~task_id
      ~verification_id
      ~authority
  =
  match producer_keeper ~config ~producer ~task_id with
  | Error delivery -> delivery
  | Ok keeper_name ->
    let outcome : Keeper_event_queue.task_outcome =
      { to_task_id = task_id
      ; to_verification_id = verification_id
      ; to_producer = producer
      ; to_authority = authority
      }
    in
    let wake_policy = Keeper_keepalive_signal.task_verdict_wake_policy
        ~input_kind:Keeper_keepalive_signal.Task_outcome_approved authority in
    let stimulus : Keeper_event_queue.stimulus =
      { post_id = Keeper_event_queue.task_outcome_post_id outcome
      ; urgency = Keeper_keepalive_signal.urgency_of_stimulus_wake_policy wake_policy
      ; arrived_at = Time_compat.now ()
      ; payload = Keeper_event_queue.Task_outcome outcome
      }
    in
    (match
       Keeper_registry_event_queue.enqueue_durable_result
         ~base_path:config.base_path
         keeper_name
         stimulus
     with
     | Error detail -> Durable_queue_failed { keeper_name; detail }
     | Ok () ->
       wake_producer_keeper ~wake_policy ~notify:ignore ~config ~keeper_name)
