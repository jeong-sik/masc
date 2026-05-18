(** Cascade-attempt persistence helpers for {!Keeper_registry}. *)

type get_entry =
  base_path:string -> string -> Keeper_registry_types.registry_entry option

val record :
  get_entry:get_entry ->
  base_path:string ->
  keeper_name:string ->
  Keeper_types.cascade_attempt_record ->
  unit
(** Persist the last cascade provider attempt in keeper runtime meta.
    Best-effort: missing keepers or meta write failures are ignored. *)

val enrich_fiber_unresolved_outcome :
  get_entry:get_entry -> base_path:string -> keeper_name:string -> string -> string
(** Add [provider=<id> http=<status>] to fresh [fiber_unresolved] outcomes. *)
