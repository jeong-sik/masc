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
(* Which release failures can be ended here rather than kept for the next
   interval. Two conditions, and both have to hold.

   It has to be permanent: #36461 removed a retry that could never succeed,
   and a release that fails the same way every interval would put it back.

   It also has to be *dischargeable*, which is the condition the first pass
   of this got wrong. Ending an obligation means acknowledging it, and
   {!Workspace_task_rejection_outbox.acknowledge} takes the same lock and
   makes the same backlog write the release just failed at. So a failure that
   says the backlog cannot be read, written or locked cannot be ended either:
   the only thing left to do with it is keep it, which is also the right thing.
   [NotInitialized] was in the permanent set and is wrong twice over — the
   acknowledgement would fail for the same reason, and an uninitialised
   workspace fails the outbox read long before a release is attempted.

   That leaves the two that fail while the backlog is still writable: an
   obligation carrying a task id that is not a task id, and one carrying an
   authority with no identity. Neither can change while the obligation stands.
   Both are close to unreachable — the verdict path refuses a blank authority
   before the obligation exists — which is the point: if one does appear, it
   appeared through a route nobody expected, and retrying it forever is how
   that stays invisible. *)
let release_failure_is_permanent (error : Masc_domain.masc_error) =
  match error with
  | Masc_domain.System system ->
    (match system with
     | Masc_domain.System_error.ValidationError _ -> true
     (* Every one of these says the backlog itself is unavailable, so the
        acknowledgement that would end the obligation fails with it. *)
     | Masc_domain.System_error.NotInitialized
     | Masc_domain.System_error.IoError _
     | Masc_domain.System_error.StorageError _
     | Masc_domain.System_error.LockContention _
     | Masc_domain.System_error.InvalidJson _
     | Masc_domain.System_error.InvalidFilePath _
     | Masc_domain.System_error.AlreadyInitialized -> false)
  | Masc_domain.Task task ->
    (match task with
     | Masc_domain.Task_error.InvalidId _ -> true
     | Masc_domain.Task_error.NotFound _
     | Masc_domain.Task_error.AlreadyClaimed _
     | Masc_domain.Task_error.NotClaimed _
     | Masc_domain.Task_error.InvalidState _
     | Masc_domain.Task_error.VerificationSuperseded _ -> false)
  (* Spelled out rather than left to a catch-all: the release cannot raise
     these today, and a change that makes it raise one has to decide here
     instead of inheriting "retry forever". *)
  | Masc_domain.Agent _
  | Masc_domain.Auth _
  | Masc_domain.RateLimitExceeded _
  | Masc_domain.CacheError _ -> false
;;

let release_unroutable_task ~config (item : Masc_domain.pending_completion_rejection) =
  (* Asked again inside the backlog lock: the routing answer above was read
     before it, and a Keeper meta can land at the producer's name in between.
     Through the reader that writes nothing — [resolve] repairs an off-canon
     meta in place, and an fsync of another Keeper's file under a lease-backed
     lock widens the window where the lease expires while still held. *)
  let still_unroutable () =
    Ok (Keeper_producer_route.has_no_queue_without_writing ~config item.producer)
  in
  match
    Workspace_task.release_unroutable_rejected_task_r
      config
      ~authority:item.authority
      ~task_id:item.task_id
      ~producer:item.producer
      ~verification_id:item.verification_id
      ~reason:item.reason
      ~still_unroutable
      ()
  with
  | Error error when release_failure_is_permanent error ->
    Log.Misc.error
      "completion rejection cannot be released and retrying cannot change that \
       task_id=%s verification_id=%s producer=%s detail=%s"
      item.task_id
      item.verification_id
      item.producer
      (Masc_domain.masc_error_to_string error);
    Ok `Release_refused
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
  (* A queue exists after all. Keep the obligation: the next interval routes
     to that Keeper and delivers what this one could not. *)
  | Ok Workspace_task.Producer_became_routable ->
    Error "a Keeper queue appeared at the producer's name; delivering next interval"
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
      | Ok `Release_refused ->
        (* Already logged as an error with the reason at the refusal. *)
        { report with unroutable = report.unroutable + 1 }
      | Error detail ->
        Log.Misc.error
          "completion repair remains pending task_id=%s verification_id=%s producer=%s detail=%s"
          item.task_id item.verification_id item.producer detail;
        { report with retained = report.retained + 1 }
    in
    Ok (List.fold_left deliver { delivered = 0; unroutable = 0; retained = 0 } pending)
;;
