(** Per-cascade inference parameters from cascade.json.

    Reads optional temperature and max_tokens fields from the same
    cascade.json used by OAS Cascade_config for model selection.
    This allows keeper and other MASC modules to delegate inference
    parameter decisions to the cascade configuration.

    Resolution order:
    1. cascade.json "{name}_temperature" / "{name}_max_tokens"
    2. cascade.json "default_temperature" / "default_max_tokens"
    3. Caller-provided fallback

    @since v2.128.0 — #2408 Phase 3 keeper inference delegation *)

(** Inference parameters resolved from cascade config. *)
type t = {
  temperature : float option;
  max_tokens : int option;
}

(** No inference parameters specified. *)
val empty : t

(** Load inference parameters for a named cascade profile.

    Reads from cascade.json located via {!Model_spec.cascade_config_path}.
    Keys follow the pattern: "{name}_temperature", "{name}_max_tokens".
    Falls back to "default_temperature" / "default_max_tokens" when the
    named key is absent. Returns {!empty} when no config file is found. *)
val for_cascade : name:string -> t

(** Extract inference parameters from a parsed JSON value.
    Same resolution logic as {!for_cascade} but operates on an in-memory
    JSON value instead of reading from disk. Useful for testing. *)
val for_json : name:string -> Yojson.Safe.t -> t

(** Resolve a temperature value with cascade config priority.
    Returns cascade config value if present, otherwise calls [fallback]. *)
val resolve_temperature : cascade_name:string -> fallback:(unit -> float) -> float

(** Resolve a max_tokens value with cascade config priority.
    Returns cascade config value if present, otherwise calls [fallback]. *)
val resolve_max_tokens : cascade_name:string -> fallback:(unit -> int) -> int

(** {1 Low-level helpers (exposed for testing)} *)

(** Read a float field from a JSON object. Returns [None] if absent or wrong type. *)
val read_float_field : Yojson.Safe.t -> string -> float option

(** Read an int field from a JSON object. Returns [None] if absent or wrong type. *)
val read_int_field : Yojson.Safe.t -> string -> int option
