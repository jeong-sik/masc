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
      ; schedule_instance_id : string
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

type keeper_purge_error =
  | Schedule_ledger_read_error of Schedule_store.read_error
  | Durable_queue_read_error of { keeper_name : string; detail : string }
  | Durable_queue_index_error of { keeper_name : string; detail : string }
  | Invalid_execution_detail of { occurrence_id : string; detail : string }
  | Pending_transferred_occurrence of
      { source_keeper : string
      ; owner : string
      ; occurrence_id : string
      }
  | Projecting_transferred_occurrence of
      { source_keeper : string
      ; owner : string
      ; target : string
      ; occurrence_id : string
      }
  | Missing_transferred_evidence of
      { source_keeper : string
      ; owner : string
      ; occurrence_id : string
      }
  | Unprojected_schedule_transfer of
      { keeper_name : string; target : string; occurrence_id : string }
  | Transfer_resolution_error of
      { source_keeper : string
      ; target : string
      ; occurrence_id : string
      ; detail : string
      }
  | Mismatched_schedule_evidence of
      { keeper_name : string; occurrence_id : string }
  | Non_schedule_evidence of
      { keeper_name : string; occurrence_id : string }
  | Missing_schedule_evidence of
      { keeper_name : string; occurrence_id : string }
  | Schedule_ledger_write_error of Schedule_store.store_error

val keeper_purge_error_to_string : keeper_purge_error -> string

val settle_keeper_purge_occurrences :
  Workspace_utils.config ->
  keeper_name:string ->
  operation_id:string ->
  now:float ->
  (unit, keeper_purge_error) result
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
