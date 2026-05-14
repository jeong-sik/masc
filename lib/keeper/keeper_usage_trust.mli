(** Shared trust classification for LLM usage telemetry. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

val classify :
  usage_reported:bool ->
  usage:Agent_sdk.Types.api_usage ->
  model_used:string ->
  resolved_model_id:string ->
  context_max:int ->
  t

val is_trusted : t -> bool

val to_string : t -> string

val reasons : t -> string list

val warns_operator : t -> bool
(** [true] when the trust anomaly should be operator-visible as WARN.

    A pure zero-token report is an untrusted usage shape, but several
    CLI/runtime lanes legitimately cannot report token usage. It remains
    counted and serialized as untrusted, but should not page operators via
    WARN unless another anomaly reason is present. *)

val json_fields : t -> (string * Yojson.Safe.t) list
