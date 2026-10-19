(** Pure projection of committed admission provenance through revision history.
    Files, receipts, locks and journal cache ownership remain in the store. *)

open Keeper_memory_os_current_types

type transition =
  { evidence : revision_evidence
  ; removed : Keeper_memory_os_types.fact list
  ; program : Keeper_memory_os_program_types.publication option
  ; recreated_memory_ids : string list
  }

val project :
  t ->
  (int * admission_recall_binding) list ->
  (transition list, string) result ->
  successor_recall
(** Bindings are paired with their birth revisions; history is chronological.
    Identical duplicate rewrites are replay evidence, while conflicting duplicate
    rewrites make the affected binding unresolved. Only declared edges present
    at the retirement revision continue a path. A canonical program traverses
    its actual locked execution stages, using applied edges and exact endpoint
    facts; intermediate revisions are never invented. A later re-addition
    without a recorded edge cannot revive a dead path. A history error preserves
    the snapshot and bindings born at its
    current revision, and reports older bindings as unavailable. *)
