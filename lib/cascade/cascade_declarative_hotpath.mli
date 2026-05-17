(** Declarative catalog -> runtime snapshot conversion (RFC-0058 Phase 3).

    Converts an {!Cascade_declarative_adapter.adapted_catalog} into a
    lightweight {!decl_snapshot} used by the active cascade runtime.

    This module does NOT depend on {!Cascade_catalog_runtime} to avoid
    a dependency cycle.  Mirror types are defined locally and the runtime
    module bridges them at the call site.

    @stability Internal *)

(** {1 Mirror types} *)

type candidate = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

type profile = {
  name : string;
  weighted_entries : Cascade_config_loader.weighted_entry list;
  inference_params : Cascade_config_loader.inference_params;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  candidates : candidate list;
}

type decl_snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile list;
}

(** {1 Low-level helpers} *)

val provider_config_to_model_string :
  Llm_provider.Provider_config.t -> string
(** Reconstruct a "prefix:model_id" string from a resolved provider config.
    The result is parseable by [Cascade_config.parse_model_string] and
    matches the format stored in {!Cascade_config_loader.weighted_entry.model}. *)

(** {1 Profile conversion} *)

val adapted_profile_to_profile :
  Cascade_declarative_adapter.adapted_profile ->
  profile option
(** [None] when [provider_configs] is empty (invalid profile). *)

(** {1 Catalog conversion} *)

val adapted_catalog_to_snapshot :
  source_path:string ->
  Cascade_declarative_adapter.adapted_catalog ->
  decl_snapshot option
(** [None] when [profiles] is empty or all profiles fail conversion.
    Errors in the adapted catalog are logged but do not prevent snapshot
    creation for the valid subset. *)

(** {1 TOML loading} *)

type partial_load_result = {
  snapshot : decl_snapshot;
  errors : Cascade_declarative_adapter.adapter_error list;
}
(** Result of a partial catalog load. [snapshot] always contains the
    subset of profiles whose internal cross-references resolved
    successfully. [errors] lists per-entry failures (unresolved
    provider/model/binding/tier). [errors = []] is the all-clean case.

    Surfacing both fields at the same time lets downstream callers (notably
    keeper toml validation) accept the valid subset while logging the
    failed entries — see RFC-0058 Phase 8. *)

val try_load_partial : string -> partial_load_result option
(** [try_load_partial config_path] attempts to parse a 5-layer TOML and
    convert it to a partial snapshot.

    Returns:
    - [Some { snapshot; errors = [] }] — 5-layer TOML, all entries resolved
    - [Some { snapshot; errors = e :: _ }] — 5-layer TOML, partial parse;
      [snapshot] contains the resolvable subset
    - [None] — not a 5-layer TOML (parse failed), or no entry resolvable
      at all (caller should fall back to the legacy profile loader) *)

val try_load_declarative :
  string ->
  (decl_snapshot,
    Cascade_declarative_adapter.adapter_error list)
  result option
(** Backward-compatible binary variant of {!try_load_partial}: collapses
    a partial result to [Error] when any error is present, otherwise
    returns [Ok snapshot]. Retained for boot-gate callers that require
    all-or-nothing semantics (e.g.
    [Cascade_catalog_runtime.validate_path_result]).

    Returns:
    - [Some (Ok snapshot)] — 5-layer TOML found and fully converted
    - [Some (Error errors)] — 5-layer TOML found but conversion failed
    - [None] — not a 5-layer TOML (parse failed) *)

(** {1 Route bindings} *)

val declarative_route_bindings :
  Cascade_declarative_adapter.adapted_catalog ->
  (string * string) list
(** Extract [(route_name, profile_name)] pairs from the adapted catalog. *)

val decl_snapshot_profile_names :
  decl_snapshot -> string list
(** Extract profile names from a declarative snapshot as a sorted,
    deduplicated set.  The sort gives callers a stable comparison and
    output order independent of TOML declaration order; without it, list equality
    flips on declaration-order differences and produces spurious
    [profile name mismatch] WARNs. *)
