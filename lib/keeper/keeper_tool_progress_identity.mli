(** Stable tool-call progress identity for no-progress detection.

    A strong-evidence tool call only proves progress when it differs from the
    recent evidence stream. The identity deliberately includes normalized
    input/output digests, not just [(tool_name, typed_outcome)], so queue and
    batch processors that handle different items with the same tool/outcome do
    not look stalled. *)

type io_fingerprints =
  { input_fingerprint : string
  ; output_fingerprint : string
  }

type call =
  { tool_name : string
  ; typed_outcome : Keeper_tool_outcome.t option
  ; task_id : string option
  ; input_fingerprint : string option
  ; output_fingerprint : string option
  }

type t

val digest_tool_io :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  io_fingerprints option

val of_calls : call list -> t option
val equal : t -> t -> bool
val to_string : t -> string

module For_testing : sig
  val normalize_json : Yojson.Safe.t -> Yojson.Safe.t
end
