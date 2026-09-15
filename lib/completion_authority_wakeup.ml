(** Durable rejection delivery to the producer Keeper after a system completion
    authority rejects submitted evidence. *)

type delivery =
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

let wake_rejected_producer
      ~(config : Workspace_utils_backend_setup.config)
      ~producer
      ~task_id
      ~verification_id
      ~reason
      ~authority
  =
  match Keeper_producer_route.resolve ~config producer with
  | Error detail ->
    Producer_identity_lookup_failed { producer; task_id; detail }
  | Ok Keeper_producer_route.No_keeper ->
    Unroutable_producer { producer; task_id }
  | Ok (Keeper_producer_route.Keeper keeper_name) ->
    let rejection : Keeper_event_queue.completion_authority_rejection =
      { car_task_id = task_id
      ; car_verification_id = verification_id
      ; car_reason = reason
      ; car_authority = authority
      }
    in
    let stimulus : Keeper_event_queue.stimulus =
      { post_id = Keeper_event_queue.completion_authority_rejection_post_id rejection
      ; urgency = Keeper_event_queue.Immediate
      ; arrived_at = Time_compat.now ()
      ; payload = Keeper_event_queue.Completion_authority_rejected rejection
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
       (* The producer Keeper owns current-task projection. Its next cycle
          reconciles that projection from the committed backlog before it
          renders this durable rejection stimulus. Keeping that mutation out
          of the authority-to-queue boundary means a best-effort Keeper
          projection can never prevent durable delivery or the live wake. *)
       (try
          match
            Keeper_registry.wakeup_running
              ~intent:Keeper_registry.Reactive_signal
              ~base_path:config.base_path
              keeper_name
          with
          | Keeper_registry.Signaled -> Signaled { keeper_name }
          | ( Keeper_registry.Deferred_unregistered
            | Keeper_registry.Deferred_not_running _
            | Keeper_registry.Deferred_lifecycle _ ) as wakeup ->
            Durable_deferred { keeper_name; wakeup }
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Durable_wake_failed
            { keeper_name; detail = Printexc.to_string exn }))


type recovery_report = { delivered : int; unroutable : int; retained : int }

(* A rejection with no Keeper queue leaves the Task held by a producer that
   will never act on it again. Ending the delivery obligation alone (#36461)
   stopped the retry but left the Task in [InProgress] for good, so the Task is
   put back before the obligation is acknowledged. Release-then-acknowledge is
   the safe order: a crash between the two replays the release, which reads the
   status again and does nothing the second time, while acknowledging first
   would strand the Task with nothing left to retry. *)
let release_unroutable_task ~config (item : Masc_domain.pending_completion_rejection) =
  match
    Workspace_task.release_unroutable_rejected_task_r
      config
      ~authority:item.authority
      ~task_id:item.task_id
      ~producer:item.producer
      ~verification_id:item.verification_id
      ~reason:item.reason
      ()
  with
  | Error error -> Error (Masc_domain.masc_error_to_string error)
  | Ok (Workspace_task.Released { previous_status; backlog_version; post_commit_errors })
    ->
    List.iter
      (fun detail ->
         Log.Misc.warn
           "completion rejection release projection failed task_id=%s detail=%s"
           item.task_id detail)
      post_commit_errors;
    Ok
      (`Released
        (Masc_domain.task_status_to_string previous_status, backlog_version))
  | Ok (Workspace_task.Not_held_by_producer { task_status }) ->
    Ok (`Already_moved (Masc_domain.task_status_to_string task_status))
  | Ok Workspace_task.Task_absent -> Ok `Task_absent
;;

let reconcile_pending ~config =
  match Workspace_task_rejection_outbox.pending config with
  | Error detail -> Error detail
  | Ok pending ->
    let deliver report (item : Masc_domain.pending_completion_rejection) =
      let queued =
        match wake_rejected_producer ~config ~producer:item.producer
                ~task_id:item.task_id ~verification_id:item.verification_id
                ~reason:item.reason ~authority:item.authority with
        | Signaled _ -> Ok `Queued
        | Durable_deferred { keeper_name; _ } ->
          Log.Misc.warn
            "completion repair queued; Keeper wake deferred task_id=%s keeper=%s"
            item.task_id keeper_name;
          Ok `Queued
        | Durable_wake_failed { keeper_name; detail } ->
          Log.Misc.error
            "completion repair queued; live wake failed task_id=%s keeper=%s detail=%s"
            item.task_id keeper_name detail;
          Ok `Queued
        (* No Keeper carries this name and none has a meta file under it, so
           no queue will ever be read for it: an MCP client that submitted
           the Task is the usual producer here. Retrying cannot create one.
           The verdict and its reason already stand on the Task (the rejection
           handoff committed with it), so the obligation ends here instead of
           being retried every interval for good — and the Task goes back to
           the backlog, because the producer named on it cannot act again. *)
        | Unroutable_producer _ -> release_unroutable_task ~config item
        | Producer_identity_lookup_failed { detail; _ }
        | Durable_queue_failed { detail; _ } -> Error detail
      in
      let acknowledged =
        match queued with
        | Error _ as error -> error
        | Ok outcome ->
          Result.map
            (fun () -> outcome)
            (Workspace_task_rejection_outbox.acknowledge config
               ~task_id:item.task_id ~verification_id:item.verification_id)
      in
      match acknowledged with
      | Ok `Queued ->
        Log.Misc.info
          "completion repair delivered task_id=%s verification_id=%s producer=%s"
          item.task_id item.verification_id item.producer;
        { report with delivered = report.delivered + 1 }
      | Ok (`Released (previous_status, backlog_version)) ->
        Log.Misc.warn
          "completion rejection has no Keeper to deliver to; the task returned \
           to the backlog task_id=%s verification_id=%s producer=%s from=%s \
           version=%d"
          item.task_id item.verification_id item.producer previous_status
          backlog_version;
        { report with unroutable = report.unroutable + 1 }
      | Ok (`Already_moved task_status) ->
        Log.Misc.warn
          "completion rejection has no Keeper to deliver to; the task already \
           moved on task_id=%s verification_id=%s producer=%s status=%s"
          item.task_id item.verification_id item.producer task_status;
        { report with unroutable = report.unroutable + 1 }
      | Ok `Task_absent ->
        Log.Misc.warn
          "completion rejection has no Keeper to deliver to; the task no longer \
           exists task_id=%s verification_id=%s producer=%s"
          item.task_id item.verification_id item.producer;
        { report with unroutable = report.unroutable + 1 }
      | Error detail ->
        Log.Misc.error
          "completion repair remains pending task_id=%s verification_id=%s producer=%s detail=%s"
          item.task_id item.verification_id item.producer detail;
        { report with retained = report.retained + 1 }
    in
    Ok (List.fold_left deliver { delivered = 0; unroutable = 0; retained = 0 } pending)
;;
