(** Declarative Runtime TOML parser (RFC-0206, runtime→Runtime rebirth).

    Re-homed from the deleted [Runtime_declarative_parser]. Parses only
    RFC-0058 layers 1-3 plus [\[runtime\].default] into a self-standing
    {!Runtime_schema.config}:

    - [\[providers.*\]] — Layer 1
    - [\[models.*\]] — Layer 2
    - [<provider>.<model>] binding tables — Layer 3
    - [\[runtime\].default] — the default Runtime id ([provider.model])

    The routing layers are intentionally NOT parsed: Layer 4 aliases
    ([<p>.<m>.<a>]), Layer 5 [\[routes\]]/[\[system\]]/[\[profiles\]], and the
    strategy/cycle-policy/scoring tables are dropped. A Runtime is a single
    pre-selected (provider × model) binding, so there is no routing
    indirection to model. *)

type parse_error =
  { path : string  (** TOML path where the error occurred *)
  ; message : string
  }
[@@deriving show]

val parse_string : string -> (Runtime_schema.config, parse_error list) result
(** Parse a TOML string into a Runtime config.
    Returns [Ok config] on success, [Error errors] with all
    parse errors found. *)

val parse_file : string -> (Runtime_schema.config, parse_error list) result
(** Parse a TOML file into a Runtime config. *)

(** {1 Internal: protocol resolution} *)

val api_format_of_protocol : string -> (Runtime_schema.api_format, string) result
(** Map a TOML protocol string to a {!Runtime_schema.api_format} variant. Only
    the canonical labels are accepted: [messages-cli], [messages-http],
    [openai-compatible-cli], [openai-compatible-http], [ollama-http]. The
    deprecated provider-letter aliases [provider_d-http] / [provider-d-cli]
    (renamed in v0.19.43) are rejected with an "unknown protocol" error — they
    are NOT silently canonicalized — so a checked-in config still using them
    fails to load. Locked by [test_legacy_protocol_alias_rejected]. *)

val transport_of_provider :
  Otoml.t -> string -> (Runtime_schema.transport, string) result
(** Extract transport ([Http] or [Cli]) from a provider TOML table. *)
