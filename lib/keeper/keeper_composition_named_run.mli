(** Immutable membership of a named async producer's accepted request.
    Request context alone does not prove admission by that producer. *)
val admit :
  base_path:string -> keeper_name:string ->
  Keeper_composition_dependency.composition -> (unit, string) result
(** Called only by the named composition producer at canonical Queued
    acceptance, before its worker starts. An existing different binding is
    refused; replay of the exact original admission is idempotent. *)

val validate :
  base_path:string -> keeper_name:string ->
  Keeper_composition_dependency.composition -> (unit, string) result
(** Read-only membership check. Missing, changed or unavailable original
    evidence refuses result consumption, including while the request is active. *)
