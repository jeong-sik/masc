(** Severity — Canonical severity levels shared across MASC modules.

    Domain-specific severity types (Response.severity, Failure_envelope.severity,
    Dashboard_attention.severity) remain for backwards compatibility.
    Each provides a [to_severity] coercion for cross-module communication.

    @since SSOT audit 2026-04-09, closes #5989 *)

type t =
  | Debug
  | Info
  | Warning
  | Error
  | Critical
[@@deriving show, eq, yojson]

let to_int = function
  | Debug -> 0
  | Info -> 1
  | Warning -> 2
  | Error -> 3
  | Critical -> 4

let compare a b = Int.compare (to_int a) (to_int b)

