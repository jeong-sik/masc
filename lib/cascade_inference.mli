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
    Returns cascade config value if present, otherwise calls [fallback]. *)
val resolve_max_tokens :
  cascade_name:Keeper_cascade_profile.runtime_name ->
  fallback:(unit -> int) ->
  int

(** Clamp max_tokens to provider ceiling.

    If [provider_ceiling] is [Some ceiling] and [max_tokens > ceiling],
    returns [ceiling]. Otherwise returns [max_tokens] unchanged.

    Clamping strategy: a smaller response is better than no response.
    Mirrors TLA+ KeeperCoreTriad.CapabilityGate action.

    @since Core Triad *)
val clamp_max_tokens_to_ceiling : provider_ceiling:int option -> int -> int
