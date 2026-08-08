(** Provider kind sum type, split from [Provider_config] so it can be shared
    by {!Types.inference_telemetry} without introducing a
    [Provider_config <-> Types] dependency cycle.

    {!Provider_config} rebinds this type so [Provider_config.Anthropic],
    [Provider_config.string_of_provider_kind], etc. remain valid entry
    points for existing callers.

    @since 0.165.0 *)

type t =
  | Anthropic
  | Kimi
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
  | DashScope

(** All variants in declaration order. Maintained exhaustively alongside
    {!t}; adding a new variant without extending this list is a bug that
    the property test in [test_provider_config] flags immediately. Useful
    for QCheck generators, CLI completion, and iterative exhaustive
    checks. *)
val all : t list

(** Canonical environment variable conventionally consulted for the kind's
    API key (e.g. [Anthropic -> Some "ANTHROPIC_API_KEY"]). Returns [None]
    for kinds that do not have a universally-agreed env var — either the
    kind is local ({!Ollama}) or shares a space where
    OAS does not dictate the env name ({!OpenAI_compat}). *)
val default_api_key_env : t -> string option

(** Canonical lowercase wire form (e.g. [Anthropic -> "anthropic"]).
    Exhaustive — adding a new variant forces a compile error. *)
val to_string : t -> string

(** Tolerant configuration/CLI parser for the 7 known forms. Matching is
    case-insensitive and ignores leading/trailing whitespace. Durable codecs
    must use {!of_canonical_string}. *)
val of_string : string -> t option

(** Exact inverse of {!to_string} for durable codecs. Unlike {!of_string},
    this rejects case changes and surrounding whitespace. *)
val of_canonical_string : string -> t option

val pp : Format.formatter -> t -> unit
val show : t -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or
