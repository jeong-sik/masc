(** Cascade_metrics — Prometheus emit helpers for cascade routing observability. *)

val on_decision : cascade_name:string -> decision_label:string -> unit
val on_fallback : cascade_name:string -> reason:string -> unit
val on_exhausted : cascade_name:string -> unit
val on_phase_override : phase:string -> from_cascade:string -> to_cascade:string -> unit

val on_profile_discovery : path:string -> unit
(** Tick the profile discovery counter.  [path] must be one of
    [declarative], [legacy_after_decl_error], [legacy_no_decl].
    See [cascade_catalog_runtime.ml] [discover_profile_names]. *)

val on_declarative_parse_error : unit -> unit
(** Tick the declarative parse error counter once per discovery call
    that returned [Error _] from the declarative adapter.  The
    individual error bodies are surfaced via WARN logs at the call
    site. *)

val on_parallel_validation : result:string -> unit
(** Tick the parallel-validation counter for one [validate_path_result]
    invocation.  [result] must be one of [ok], [mismatch],
    [adapter_error], [no_decl]. *)

val on_toml_read_race : unit -> unit
(** Tick the TOML read-race counter once per [load_toml_in_memory]
    call where the cascade.toml mtime drifted between the pre-stat
    and post-stat samples, or the file vanished between samples.
    The loader still returns fresh content but skips the cache
    update so the next call re-converges. *)

val on_serving_last_known_good : reason:string -> unit
(** Tick the serving-last-known-good counter for one [inspect_active]
    invocation that returned [Serving_last_known_good].  [reason] must
    be one of [path_unresolved], [validation_failed],
    [stale_rejection_cached]. *)

val on_lkg_recovery : unit -> unit
(** Tick once per [inspect_active] call that transitions out of
    [Serving_last_known_good] back to [Validated] (operator fixed the
    cascade.toml fault). *)

val on_profile_candidate_drop : cascade:string -> reason:string -> unit
(** Tick the per-cascade candidate drop counter at [validate_profile_static]
    when [Cascade_config.parse_weighted_entry_diag] rejects an entry.
    [reason] must be one of [unregistered_scheme], [unavailable_scheme],
    [invalid_syntax]. *)

val on_resolve_provider_leak : cascade:string -> leak_count:int -> unit
(** Tick the resolve-leak counter at [resolve_named_providers] when
    the returned Provider_config.t list contains entries not present
    in the parsed declared profile.  Bumps by [leak_count] (number of
    leaked entries observed in this single resolve call); a [leak_count]
    of zero is a no-op so callers can call unconditionally. *)

val on_route_config_error : error_type:string -> count:int -> unit
(** Tick the route schema-error counter at [validate_path_result] for
    each rejection class folded into [top_errors].  [error_type] must
    be one of [missing_target_profile] (a [\[routes\]] entry points
    at a profile that doesn't exist) or [unknown_route_key] (a
    [\[routes\]] key isn't in the known_route_keys allowlist —
    typo or deprecated key).  Bumps by [count] (number of errors
    of that type in this single validate call); a [count] of zero
    is a no-op so callers can call unconditionally. *)
