open Keeper_memory_os_types

type source_kind =
  | Librarian
  | Explicit_write
  | Explicit_retract

type source =
  { kind : source_kind
  ; trace_id : string
  }

type removal =
  { removed_in_revision : int
  ; removed_at : float
  ; removed_by : source
  ; removed_origin : Keeper_memory_os_types.origin_kind
  ; drop_reason : string option
  }

type supersession =
  | Superseded_current
  | Target_already_dropped of removal

type support_invalidation =
  { fact : fact
  ; missing_premise_ids : string list
  }

type change =
  { added : fact list
  ; removed : fact list
  ; retained : int
  ; invalidated : support_invalidation list
  }

type upsert_error =
  | Unsupported_derivation of support_invalidation
  | Upsert_persistence_failed of string

type retract_error =
  | Retract_memory_id_invalid
  | Retract_reason_empty
  | Retract_fact_not_found of string
  | Retract_persistence_failed of string

type supersede_error =
  | Supersede_memory_id_invalid
  | Supersede_self
  | Supersede_target_not_current of string
  | Supersede_target_removed of removal
  | Supersede_target_not_authored of string
  | Supersede_successor_rests_on_target of support_invalidation
  | Supersede_unsupported_derivation of support_invalidation
  | Supersede_journal_unreadable of string
  | Supersede_persistence_failed of string

type retraction =
  { memory_id : string
  ; reason : string
  }

type retract_batch_error =
  | Retract_batch_empty
  | Retract_batch_memory_id_invalid of { index : int }
  | Retract_batch_reason_empty of { index : int }
  | Retract_batch_duplicate_memory_id of string
  | Retract_batch_snapshot_sha256_invalid
  | Retract_batch_snapshot_conflict of
      { expected_revision : int
      ; observed_revision : int option
      ; expected_snapshot_sha256 : string
      ; observed_snapshot_sha256 : string option
      }
  | Retract_batch_fact_not_found of string
  | Retract_batch_plan_evidence_pending of
      { plan_id : string
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      ; detail : string
      }
  | Retract_batch_persistence_failed of string

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : fact list
  ; change : change
  }

type commit_effect =
  | Rewritten
  | Unchanged

type librarian_failure_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Absorb_judgment_failure
  | Memory_snapshot_write_failure
  | Runtime_context_unavailable
  | Lane_cancelled
  | Unhandled_exception

type journal_entry =
  | Journal_committed of
      { recorded_at : float
      ; revision : int
      ; source : source
      ; change : change
      ; dropped : Keeper_memory_os_types.dropped_statement list option
      }
  | Journal_failed of
      { recorded_at : float
      ; trace_id : string
      ; kind : librarian_failure_kind
      ; detail : string
      ; snapshot_present : bool
      }
  | Journal_quarantined of
      { recorded_at : float
      ; rejection : string
      ; rejected_path : string
      }
