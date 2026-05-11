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

val on_degraded_recovery : unit -> unit
(** Tick once per [inspect_active] call that transitions FROM a
    degraded state (either [Serving_last_known_good] from iter 5 or
    [Validated_with_rejections] from iter 11) back to [Validated]
    (operator fixed the cascade.toml fault).  Originally named
    [on_lkg_recovery] in iter 5 when only the LKG case existed;
    renamed in iter 16 after iter 11 broadened the
    [prev_was_failing] detection to include partial-rejection
    recovery. *)

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

val on_resolve_failure : cascade:string -> reason:string -> unit
(** Tick the resolve-failure counter for one [resolve_named_providers]
    or [resolve_named_providers_strict] invocation that returned
    [Error _].  [reason] must be one of [lookup_failed],
    [provider_filter_rejected], [no_callable_providers].  [cascade]
    uses the normalized cascade name when available, or the raw
    cascade_name argument when normalization itself failed
    ([lookup_failed] arm). *)

val on_validated_with_rejections : reason:string -> unit
(** Tick the validated-with-rejections counter for one [inspect_active]
    invocation that returned [Validated_with_rejections].  [reason]
    must be one of [fresh_partial_rejection] (validate_path_result
    newly produced a partial rejection on this call) or
    [stale_partial_rejection_cached] (same-mtime cache replay of a
    previously-cached partial rejection). *)

val on_provider_filter_widening : cascade:string -> unit
(** Tick the provider-filter widening counter for one
    [apply_provider_filter] (non-strict) invocation whose filter
    matched no provider in the declared set, causing the function
    to fall back to the unfiltered list.  A non-zero rate signals
    the operator-supplied filter is being silently widened with
    security / budget / SLA implications. *)

val on_auto_expansion_fanout : cascade:string -> fanout:int -> unit
(** Tick the [provider:auto] fan-out counter at
    [expand_weighted_entries] by [fanout] (= output_count -
    input_count).  [fanout=0] is a documented no-op so callers
    invoke unconditionally.  A [rate()] tracks how many extra
    candidates per cascade per second are synthesized by auto
    expansion. *)

val on_ordering_health_widening : cascade:string -> unit
(** Tick the ordering-step health-widening counter at
    [order_weighted_entries] when [Cascade_health_tracker] has cooled
    every provider (active = []) and the function falls back to the
    unfiltered [entries] list.  A non-zero rate signals the health
    tracker judged every provider in this cascade unhealthy yet
    keeper turns continue to route — either the health tracker is
    wrong or the cascade should fail closed. *)
