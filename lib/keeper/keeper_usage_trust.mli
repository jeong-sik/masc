(** Shared trust classification for LLM usage telemetry. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

val classify :
  usage_reported:bool ->
  usage:Oas.Types.api_usage ->
  model_used:string ->
  resolved_model_id:string ->
  context_max:int ->
  t

val is_trusted : t -> bool

val to_string : t -> string

val reasons : t -> string list

val json_fields : t -> (string * Yojson.Safe.t) list
