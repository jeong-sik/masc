(** Declarative cascade TOML parser (RFC-0058 v2).

    Parses the 5-layer declarative TOML schema into typed config.
    See RFC-0058 §3 for the TOML schema specification. *)

open Cascade_declarative_types

type parse_error = {
  path : string;   (** TOML path where the error occurred *)
  message : string;
}
[@@deriving show]

val parse_string : string -> (cascade_config, parse_error list) result
(** Parse a TOML string into a declarative config.
    Returns [Ok config] on success, [Error errors] with all
    parse errors found. *)

val parse_file : string -> (cascade_config, parse_error list) result
(** Parse a TOML file into a declarative config. *)

(** {1 Internal: protocol resolution} *)

val api_format_of_protocol : string -> (cascade_api_format, string) result
(** Map a TOML protocol string to a [cascade_api_format] variant. *)

val transport_of_provider :
  Otoml.t -> string -> (cascade_transport, string) result
(** Extract transport (Http or Cli) from a provider TOML table. *)
