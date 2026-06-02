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

let to_string = function
  | Debug -> "debug"
  | Info -> "info"
  | Warning -> "warning"
  | Error -> "error"
  | Critical -> "critical"

let of_string = function
  | "debug" -> Ok Debug
  | "info" -> Ok Info
  | "warning" | "warn" -> Ok Warning
  | "error" | "bad" -> Ok Error
  | "critical" | "fatal" -> Ok Critical
  | other -> Error ("unknown severity: " ^ other)

let of_string_default ~default s =
  match of_string s with Ok v -> v | Error _ -> default

(** Numeric ordering: Debug=0 .. Critical=4.
    Higher is more severe. *)
let to_int = function
  | Debug -> 0
  | Info -> 1
  | Warning -> 2
  | Error -> 3
  | Critical -> 4

let compare a b = Int.compare (to_int a) (to_int b)

(** [at_least ~threshold s] is [true] when [s >= threshold]. *)
let at_least ~threshold s = to_int s >= to_int threshold
