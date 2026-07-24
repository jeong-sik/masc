(** Typed operator command for one Board-attention quarantine.

    The command never invokes OAS and never retries automatically. Candidate
    [Requeue_requested], candidate [Requeued], and exact partition [Ready] are
    committed in that order. The opaque quarantine id fences a later failure
    generation on the same singleton partition. *)

val request_schema : string
val tool_command_schema : string
val result_schema : string

type decision = Acknowledge_and_requeue

type request =
  { candidate_id : string
  ; expected_quarantine_id : string
  ; decision : decision
  }

type t =
  { keeper_name : string
  ; partition_id : string
  ; request : request
  }

type input_error =
  | Object_required
  | Duplicate_fields of string list
  | Unsupported_fields of string list
  | Missing_fields of string list
  | Invalid_field of string
  | Unsupported_schema of string
  | Unsupported_decision of string
  | Invalid_keeper_name of string

type execution_error =
  | Candidate_state_conflict of string
  | Partition_state_conflict of string
  | Durability_unconfirmed of string
  | Wake_request_failed of string

type report =
  { candidate : Keeper_board_attention_candidate.candidate
  ; partition : Keeper_board_attention_partition.t
  ; wake : Keeper_board_attention_worker_wake.wake_result
  }

val input_error_to_string : input_error -> string
val input_error_to_json : input_error -> Yojson.Safe.t
val execution_error_label : execution_error -> string
val execution_error_to_json : execution_error -> Yojson.Safe.t

val parse_request : Yojson.Safe.t -> (request, input_error) result
val parse_tool_command : Yojson.Safe.t -> (t, input_error) result

val make :
  keeper_name:string ->
  raw_partition_id:string ->
  request ->
  (t, input_error) result

val execute :
  now:float ->
  base_path:string ->
  t ->
  (report, execution_error) result

module For_testing : sig
  val execute_with_before_partition_commit :
    before_partition_commit:(Keeper_board_attention_partition.t -> unit) ->
    now:float ->
    base_path:string ->
    t ->
    (report, execution_error) result
end

val audit :
  Workspace.config ->
  actor:string ->
  t ->
  outcome:Audit_log.outcome ->
  (unit, string) result

val audit_json : (unit, string) result -> Yojson.Safe.t
val success_json : audit:Yojson.Safe.t -> t -> report -> Yojson.Safe.t
val failure_json : audit:Yojson.Safe.t -> execution_error -> Yojson.Safe.t


type inventory_phase =
  | Inventory_quarantined
  | Inventory_requeue_requested
  | Inventory_requeued

type inventory_item =
  { keeper_name : string
  ; partition_id : string
  ; candidate_id : string
  ; quarantine_id : string
  ; phase : inventory_phase
  ; failure_category : Keeper_board_attention_candidate.quarantine_failure_category
  ; attempt_provenance : Keeper_board_attention_candidate.attempt_provenance option
  ; quarantined_at : float
  ; requested_at : float option
  ; requeued_at : float option
  }

type inventory_error_kind =
  | Inventory_candidate_ledger_unavailable

type inventory_error =
  { keeper_name : string
  ; kind : inventory_error_kind
  }

type inventory =
  { items : inventory_item list
  ; errors : inventory_error list
  }

val inventory :
  base_path:string ->
  keeper_names:string list ->
  inventory

val inventory_to_json : inventory -> Yojson.Safe.t

val inventory_json :
  base_path:string ->
  keeper_names:string list ->
  Yojson.Safe.t
