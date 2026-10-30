(** An ordered Memory program and its exact source accounting. This leaf
    contract has no dependency on Runtime, Current, storage or clocks.
    The caller supplies already accepted judgments; structural validation is
    not a semantic judge or independent proof of provider exhaustion. *)
open Keeper_memory_os_types

type decision = Keeper_memory_os_program_types.decision =
  { run_id : string
  ; keeper_id : Keeper_identity.Keeper_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; input_current : fact list option
  ; sources : Keeper_librarian_unread.source list
  ; input_evidence : Yojson.Safe.t
  ; gate_evidence : Yojson.Safe.t
  ; working_state : string
  ; new_claims : fact list
  ; dropped : dropped_statement list
  ; absorbed : absorbed_statement list
  ; revisions : revision list
  }
(** Evidence documents are preserved opaque data, never interpreted as
    admission or control flags. The Runtime adapter must bind [sources] to
    the exact message bytes it actually judged. Their hashes and ordered
    partition are checked here against the complete frozen source manifest.
    [sources=[]] retains an observation-only decision without claiming any
    conversation message was read. The Runtime adapter must bind that decision
    to actual host observations; opaque evidence is never parsed as authority. *)

type invalidation = Keeper_memory_os_program_types.invalidation =
  { fact : fact
  ; missing_premise_ids : string list
  }

type stage = Keeper_memory_os_program_types.stage =
  { index : int
  ; decision : decision
  ; before : fact list
  ; after : fact list
  ; invalidated : invalidation list
  ; absorbed_applied : absorbed_statement list
  ; revisions_applied : revision list
  ; claims_refused : fact list
  }
(** [index] is zero based within one transaction, not a durable revision.
    Full intermediate facts and accepted decisions remain available even
    when the final facts equal the original facts (including A→B→A). *)

type t = Keeper_memory_os_program_types.t =
  { transaction_id : string
  ; keeper_id : Keeper_identity.Keeper_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; sources : Keeper_librarian_unread.source list
  ; unread : Keeper_librarian_unread.t list
  ; initial_current : fact list option
  ; stages : stage list
  ; final_facts : fact list
  }

val create
  :  transaction_id:string
  -> keeper_id:Keeper_identity.Keeper_id.t
  -> turn_ref:Ids.Turn_ref.t
  -> sources:Keeper_librarian_unread.source list
  -> unread:Keeper_librarian_unread.t list
  -> initial_current:fact list option
  -> decisions:decision list
  -> (t, string) result
(** Require one nonempty frozen manifest, unique exact source coordinates,
    and an ordered partition into processed sources and matching unread holes.
    Reject missing, duplicate, reordered or hash-conflicting accounting.
    Validate each step's original full current payload and apply the shared
    supported disposition before the next step. New claims cannot recreate a held
    identity; relationship sources must be held, targets must survive the
    declared removals, and revisions must retire their source. No receipt is minted. *)

type execution = Keeper_memory_os_program_types.execution =
  { program : t
  ; initial_facts : fact list
  ; stages : stage list
  ; final_facts : fact list
  }

val replay : t -> current:fact list -> (execution, string) result
(** Revalidate the complete public program before replaying against locked current
    facts. Forged stage results or mismatched decision ownership reject.
    Permit unrelated additions and
    preserve their fields and order. Permit reobservation metadata changes
    while requiring the same claim/category/basis/origin and insertion time.
    Observation time may only increase. Reject missing expected
    facts or any divergence of the staged semantic application; no prefix is
    returned as a successful program. Incarnation and original-boundary checks
    are the storage publisher's responsibility before this calculation. *)

val touched_ids : execution -> string list
(** Identities whose occurrence changes in any step, including intermediate
    removal/re-addition invisible in the outer snapshot delta. A consumer
    without typed program traversal must not carry those as direct bindings. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict schema 1. Decode and replay the complete program, then check every
    stored intermediate/final fact, invalidation and applied relationship.
    Unknown/missing/duplicate program fields or forged computed outcomes reject.
    Opaque evidence documents are retained without assigning them a schema. *)

val execution_to_json : execution -> Yojson.Safe.t
val execution_of_json : Yojson.Safe.t -> (execution, string) result
(** The original program and actual locked replay stay distinct. This proof
    alone does not assert a durable snapshot; the publisher must bind it to
    that snapshot's exact revision/hash and canonical journal transaction. *)
