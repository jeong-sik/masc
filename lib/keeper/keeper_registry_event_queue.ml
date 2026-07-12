(** Per-keeper event-queue access.

    Extracted from keeper_registry.ml (lines 1854-1900) as part of the
    godfile decomp campaign. Each [registry_entry] carries its own
    [event_queue : Keeper_event_queue.t Atomic.t].  The durable v2 envelope is
    the mutation authority; these wrappers publish its pending projection to
    that per-entry Atomic only after commit.  No coupling to the central
    registry Atomic state primitive. *)

type lease = Keeper_event_queue_persistence.lease

type requeue_reason = Keeper_event_queue_persistence.requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Retry_after_pacing
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery

type escalation_reason = Keeper_event_queue_persistence.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_operator_required of
      { judge_runtime_id : string
      ; rationale : string
      }

type settlement = Keeper_event_queue_persistence.settlement =
  | Ack
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type transition_receipt = Keeper_event_queue_persistence.transition_receipt
type outbox_entry = Keeper_event_queue_persistence.outbox_entry

type settle_result = Keeper_event_queue_persistence.settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt

let lease_stimuli = Keeper_event_queue_persistence.lease_stimuli
let lease_kind = Keeper_event_queue_persistence.lease_kind

let active_lease_result ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.active_lease_result
      ~base_path
      ~keeper_name:name
;;

let transition_outbox_result ~base_path name =
  Keeper_event_queue_persistence.transition_outbox_result
    ~base_path
    ~keeper_name:name
;;

let mark_transition_projected_result ~base_path name ~transition_id =
  Keeper_event_queue_persistence.mark_transition_projected_result
    ~base_path
    ~keeper_name:name
    ~transition_id
;;

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus then queue else Keeper_event_queue.enqueue queue stimulus
;;

let rec stimulus_with_post_id queue post_id =
  match Keeper_event_queue.dequeue queue with
  | None -> None
  | Some (stimulus, rest) ->
    if String.equal stimulus.post_id post_id
    then Some stimulus
    else stimulus_with_post_id rest post_id
;;

let enqueue_external_decision queue stimulus =
  match stimulus_with_post_id queue stimulus.Keeper_event_queue.post_id with
  | None -> Ok (Keeper_event_queue.enqueue queue stimulus)
  | Some committed
    when Keeper_event_queue.stimulus_identity_equal committed stimulus ->
    Ok queue
  | Some _ ->
    Error
      (Printf.sprintf
         "conflicting durable stimulus already exists for post_id=%s"
         stimulus.post_id)
;;

let requeue_missing_front queue stimuli =
  let missing =
    List.filter (fun stimulus -> not (queue_contains queue stimulus)) stimuli
  in
  Keeper_event_queue.prepend_list missing queue
;;

let publish_pending ~base_path name pending =
  match Keeper_registry.get ~base_path name with
  | None -> ()
  | Some entry -> Atomic.set entry.event_queue pending
;;

let enqueue ~base_path name stimulus =
  if Option.is_none (Keeper_registry.get ~base_path name)
  then
    Log.Keeper.warn
      "registry: enqueue_event name=%s base_path=%s: keeper not registered; persisting stimulus for replay"
      name
      base_path;
  let committed_pending = ref None in
  match
    Keeper_event_queue_persistence.update_checked_result
      ~base_path
      ~keeper_name:name
      ~after_commit:(fun () ->
        match !committed_pending with
        | None -> ()
        | Some pending -> publish_pending ~base_path name pending)
      (fun current ->
         let pending = enqueue_if_missing current stimulus in
         committed_pending := Some pending;
         Ok pending)
  with
  | Ok () -> ()
  | Error message ->
    Log.Keeper.error
      "registry: durable enqueue failed name=%s base_path=%s post_id=%s: %s"
      name
      base_path
      stimulus.Keeper_event_queue.post_id
      message
;;

let enqueue_durable_result ~base_path name stimulus =
  (* Commit the identity-deduplicated durable row before exposing a successful
     delivery result. This path is intentionally separate from [enqueue]: most
     stimuli already have an upstream replay source, while HITL resolution is
     the sole carrier of an operator decision and must fail closed. *)
  let committed_pending = ref None in
  Keeper_event_queue_persistence.update_checked_result
    ~base_path
    ~keeper_name:name
    ~after_commit:(fun () ->
      match !committed_pending with
      | None -> ()
      | Some pending -> publish_pending ~base_path name pending)
    (fun queue ->
       match enqueue_external_decision queue stimulus with
       | Error _ as error -> error
       | Ok pending ->
         committed_pending := Some pending;
         Ok pending)
;;

let enqueue_hitl_resolution_durable_result
    ~base_path
    ~keeper_name
    ~approval_id
    ~decision
    ~channel
  =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id; decision; channel }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Hitl_resolved resolution
    }
  in
  enqueue_durable_result ~base_path keeper_name stimulus
;;

let requeue_front ~base_path name stimuli =
  match stimuli with
  | [] -> ()
  | _ ->
    let committed_pending = ref None in
    (match
       Keeper_event_queue_persistence.update_checked_result
         ~base_path
         ~keeper_name:name
         ~after_commit:(fun () ->
           match !committed_pending with
           | None -> ()
           | Some pending -> publish_pending ~base_path name pending)
         (fun current ->
            let pending = requeue_missing_front current stimuli in
            committed_pending := Some pending;
            Ok pending)
     with
     | Error message ->
       Log.Keeper.error "registry: durable requeue failed name=%s: %s" name message
     | Ok () ->
       Keeper_event_queue_persistence.ack_inflight
         ~base_path
         ~keeper_name:name
         stimuli)
;;

let ack_consumed_result ~base_path name stimuli =
  Keeper_event_queue_persistence.ack_consumed ~base_path ~keeper_name:name stimuli
;;

let ack_consumed ~base_path name stimuli =
  match ack_consumed_result ~base_path name stimuli with
  | Ok () -> ()
  | Error msg ->
    Log.Keeper.warn "registry: ack_consumed failed name=%s: %s" name msg
;;

let drop_by_post_id ~base_path name ~post_id =
  match
    Keeper_event_queue_persistence.drop_by_post_id
      ~base_path
      ~keeper_name:name
      ~post_id
      ~after_commit:(publish_pending ~base_path name)
      ()
  with
  | Error msg ->
    Log.Keeper.warn
      "registry: drop_by_post_id failed name=%s post_id=%s: %s"
      name
      post_id
      msg;
    Error msg
  | Ok persisted_removed -> Ok persisted_removed
;;

let snapshot ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_event_queue_persistence.load ~base_path ~keeper_name:name
  | Some entry -> Atomic.get entry.event_queue
;;

let dequeue_when ~base_path name ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> None
  | Some _ ->
    (match
       Keeper_event_queue_persistence.claim_when_result
         ~base_path
         ~keeper_name:name
         ~claimed_at:(Time_compat.now ())
         ~ready
         ~after_commit:(publish_pending ~base_path name)
         ()
     with
     | Error message ->
       Log.Keeper.error "registry: durable claim failed name=%s: %s" name message;
       None
     | Ok None -> None
     | Ok (Some lease) ->
       (match lease_stimuli lease with
        | [ stimulus ] -> Some stimulus
        | [] | _ :: _ :: _ ->
          Log.Keeper.error
            "registry: single claim returned invalid cardinality name=%s"
            name;
          None))
;;

let dequeue ~base_path name = dequeue_when ~base_path name ~ready:(fun _ -> true)

let drain_board ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> []
  | Some _ ->
    (match
       Keeper_event_queue_persistence.claim_board_result
         ~base_path
         ~keeper_name:name
         ~claimed_at:(Time_compat.now ())
         ~after_commit:(publish_pending ~base_path name)
         ()
     with
     | Error message ->
       Log.Keeper.error "registry: durable board claim failed name=%s: %s" name message;
       []
     | Ok None -> []
     | Ok (Some lease) -> lease_stimuli lease)
;;

let claim_when_result ~base_path name ~claimed_at ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.claim_when_result
      ~base_path
      ~keeper_name:name
      ~claimed_at
      ~ready
      ~after_commit:(publish_pending ~base_path name)
      ()
;;

let claim_board_result ~base_path name ~claimed_at =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.claim_board_result
      ~base_path
      ~keeper_name:name
      ~claimed_at
      ~after_commit:(publish_pending ~base_path name)
      ()
;;

let settle_result ~base_path name ~settled_at ~lease ~settlement =
  Keeper_event_queue_persistence.settle_result
    ~base_path
    ~keeper_name:name
    ~settled_at
    ~lease
    ~settlement
    ~after_commit:(publish_pending ~base_path name)
    ()
;;
