(** Typed command boundary for resolving one crash-ambiguous chat receipt.

    Resolution is an operator decision, never an automatic retry.  Both HTTP
    and MCP surfaces parse into this type and execute the same exact
    receipt/revision/lease compare-and-set. *)

val request_schema : string
val tool_command_schema : string
val result_schema : string

type cancellation =
  { detail : string
  ; outcome_ref : string option
  }

type decision =
  | Requeue_unconfirmed
  | Cancel_unconfirmed of cancellation

type request =
  { expected_revision : int64
  ; lease_id : string
  ; decision : decision
  }

type t =
  { keeper_name : string
  ; receipt_id : Keeper_chat_queue.Receipt_id.t
  ; request : request
  }

type input_error =
  | Object_required of
      { context : string
      ; observed_kind : string
      }
  | Duplicate_fields of
      { context : string
      ; fields : string list
      }
  | Unsupported_fields of
      { context : string
      ; fields : string list
      }
  | Missing_fields of
      { context : string
      ; fields : string list
      }
  | Invalid_field of
      { field : string
      ; expectation : string
      }
  | Unsupported_schema of string
  | Unsupported_decision of string
  | Invalid_keeper_name of string
  | Invalid_receipt_id of string

val input_error_to_string : input_error -> string
val input_error_to_json : input_error -> Yojson.Safe.t

val parse_request : Yojson.Safe.t -> (request, input_error) result

val make :
  keeper_name:string ->
  raw_receipt_id:string ->
  request ->
  (t, input_error) result

val parse_tool_command : Yojson.Safe.t -> (t, input_error) result

val decision_label : decision -> string

val execute :
  now:float ->
  t ->
  (Keeper_chat_queue.recovery_resolution_report, Keeper_chat_queue.mutation_error)
    result

val audit :
  Workspace.config ->
  actor:string ->
  t ->
  outcome:Audit_log.outcome ->
  (unit, string) result

val audit_json : (unit, string) result -> Yojson.Safe.t

val success_json :
  audit:Yojson.Safe.t ->
  t ->
  Keeper_chat_queue.recovery_resolution_report ->
  Yojson.Safe.t

val mutation_error_json :
  audit:Yojson.Safe.t -> Keeper_chat_queue.mutation_error -> Yojson.Safe.t
