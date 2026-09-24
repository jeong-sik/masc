
type keeper_wake_reaction_ledger_status =
  | Keeper_wake_reaction_ledger_recorded
  | Keeper_wake_reaction_ledger_record_failed of string

type keeper_wake_occurrence_status =
  | Keeper_wake_awaiting_ack
  | Keeper_wake_already_acked
  | Keeper_wake_already_failed
  | Keeper_wake_already_cancelled

type keeper_wake_result_delivery_policy =
  | Keeper_wake_result_delivery_none
  | Keeper_wake_result_delivery_reply_to_origin

(** Why a durably enqueued wake did not also signal a live owner. A name
    the metadata store does not hold is not a deferral: [consumer] rejects
    that occurrence terminally before anything is enqueued and the schedule
    fails with the reason. *)
type keeper_wake_activation_deferred_reason =
  | Keeper_wake_activation_lifecycle_denied of string
  | Keeper_wake_activation_autoboot_disabled
  | Keeper_wake_activation_proactive_disabled
  | Keeper_wake_activation_shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Keeper_wake_activation_owner_unknown of string
      (** The owner could not be read: the metadata store or the owner
          registry did not answer. The string is that failure. *)
  | Keeper_wake_activation_owner_not_current of string
      (** The metadata store holds a file under this name that this binary
          does not decode as current. Boot re-materialises the Keeper from
          its declaration and it consumes the retained stimulus then. Wire
          reason [owner_not_current]; the string is the decode detail. *)
  | Keeper_wake_activation_unregistered
  | Keeper_wake_activation_not_running of Keeper_state_machine.phase

type keeper_wake_activation_outcome =
  | Keeper_wake_activation_signaled
  | Keeper_wake_activation_deferred of keeper_wake_activation_deferred_reason
  | Keeper_wake_activation_not_required

type dispatch_receipt =
  | Keeper_wake_enqueued of
      { keeper_name : string
      ; schedule_instance_id : string
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      ; stimulus_id : string option
      ; reaction_ledger_status : keeper_wake_reaction_ledger_status option
      ; result_delivery_policy : keeper_wake_result_delivery_policy
      ; occurrence_status : keeper_wake_occurrence_status
      ; activation_outcome : keeper_wake_activation_outcome
      }

val dispatch_receipt_of_detail :
  Yojson.Safe.t -> (dispatch_receipt, string) result

val dispatch_receipt_to_yojson : dispatch_receipt -> Yojson.Safe.t

val consumer : Schedule_runner.consumer
(** Production scheduled-automation consumer adapter.

    The schedule core remains opaque; this adapter is the MASC server layer that
    interprets explicitly supported payload envelopes. *)

val cancel_keeper_schedules :
  Workspace_utils.config ->
  keeper_name:string ->
  (unit, Schedule_store.store_error) result
(** Cancels only future wake schedules for [keeper_name]. Already-delivered
    wake messages and their Keeper-owned results are not schedule state. *)

val resume_fenced_owners :
  Workspace_utils.config ->
  newly_held:Schedule_runner.held list ->
  Schedule_runner.held list ->
  unit
(** For each Keeper a tick held on its shutdown fence, ask the operation that
    now holds that fence to walk its finalization again, once. Call it after
    the tick, so every held schedule is already settled as [Due] (#34642).
    If an operation cannot be walked in-process, log that phase only when
    its fence first causes a hold. *)

type keeper_wake_acceptance =
  | Wake_required
  | Already_pending of string
  | Already_acked
  | Already_failed of string
  | Already_cancelled

val accept_keeper_wake_occurrence :
  ?intake_token:Keeper_shutdown_intake_fence.intake_token ->
  base_path:string ->
  keeper_name:string ->
  expected_owner:string ->
  stimulus_id:string ->
  now:float ->
  wake:Keeper_event_queue.scheduled_wake ->
  Keeper_event_queue.stimulus ->
  (keeper_wake_acceptance, Schedule_runner.consumer_dispatch_error) result
(** Accepts one scheduled wake occurrence for [keeper_name], reusing the
    durable occurrence when the queue already holds it. A new occurrence
    first cancels the schedule's earlier pending occurrences as superseded,
    stamped [now], so the queue holds at most one per schedule. *)
