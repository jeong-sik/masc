(** Per-cascade inference parameters — thin delegation to MASC Cascade_config.

    Delegates to MASC [Cascade_config.resolve_inference_params].
    TOML rendering, caching, and field extraction are handled by the local
    cascade module.

    Resolution order:
    1. cascade.toml "{name}_temperature" / "{name}_max_tokens"
    2. cascade.toml "default_temperature" / "default_max_tokens"
    3. Caller-provided fallback

    @since v2.128.0
    @since v2.149.0 — delegated to MASC Cascade_config *)

(** Inference parameters resolved from cascade config. *)
type t = {
  temperature : float option;
  max_tokens : int option;
  thinking_enabled : bool option;
  thinking_budget : int option;
}

(** No inference parameters specified. *)
val empty : t

(** Load inference parameters for a named cascade profile.
    Delegates to MASC [Cascade_config.resolve_inference_params]. *)
val for_cascade : name:string -> t

(** Extract inference parameters from a parsed JSON value.
    Same resolution logic as {!for_cascade} but operates on an in-memory
    JSON value instead of reading from disk. Useful for testing. *)
val for_json : name:string -> Yojson.Safe.t -> t

(** Resolve a temperature value with cascade config priority.
    Returns cascade config value if present, otherwise calls [fallback]. *)
val resolve_temperature :
  cascade_name:Keeper_cascade_profile.runtime_name ->
  fallback:(unit -> float) ->
  float

(** Resolve a max_tokens value with cascade config priority.
    Returns cascade config value if present, otherwise calls [fallback].
    Both cascade config values and fallback values are bounded to the
    resolved cascade's narrowest output ceiling when one is available;
    silent reductions emit a deduplicated WARN per
    (cascade, source, requested, ceiling) tuple. *)
val resolve_max_tokens :
  cascade_name:Keeper_cascade_profile.runtime_name ->
  fallback:(unit -> int) ->
  int

(** Cap a max_tokens value to the resolved cascade's narrowest output ceiling.

    Use this for internally supplied runtime overrides that bypass
    {!resolve_max_tokens}. [source] is emitted in the deduplicated WARN and
    metric context so operators can distinguish [cascade_config], [fallback],
    and [caller_override] clamps. *)
val cap_max_tokens_to_cascade_ceiling :
  cascade_name:Keeper_cascade_profile.runtime_name ->
  source:string ->
  int ->
  int

(** Validate max_tokens against the provider ceiling before dispatch.

    If [provider_ceiling] is [Some ceiling] and [max_tokens > ceiling],
    returns [Error _] instead of silently reducing the operator-supplied
    budget. Also rejects non-positive [max_tokens] and non-positive
    provider ceilings.

    Cascade-config, fallback, and keeper runtime override values are clamped
    upstream by {!resolve_max_tokens} or
    {!cap_max_tokens_to_cascade_ceiling}, so a violation here indicates
    either a non-positive budget, an invalid provider ceiling, or a cascade
    reload between resolve and validate.

    @since DD-020 (semantics revised 2026-05-17: cascade-config and fallback
    values are silently clamped upstream; internal keeper overrides should
    use the same clamp helper before dispatch.) *)
val validate_max_tokens_within_ceiling :
  cascade_name:Keeper_cascade_profile.runtime_name ->
  provider_ceiling:int option ->
  int ->
  (int, Cascade_error_classify.masc_internal_error) result

module For_testing : sig
  val reset_auto_max_tokens_clamp_warnings : unit -> unit

  val should_log_auto_max_tokens_clamp :
    cascade_name:Keeper_cascade_profile.runtime_name ->
    source:string ->
    max_tokens:int ->
    ceiling:int ->
    bool

  (** Pure clamp helper with an explicit ceiling — bypasses
      [Cascade_runtime.max_output_tokens_ceiling_of_cascade_name] so unit
      tests do not need a live cascade.toml on disk. Same arithmetic and
      same WARN dedup behavior as [resolve_max_tokens]'s internal clamp. *)
  val clamp_with_ceiling :
    cascade_name:Keeper_cascade_profile.runtime_name ->
    source:string ->
    ceiling:int option ->
    int ->
    int
end
