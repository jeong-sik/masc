(** Agent memory tool runtime — search, context status, write. *)

(** Issue #8484: Variant SSOT for memory search scope.  Mirror in
    [Tool_shard.memory_search_source_enum_strings] (cycle avoidance,
    sync regression test catches drift). *)
type memory_search_source =
  | Current
      (** Ordinary and source-bound facts that are current now. This is the
          default and excludes absorbed history. *)
  | Absorbed
      (** Facts a librarian pass merged into a newer claim (RFC-0456 §4.2),
          read from [<keeper>.memory-absorbed.jsonl]. *)
  | History
  | All

val memory_search_source_of_string_opt : string -> memory_search_source option
val valid_memory_search_source_strings : string list

val keeper_memory_search_json
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> args:Yojson.Safe.t
  -> string

val keeper_memory_search_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

val keeper_context_status_json
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> string

(** Explicit memory write surface.

    Without [source_path], atomically adds a durable claim to the ordinary
    current Memory OS snapshot. With [source_path], writes only the
    source-bound current store.
    Body is stored as [**title** content] when [title] is non-empty.

    Args (JSON object):
    - [title] — optional hook. May be empty; then [content] stands alone.
    - [content] — body. Required; must be non-empty.
    - [source_path] — optional keeper-visible regular file. When present, the
      claim enters the source-bound current store and is revalidated before
      every recall instead of entering the ordinary Memory OS snapshot.
    - [rule_id] and [premise_ids] — optional pair for an ordinary-current
      derived conclusion. Premises are exact ordinary Memory OS identities.

    Returns a JSON string with [{ok, error_kind, ...}]:
    - On success: [ok=true], [rows_written], [outcome], [store].
    - On validation or persistence failure: [ok=false] with the
      corresponding explicit [error_kind]. *)
val keeper_memory_write_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t
(** Validate and atomically upsert an explicit fact in the Keeper's
    Memory OS snapshot. The write stays inside MASC and never enters the
    external-effect Gate or approval replay path. *)

(** The two stores an explicit memory write reaches: the ordinary current
    Memory OS snapshot, or the source-bound store a [source_path] selects. *)
type fact_store =
  | Ordinary_current
  | Source_bound_current

(** Which half of a derivation arrived without the other. *)
type derivation_half =
  | Rule_id_without_premise_ids
  | Premise_ids_without_rule_id

(** Why the [rule_id] and [premise_ids] a call carried cannot name a
    derivation. Closed and produced only by {!validate_memory_write_args}, so a
    new refusal has to say what to change before it can be made.
    {!Keeper_memory_os_types.is_memory_id} stays the single premise grammar;
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

(** Result of validating a [keeper_memory_write] call's args. Exposed
    so tests can pin the error_kind taxonomy without constructing a
    [Workspace.config]. *)
type memory_write_error_kind =
  | Content_empty
  | Source_path_invalid
  | Source_read_failed of Keeper_memory_source_current.source_read_failure
  | Derivation_incomplete of derivation_half
  | Derivation_invalid of derivation_rejection
  | Derived_source_path_unsupported
  | Board_ref_invalid
      (** [board_post_id] or [board_comment_id] is not a string, is blank, or
          fails the Board id grammar. *)
  | Board_comment_without_post
      (** [board_comment_id] was given without [board_post_id]. *)
  | Board_ref_with_derivation_unsupported
      (** A Board reference is an observation source; a derived conclusion
          cannot carry one. *)
  | Board_ref_with_source_path_unsupported
      (** A source-bound claim already names its file; it cannot also name a
          Board post. *)
  | Unsupported_derivation
  | Persistence_failed of fact_store
      (** The store did not answer; which store decides what a repeat write
          does. *)
  | Commit_receipt_inconsistent
  | No_memory_write_error

val memory_write_error_kind_to_string : memory_write_error_kind -> string

val memory_write_rejection_fields
  :  memory_write_error_kind
  -> (string * Yojson.Safe.t) list
(** [rejected_field] and [expected] for a refusal this kind can answer: which
    field to change and what it takes. Empty for the kinds whose payload
    already carries its own coordinates. Derived from the kind, so no failure
    site states it. *)

val memory_write_error_effect_disposition
  :  memory_write_error_kind
  -> Tool_result.failure_effect_disposition
(** What a failed write with this kind committed. The same match on the kind
    also picks the payload's [what_committed] sentence, so no failure site
    states either. *)

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; source_path : string option
      ; basis : Keeper_memory_os_types.basis
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

val validate_memory_write_args : Yojson.Safe.t -> memory_write_validation

(** Explicitly retract one exact ordinary-current fact. The durable reason is
    journaled with the same commit, and unsupported derived facts are removed
    by the Memory OS support fixed point. *)
val keeper_memory_retract_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

type memory_retract_error_kind =
  | Memory_id_invalid
  | Reason_empty
  | Fact_not_found
  | Retract_persistence_failed
  | No_memory_retract_error

val memory_retract_error_kind_to_string : memory_retract_error_kind -> string

type memory_retract_validation =
  | Memory_retract_ok of
      { memory_id : string
      ; reason : string
      }
  | Memory_retract_invalid of memory_retract_error_kind

val validate_memory_retract_args : Yojson.Safe.t -> memory_retract_validation

module For_testing : sig
  val read_current_facts
    :  keepers_dir:string
    -> keeper_id:string
    -> (Keeper_memory_os_types.fact list, string) result
end
