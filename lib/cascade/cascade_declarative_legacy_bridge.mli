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
    [Cascade_config.parse_model_string] keeps working unchanged. *)

val declarative_profile_names : config_path:string -> string list
(** [declarative_profile_names ~config_path] returns the
    [tier.<X>]/[tier-group.<X>] names produced by the declarative
    adapter, in the order [Cascade_declarative_adapter.adapt_config]
    emits them.  Empty list when the parse fails. *)
