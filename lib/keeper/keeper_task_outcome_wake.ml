(** Durable approval delivery to the producer Keeper after a completion
    authority (system LLM or HITL) approves its submitted evidence.

    This is the approval twin of [Completion_authority_wakeup]: a rejection
    has always woken the producer with a typed stimulus, but an approval
    ended the loop in silence — the Board receipt is Unlisted and the
    producer's current-task projection is already cleared at submission, so
    nothing told the producer its task closed (#25868).

    Delivery follows the same fail-closed contract as
    [Keeper_delegate_completion_wake]: the typed stimulus is committed to the
    producer's durable queue first and only then is the live wake attempted.
    The live wake is a hint — it reaches only a [Running] Keeper; a paused or
    unregistered producer reads the committed stimulus on its next admitted
    turn, and its failure is logged rather than raised. Eio structural
    cancellation is re-raised. *)

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

let producer_keeper_name
      ~(config : Workspace_utils_backend_setup.config)
      producer
  =
  match
    Keeper_registry_lookup.find_by_name_in_base_path
      ~base_path:config.Workspace.base_path
      producer
  with
  | Some entry -> Ok (Some entry.name)
  | None ->
    (match Keeper_meta_store.read_meta config producer with
     | Ok (Some _) -> Ok (Some producer)
     | Ok None -> Ok None
     | Error detail -> Error detail)
;;

let wake_approved_producer
      ~(config : Workspace_utils_backend_setup.config)
      ~producer
      ~task_id
      ~verification_id
      ~authority
  =
  match producer_keeper_name ~config producer with
  | Error detail ->
    Producer_identity_lookup_failed { producer; task_id; detail }
  | Ok None ->
    Unroutable_producer { producer; task_id }
  | Ok (Some keeper_name) ->
    let outcome : Keeper_event_queue.task_outcome =
      { to_task_id = task_id
      ; to_verification_id = verification_id
      ; to_producer = producer
      ; to_authority = authority
      }
    in
    let stimulus : Keeper_event_queue.stimulus =
      { post_id = Keeper_event_queue.task_outcome_post_id outcome
      ; urgency = Keeper_event_queue.Immediate
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
       (* [Immediate] for the same reason [Keeper_composition_completion_wake]
          gives: the producer is waiting on a verdict it asked for, which is
          not the kind of event Board activity is. The task is already Done
          and the producer's projection already cleared, so a queued row
          behind a long Board backlog would deliver the news to a Keeper that
          has moved on without knowing why. *)
       (try
          match
            Keeper_registry.wakeup_running
              ~intent:Keeper_registry.Reactive_signal
              ~base_path:config.base_path
              keeper_name
          with
          | Signaled -> Signaled { keeper_name }
          | ( Deferred_unregistered
            | Deferred_not_running _
            | Deferred_lifecycle _ ) as wakeup ->
            Durable_deferred { keeper_name; wakeup }
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Durable_wake_failed
            { keeper_name; detail = Printexc.to_string exn }))
