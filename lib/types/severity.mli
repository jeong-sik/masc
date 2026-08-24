(** Severity — canonical severity levels shared across MASC modules.

    Domain-specific severity types ([Response.severity],
    [Failure_envelope.severity], [Dashboard_attention.severity])
    remain for backwards compatibility; each provides a
    [to_severity] coercion for cross-module communication.

    @since SSOT audit 2026-04-09, closes #5989 *)

type t =
  | Debug
  | Info
  | Warning
  | Error
  | Critical
[@@deriving show, eq, yojson]

val to_string : t -> string
(** Lowercase canonical name ([{Debug → "debug"}], …). *)

val of_string : string -> (t, string) result
(** Parse a severity name. Aliases recognized:
    ["warn" → Warning], ["bad" → Error], ["fatal" → Critical].
    Returns [Error msg] for unknown inputs. *)

val to_int : t -> int
(** Numeric ordering [{Debug = 0 .. Critical = 4}]; higher is more severe. *)

val compare : t -> t -> int
(** Total order on severity, by {!to_int}. *)

