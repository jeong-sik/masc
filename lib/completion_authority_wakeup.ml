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
  | Durable_queue_failed of { keeper_name : string; detail : string }

let registered_keeper_name_for_agent ~base_path producer =
  Keeper_registry.all ~base_path ()
  |> List.find_map (fun (entry : Keeper_registry.registry_entry) ->
       if String.equal entry.meta.agent_name producer
       then Some entry.name
       else None)
;;

let producer_keeper_name ~base_path producer =
  match registered_keeper_name_for_agent ~base_path producer with
  | Some keeper_name -> Some keeper_name
  | None -> Keeper_identity.canonical_keeper_name_from_agent_name producer
;;

let wake_rejected_producer
      ~(config : Workspace_utils_backend_setup.config)
      ~producer
      ~task_id
      ~verification_id
      ~reason
      ~authority
  =
  match producer_keeper_name ~base_path:config.base_path producer with
  | None ->
    Unroutable_producer { producer; task_id }
  | Some keeper_name ->
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
