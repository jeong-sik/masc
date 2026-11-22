(** Declarative Ship-of-Theseus lifecycle state machine, structural molt
    triggers, and world-memory promotion proposals for the v2 Librarian.

    All lifecycle transitions are pure, closed algebraic sum types driven by
    structural boundaries (compaction epoch advances, completed synthesis
    cycles) — NEVER wall-clock TTL expiry or numeric importance scoring. *)

open Keeper_memory_os_types

(** Closed algebraic lifecycle states for a fact as it evolves through
    consolidation, canonicalization, supersession, and archival molting. *)
type lifecycle =
  | Ephemeral
  | Working
  | Consolidated
  | Canonical
  | Superseded_by of string
  | Molted_to_archive

type invalid_transition =
  { from : lifecycle
  ; to_ : lifecycle
  ; reason : string
  }

(** Pure declarative lifecycle transition validator. Terminal states
    ([Superseded_by _] and [Molted_to_archive]) never silently resurrect, and
    lifecycle never regresses backwards. *)
val transition : from:lifecycle -> to_:lifecycle -> (lifecycle, invalid_transition) result

val invalid_transition_to_string : invalid_transition -> string

val lifecycle_to_string : lifecycle -> string
val lifecycle_of_string : string -> lifecycle option

(** Structural boundary that triggers proactive declarative molting and
    cross-category synthesis. Never wall-clock time or numeric score thresholds. *)
type molt_trigger =
  | Compaction_epoch_advanced of { epoch_id : int }
  | Synthesis_cycle_completed
  | Memory_growth_molt_requested of
      { current_bytes : int
      ; threshold_bytes : int
      }

val molt_trigger_to_json : molt_trigger -> Yojson.Safe.t
val molt_trigger_of_json : Yojson.Safe.t -> (molt_trigger, wire_error) result

(** A verified local-to-world promotion proposal emitted by a Keeper's
    Librarian for consumption by the lock-free World Memory curator.
    [source_fact_ids] holds canonical [sha256:...] memory IDs that remain
    supported in the Keeper's local Memory snapshot. *)
type world_promotion =
  { source_fact_ids : string list
  ; claim : string
  ; category : category
  ; facets : string list
  ; scope : string
  }

val world_promotion_to_json : world_promotion -> Yojson.Safe.t
val world_promotion_of_json : Yojson.Safe.t -> (world_promotion, wire_error) result
