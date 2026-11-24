(** The Board attention quarantine inventory and exact operator recovery wire. *)

type quarantine_failure_category =
  | Candidate_membership_conflict
  | Durable_partition_invariant
  | Exact_setup_unavailable
  | Exact_flow_replayed
  | Exact_lane_exhausted
      (** Every HTTP slot refused and the CLI tail had none to walk, or
          refused too. *)
  | Exact_flow_bookkeeping_failed
  | Exact_completion_failed
  | Domain_output_invalid
  | Execution_provenance_mismatch
  | Unexpected_worker_failure
  | Exact_execution_quarantined
  | Exact_execution_interrupted
      (** A process restart cut a bound execution. Requeueable: the judgment
          lane is a read-only model call, so redispatch spends tokens and
          nothing else. *)

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }


val quarantine_failure_category_to_string : quarantine_failure_category -> string
val quarantine_failure_category_of_string : string -> quarantine_failure_category option

type decision = Acknowledge_and_requeue

type request =
  { candidate_id : string
  ; expected_quarantine_id : string
  ; decision : decision
  }

type inventory_phase =
  | Inventory_quarantined
  | Inventory_requeue_requested
  | Inventory_requeue_unfinished
  | Inventory_requeued
  | Inventory_requeue_unreconciled

type inventory_item =
  { keeper_name : string
  ; partition_id : string
  ; candidate_id : string
  ; quarantine_id : string
  ; phase : inventory_phase
  ; failure_category : quarantine_failure_category
  ; attempt_provenance : attempt_provenance option
  ; quarantined_at : float
  ; requested_at : float option
  ; requeued_at : float option
  ; requested_by : string option
  }

type inventory_error_kind =
  | Inventory_candidate_ledger_unavailable
  | Inventory_partition_ledger_unavailable
      (** Read only for a keeper with a recorded requeue; that keeper's
          requeued rows are [Inventory_requeue_unreconciled]. *)

type inventory_error =
  { keeper_name : string
  ; kind : inventory_error_kind
  }

type inventory =
  { items : inventory_item list
  ; errors : inventory_error list
  }

val request_schema : string
val result_schema : string
val decision_to_string : decision -> string
val request_to_json : request -> Yojson.Safe.t
val inventory_to_json : inventory -> Yojson.Safe.t
val inventory_item_of_json : Yojson.Safe.t -> (inventory_item, string) result
val inventory_error_of_json : Yojson.Safe.t -> (inventory_error, string) result
val inventory_phase_to_string : inventory_phase -> string
val inventory_error_kind_to_string : inventory_error_kind -> string
val inventory_of_json : keeper:string -> Yojson.Safe.t -> (inventory, string) result
val recovery_confirmed : inventory_item -> Yojson.Safe.t -> (unit, string) result
val same_candidate : inventory_item -> inventory_item -> bool
val recoverable : inventory_phase -> bool
