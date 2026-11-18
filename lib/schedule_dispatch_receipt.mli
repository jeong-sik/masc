(** What dispatch recorded when it accepted one schedule occurrence: the
    [detail] of that occurrence's wake record. The receipt is fixed at
    dispatch. It does not change when the Keeper later consumes, finishes or
    cancels the occurrence; {!Schedule_occurrence_consumption} reads that.

    The schedule store holds the receipt as JSON. This module is its only
    decoder and encoder, below the server layer so that [masc_schedule_get]
    and the dashboard projection decode it the same way. *)

val keeper_wake_enqueued_kind : string
val keeper_event_queue_label : string

type keeper_wake_reaction_ledger_status =
  | Keeper_wake_reaction_ledger_recorded
  | Keeper_wake_reaction_ledger_record_failed of string

type keeper_wake_occurrence_status =
  | Keeper_wake_awaiting_ack
  | Keeper_wake_already_acked
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
  | Lane_act_handed_over of
      { installation_id : string
      ; instance_id : string
      ; request_id : string
      ; schedule_instance_id : string
      ; schedule_id : string
      }
      (** A [masc.lane_act] occurrence whose action receipt is durable. It
          names the receipt; the receipt says whether the worker ran it. *)
  | Keeper_receipt_delivered of
      { keeper_name : string
      ; schedule_instance_id : string
      ; schedule_id : string
      }
      (** A [masc.keeper_wake] occurrence whose delivery is [receipt] and whose
          tool-result receipt is in the Keeper's outbox. *)

val dispatch_receipt_of_detail :
  Yojson.Safe.t -> (dispatch_receipt, string) result

val dispatch_receipt_to_yojson : dispatch_receipt -> Yojson.Safe.t

val keeper_wake_occurrence_status_to_string :
  keeper_wake_occurrence_status -> string

val keeper_wake_reaction_ledger_status_json_fields :
  keeper_wake_reaction_ledger_status option -> (string * Yojson.Safe.t) list

val keeper_wake_activation_deferred_reason_fields :
  keeper_wake_activation_deferred_reason -> string * string option

val keeper_wake_activation_outcome_json_fields :
  keeper_wake_activation_outcome -> (string * Yojson.Safe.t) list
