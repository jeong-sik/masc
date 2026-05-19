(** Cascade-attempt persistence + fiber_unresolved enrichment.

    SSOT for the cascade-attempt slot of keeper runtime meta. The only
    write-path is [record], which updates [meta.runtime.last_cascade_attempt]
    through a focused [Keeper_types.write_meta_with_merge] callback;
    [enrich_fiber_unresolved_outcome] is the dashboard / supervisor
    read-path that attaches a [provider=… http=…] suffix when a fresh
    failure attempt is on file. *)

(** Persist the last cascade provider attempt in keeper runtime meta.
    Best-effort: missing keepers or meta write failures are ignored. *)
val record :
  base_path:string -> keeper_name:string
  -> Keeper_types.cascade_attempt_record -> unit

(** Add [provider=<id> http=<status>] to [fiber_unresolved] outcomes when
    keeper runtime meta has a recorded cascade attempt within
    [freshness_threshold_sec]. Other outcomes are returned unchanged. *)
val enrich_fiber_unresolved_outcome :
  base_path:string -> keeper_name:string -> string -> string
