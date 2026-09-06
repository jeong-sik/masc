
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

type keeper_wake_activation_deferred_reason =
  | Keeper_wake_activation_lifecycle_denied of string
  | Keeper_wake_activation_autoboot_disabled
  | Keeper_wake_activation_proactive_disabled
  | Keeper_wake_activation_shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Keeper_wake_activation_owner_unknown of string
      (** The owner could not be read: the metadata store or the owner
          registry did not answer. The string is that failure. *)
  | Keeper_wake_activation_owner_absent
      (** The metadata store answered with nothing it can read under this
          name: no file, or a file this binary cannot decode (which boot
          re-materialises from the Keeper's TOML). Wire reason
          [owner_absent], no detail. The durable stimulus is kept and the
          queue drain cancels it as owner-absent; a deleted Keeper stays
          absent until an operator registers the name again. *)
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
  Keeper_event_queue.stimulus ->
  (keeper_wake_acceptance, Schedule_runner.consumer_dispatch_error) result
(** Accepts one scheduled wake occurrence for [keeper_name], reusing the
    durable occurrence when the queue already holds it. *)
