(** Shared trust classification for LLM usage telemetry. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

val classify :
  usage_reported:bool ->
  usage:Agent_sdk.Types.api_usage ->
  t

val to_string : t -> string

val reasons : t -> string list

val warns_operator : t -> bool
(** [true] when a reported counter violates its objective non-negative
    invariant. Missing or zero-valued reports remain ordinary observations. *)

val json_fields : t -> (string * Yojson.Safe.t) list
