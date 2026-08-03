val supported_payload_kinds : string list

type keeper_wake_reaction_ledger_status =
  | Keeper_wake_reaction_ledger_recorded
  | Keeper_wake_reaction_ledger_record_failed of string

type keeper_wake_occurrence_status =
  | Keeper_wake_awaiting_ack
  | Keeper_wake_already_acked
  | Keeper_wake_already_failed
  | Keeper_wake_already_cancelled

type keeper_wake_activation_deferred_reason =
  | Keeper_wake_activation_lifecycle_denied of string
  | Keeper_wake_activation_autoboot_disabled
  | Keeper_wake_activation_proactive_disabled
  | Keeper_wake_activation_shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Keeper_wake_activation_owner_unknown of string
  | Keeper_wake_activation_unregistered
  | Keeper_wake_activation_not_running of Keeper_state_machine.phase

type keeper_wake_activation_outcome =
  | Keeper_wake_activation_signaled
  | Keeper_wake_activation_deferred of keeper_wake_activation_deferred_reason
  | Keeper_wake_activation_not_required

type dispatch_receipt =
  | Keeper_wake_enqueued of
      { keeper_name : string
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      ; stimulus_id : string option
      ; reaction_ledger_status : keeper_wake_reaction_ledger_status option
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

val settle_keeper_purge_occurrences :
  Workspace_utils.config ->
  keeper_name:string ->
  operation_id:string ->
  now:float ->
  (unit, string) result
(** Project every exact unsettled occurrence owned by [keeper_name] into the
    schedule ledger before its durable queue is deleted. Pending work becomes
    an explicit purge cancellation; existing terminal evidence keeps its exact
    outcome. Missing evidence and in-flight transfers fail closed. *)

module For_testing : sig
  val settlements_with_read_state :
    read_state:
      (base_path:string ->
       string ->
       (Keeper_event_queue_state.t, string) result) ->
    Workspace_utils.config ->
    Schedule_domain.execution_record list ->
    (Schedule_runner.settlement_evidence, string) result list
end
