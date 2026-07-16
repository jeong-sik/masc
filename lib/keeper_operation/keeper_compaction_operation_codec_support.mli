type field_error =
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

type decode_error =
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
  | Unknown_provider_delivery_kind of string
  | Invalid_provider_delivery_sequence of string
  | Invalid_provider_delivery of
      Keeper_compaction_operation.provider_delivery_ref_error
  | Invalid_keeper_chat_delivery of string
  | Invalid_tool_producer of Tool_invocation_ref.decode_error
  | Invalid_evidence of Keeper_compaction_evidence.decode_error
  | Invalid_turn_ref of string

val exact_object
  :  path:string
  -> allowed:string list
  -> required:string list
  -> Yojson.Safe.t
  -> ((string * Yojson.Safe.t) list, decode_error) result

val required_field
  :  path:string
  -> string
  -> (string * Yojson.Safe.t) list
  -> (Yojson.Safe.t, decode_error) result

val string_field
  :  path:string
  -> string
  -> Yojson.Safe.t
  -> (string, decode_error) result

val operation_id
  :  path:string
  -> string
  -> Yojson.Safe.t
  -> (Keeper_compaction_operation.Operation_id.t, decode_error) result

val attempt_id
  :  path:string
  -> string
  -> Yojson.Safe.t
  -> (Keeper_compaction_operation.Attempt_id.t, decode_error) result

val keeper_name
  :  path:string
  -> string
  -> Yojson.Safe.t
  -> (Keeper_id.Keeper_name.t, decode_error) result

val cause
  :  path:string
  -> string
  -> Yojson.Safe.t
  -> (Keeper_compaction_operation.Cause.t, decode_error) result

val checkpoint
  :  path:string
  -> Yojson.Safe.t
  -> (Keeper_checkpoint_ref.t, decode_error) result

val evidence
  :  path:string
  -> Yojson.Safe.t
  -> (Keeper_compaction_evidence.t, decode_error) result

val trigger
  :  path:string
  -> Yojson.Safe.t
  -> (Compaction_trigger.t, decode_error) result

val producer
  :  source_checkpoint:Keeper_checkpoint_ref.t
  -> Yojson.Safe.t
  -> (Keeper_compaction_operation.producer_ref option, decode_error) result

val turn_ref : Yojson.Safe.t -> (Ids.Turn_ref.t, decode_error) result
