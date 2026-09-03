let quarantine_undelivered ~base_path ~keeper_name ~event_id ~detail =
  match
    Keeper_external_attention.mark_quarantined
      ~base_path
      ~keeper_name
      ~event_ids:[ event_id ]
      ~reason:("connector_attention_enqueue_failed: " ^ detail)
      ()
  with
  | Ok () -> ()
  | Error err ->
    Log.Server.error
      "connector attention quarantine after refused enqueue failed (keeper=%s \
       event=%s): %s"
      keeper_name
      event_id
      err
;;

let deliver ~base_path ~keeper_name ~event_id ~channel =
  let stimulus =
    { Keeper_event_queue.post_id = event_id
    ; urgency = Keeper_event_queue.Low
    ; arrived_at = Unix.gettimeofday ()
      (* NDT-OK: stimulus receipt time, used only for ordering/age *)
    ; payload = Keeper_event_queue.Connector_attention { event_id; channel }
    }
  in
  match
    Keeper_registry_event_queue.enqueue_stimulus_durable_result
      ~base_path
      keeper_name
      stimulus
  with
  | Keeper_registry_event_queue.Stimulus_storage_error detail ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string KeepaliveSignalFailures)
      ~labels:
        [ ("keeper", keeper_name); ("phase", "connector_attention_delivery") ]
      ();
    Log.Server.error
      "connector attention durable delivery failed (keeper=%s event=%s): %s"
      keeper_name
      event_id
      detail;
    quarantine_undelivered ~base_path ~keeper_name ~event_id ~detail
  | Keeper_registry_event_queue.Stimulus_enqueued
  | Keeper_registry_event_queue.Stimulus_already_present ->
    (match
       Keeper_registry.wakeup_running
         ~intent:Keeper_registry.Reactive_signal
         ~base_path
         keeper_name
     with
     | Keeper_registry.Signaled -> ()
     | Keeper_registry.Deferred_unregistered ->
       Log.Server.info
         "connector attention durably queued; wake deferred for unregistered \
          Keeper (keeper=%s event=%s)"
         keeper_name
         event_id
     | Keeper_registry.Deferred_not_running phase ->
       Log.Server.info
         "connector attention durably queued; wake deferred by Keeper phase \
          (keeper=%s event=%s phase=%s)"
         keeper_name
         event_id
         (Keeper_state_machine.phase_to_string phase)
     | Keeper_registry.Deferred_lifecycle denial ->
       Log.Server.info
         "connector attention durably queued; wake deferred by lifecycle \
          (keeper=%s event=%s reason=%s)"
         keeper_name
         event_id
         (Keeper_lifecycle_admission.autonomous_denial_to_wire denial))
;;
