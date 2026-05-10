(** Declarative catalog → runtime snapshot conversion (RFC-0058 Phase 3).

    Converts an {!Cascade_declarative_adapter.adapted_catalog} into a
    lightweight {!decl_snapshot} that can be compared against the legacy
    JSON hotpath snapshot for parallel validation.

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

val try_load_declarative :
  string ->
  (decl_snapshot,
    Cascade_declarative_adapter.adapter_error list)
  result option
(** [try_load_declarative config_path] attempts to parse a 5-layer TOML
    and convert it to a snapshot.

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
(** Extract profile names from a declarative snapshot for comparison. *)
