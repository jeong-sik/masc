(** Pure memory mutation argument validation and typed failure evidence. *)

type fact_store =
  | Ordinary_current
  | Source_bound_current

(** Which half of a derivation arrived without the other. *)
type derivation_half =
  | Rule_id_without_premise_ids
  | Premise_ids_without_rule_id

(** Why the [rule_id] and [premise_ids] this call carried cannot name a
    derivation. Closed and produced only by {!validate_memory_write_args}, so a
    new refusal has to say what to change before it can be made.
    [Keeper_memory_os_types.is_memory_id] stays the single premise grammar;
    this type only records which element broke it and where. *)

type derivation_rejection =
  | Rule_id_not_a_string
  | Premise_ids_not_an_array
  | Rule_id_blank
  | Premise_ids_empty
  | Premise_not_a_string of { index : int }
  | Premise_repeated of
      { index : int
      ; premise_id : string
      }
  | Premise_not_a_memory_id of
      { index : int
      ; premise_id : string
      }

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Workspace.config]. *)

type memory_write_error_kind =
  | Content_empty
  | Source_path_invalid
  | Source_read_failed of Keeper_memory_source_current.source_read_failure
  | Derivation_incomplete of derivation_half
  | Derivation_invalid of derivation_rejection
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Unsupported_derivation
  | Supersedes_invalid
  | Supersedes_with_source_path_unsupported
  | Supersedes_self
  | Supersedes_not_current
  | Supersedes_not_authored
  | Supersedes_premise_of_successor
  | Pending_admission_persistence_failed
  | Persistence_failed of fact_store
  | Commit_receipt_inconsistent
  | No_memory_write_error

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; source_path : string option
      ; basis : Keeper_memory_os_types.basis
      ; supersedes : string option
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

type memory_retract_error_kind =
  | Memory_id_invalid
  | Reason_empty
  | Fact_not_found
  | Retract_persistence_failed
  | No_memory_retract_error

type memory_retract_validation =
  | Memory_retract_ok of
      { memory_id : string
      ; reason : string
      }
  | Memory_retract_invalid of memory_retract_error_kind

val memory_write_error_kind_to_string : memory_write_error_kind -> string
val class_of_memory_write_error_kind : memory_write_error_kind -> Tool_result.tool_failure_class
val memory_write_failure_effect : memory_write_error_kind -> Tool_result.failure_effect_disposition * string
val memory_write_rejection_fields : memory_write_error_kind -> (string * Yojson.Safe.t) list
val memory_write_error_effect_disposition : memory_write_error_kind -> Tool_result.failure_effect_disposition
val validate_memory_write_args : Yojson.Safe.t -> memory_write_validation
val memory_write_basis_receipt : Keeper_memory_os_types.basis -> Yojson.Safe.t
val memory_retract_error_kind_to_string : memory_retract_error_kind -> string
val class_of_memory_retract_error_kind : memory_retract_error_kind -> Tool_result.tool_failure_class
val memory_retract_failure_effect : memory_retract_error_kind -> Tool_result.failure_effect_disposition * string
val validate_memory_retract_args : Yojson.Safe.t -> memory_retract_validation
