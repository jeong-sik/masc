(** RFC-0058 Phase 5 catalog discovery bridge — declarative cascade
    config rendered as legacy [weighted_entry] lists keyed by tier /
    tier-group profile name. *)

val weighted_entries_for_profile :
  config_path:string ->
  name:string ->
  Cascade_weighted_entry.t list option
(** [weighted_entries_for_profile ~config_path ~name] resolves
    [tier.<X>] or [tier-group.<X>] names from the declarative cascade
    config and returns the matching legacy [weighted_entry] list, or
    [None] when the profile is unknown / the parse fails.  Each entry's
    [model] field is the reconstructed [cascade_prefix:model_id] string
    so the existing legacy parser at
    [Cascade_config.parse_model_string] keeps working unchanged.
    Unresolvable members emit a single bounded WARN log per call and
    are dropped from the returned list.  Reads are cached
    by [(config_path, mtime)] — repeated invocations during boot /
    dashboard refresh do not re-parse the TOML. *)

val declarative_profile_names : config_path:string -> string list
(** [declarative_profile_names ~config_path] returns the profile names
    surfaced by the bridge in [(tiers, tier_groups)] order — i.e. the
    parser's own table order, [tier.<X>] entries first followed by
    [tier-group.<X>] entries.  Empty list when the parse fails.  This
    is the legacy-shape view; route metadata (keeper_assignable
    derivation) lives in [is_keeper_routable]. *)

val is_keeper_routable : config_path:string -> name:string -> bool
(** [is_keeper_routable ~config_path ~name] returns [true] iff the
    declarative profile [name] is the [target] of any [routes.X]
    entry.  Used by the catalog loader to default
    [keeper_assignable] fail-closed: declarative entries only flip
    to keeper-assignable when wired into a keeper-facing route, so a
    system-only tier (e.g. [tier-group.governance], reachable only via
    [system_targets.X]) stays sandboxed by default. *)
