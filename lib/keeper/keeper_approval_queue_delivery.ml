open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_grant

let record_resolution_delivery_failure ~keeper_name ~approval_id reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_approval_queue_failure_site.(to_label Resolution_delivery) )
      ]
    ();
  Log.Keeper.error
    ~keeper_name
    "hitl resolution delivery failed approval=%s: %s"
    approval_id
    reason
;;

let signal_resolution_after_commit ~base_path ~keeper_name ~approval_id =
  try
    let outcome =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Hitl_resolution
        ~base_path
        keeper_name
    in
    let outcome_label, detail =
      match outcome with
      | Keeper_registry.Signaled -> "signaled", "running"
      | Keeper_registry.Deferred_unregistered ->
        "deferred_unregistered", "unregistered"
      | Keeper_registry.Deferred_not_running phase ->
        "deferred_not_running", Keeper_state_machine.phase_to_string phase
      | Keeper_registry.Deferred_lifecycle denial ->
        ( "deferred_lifecycle"
        , Keeper_lifecycle_admission.autonomous_denial_to_wire denial )
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalResolutionSignal)
      ~labels:[ "keeper", keeper_name; "outcome", outcome_label ]
      ();
    Log.Keeper.info
      ~keeper_name
      "hitl resolution committed approval=%s signal=%s phase=%s"
      approval_id
      outcome_label
      detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Resolution_signal)
        ]
      ();
    Log.Keeper.error
      ~keeper_name
      "hitl resolution signal failed after durable commit approval=%s: %s"
      approval_id
      (Printexc.to_string exn)
;;

let commit_keeper_approval_resolution
    ~base_path ~keeper_name ~approval_id ~decision
    ~(channel : Keeper_continuation_channel.t) =
  match
    try
      Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
        ~base_path
        ~keeper_name
        ~approval_id
        ~decision
        ~channel
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Keeper_registry_event_queue.Hitl_enqueue_failed
           (Printexc.to_string exn))
  with
  | Ok () -> Ok ()
  | Error Keeper_registry_event_queue.Hitl_recipient_absent as error ->
    (* No Keeper exists with the addressed name. That is a terminal
       disposition the caller settles, not a delivery failure, so it gets
       neither the failure counter nor an ERROR log here. *)
    error
  | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) as error ->
    record_resolution_delivery_failure ~keeper_name ~approval_id reason;
    error
;;

let hitl_resolution_decision_of_approval_decision = function
  | Decision.Approve -> Keeper_event_queue.Hitl_approved
  | Decision.Reject rationale -> Keeper_event_queue.Hitl_rejected rationale
;;

let deliver_resolution ~base_path (entry : pending_approval) decision =
  commit_keeper_approval_resolution
    ~base_path
    ~keeper_name:entry.keeper_name
    ~approval_id:entry.id
    ~decision:(hitl_resolution_decision_of_approval_decision decision)
    ~channel:entry.continuation_channel
;;

let ensure_resolution_chat_projection =
  Keeper_approval_queue_projection.ensure_resolution_chat_projection
let ensure_replay_chat_projection =
  Keeper_approval_queue_projection.ensure_replay_chat_projection
let continuation_settled_chat_projection_present =
  Keeper_approval_queue_projection.continuation_settled_chat_projection_present

type continuation_projection_result =
  Keeper_approval_queue_result.continuation_projection_result =
  | Continuation_projection_recorded
  | Continuation_projection_not_ready

let settled_continuation_readiness
      ~base_path ~(resolution : Keeper_event_queue.hitl_resolution) =
  match resolution.decision with
  | Keeper_event_queue.Hitl_rejected _ -> Ok (Continuation_ready None)
  | Keeper_event_queue.Hitl_approved ->
    (match approved_resolution_delivery ~base_path ~id:resolution.approval_id with
     | Ok delivery -> Ok (continuation_readiness_of_delivery delivery)
     | Error error -> Error (grant_error_to_string error))
;;

let ensure_settled_continuation_chat_projection
      ~base_path ~keeper_name ~(resolution : Keeper_event_queue.hitl_resolution) =
  Result.bind (settled_continuation_readiness ~base_path ~resolution)
    (fun readiness ->
      Keeper_approval_queue_projection.record_settled_continuation
        ~base_path ~keeper_name ~approval_id:resolution.approval_id ~readiness)
;;

let record_native_continuation_delivery ~base_path ~keeper_name
    ~(resolution : Keeper_event_queue.hitl_resolution) =
  let tool_name = match resolution.decision with
    | Keeper_event_queue.Hitl_rejected _ -> Ok None
    | Keeper_event_queue.Hitl_approved ->
      (match approved_resolution_delivery ~base_path ~id:resolution.approval_id with
       | Ok {request; _} when request.keeper_name = keeper_name -> Ok (Some request.tool_name)
       | Ok _ -> Error "native continuation belongs to another Keeper"
       | Error error -> Error (grant_error_to_string error)) in
  Result.bind tool_name (fun tool_name ->
    Keeper_approval_queue_projection.record_settled_continuation
      ~base_path ~keeper_name ~approval_id:resolution.approval_id
      ~readiness:(Continuation_ready tool_name))
;;

let ensure_failed_continuation_chat_projection
      ~base_path ~keeper_name ~(resolution : Keeper_event_queue.hitl_resolution)
      ~(route : Keeper_runtime_failure_route.route) =
  Result.bind (settled_continuation_readiness ~base_path ~resolution)
    (fun readiness ->
      Keeper_approval_queue_projection.record_failed_continuation
        ~base_path ~keeper_name ~approval_id:resolution.approval_id ~readiness ~route)
;;
