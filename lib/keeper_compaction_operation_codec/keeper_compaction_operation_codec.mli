(** Closed durable codec for typed compaction operation facts. *)

type field_error = Keeper_compaction_operation_codec_support.field_error =
  | Unknown_field of
      { path : string
      ; field : string
      }
  | Duplicate_field of
      { path : string
      ; field : string
      }
  | Missing_field of
      { path : string
      ; field : string
      }
  | Wrong_type of
      { path : string
      ; field : string
      ; expected : string
      }

type decode_error = Keeper_compaction_operation_codec_support.decode_error =
  | Expected_object of string
  | Invalid_field of field_error
  | Unknown_event_kind of string
  | Unknown_failure_kind of string
  | Unknown_reconciliation_reason of string
  | Invalid_operation_id of Keeper_compaction_operation_identity.id_error
  | Invalid_attempt_id of Keeper_compaction_operation_identity.id_error
  | Invalid_keeper_name of string
  | Invalid_trace_id of string
  | Invalid_cause of Keeper_compaction_operation_identity.Cause.error
  | Invalid_checkpoint of Keeper_checkpoint_ref.create_error
  | Invalid_trigger of Compaction_trigger.decode_error
  | Unknown_producer_kind of string
  | Invalid_tool_producer of Tool_invocation_ref.decode_error
  | Invalid_provider_producer of Keeper_compaction_operation.producer_ref_error
  | Invalid_evidence of Keeper_compaction_evidence.decode_error
  | Invalid_turn_ref of string

val to_json : Keeper_compaction_operation.event -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_compaction_operation.event, decode_error) result
