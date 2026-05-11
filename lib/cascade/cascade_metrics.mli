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
