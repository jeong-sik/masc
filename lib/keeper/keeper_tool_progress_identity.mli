(** Opaque tool I/O fingerprints for observability. Typed JSON input is
    canonicalized by field order. Output text is redacted and hashed as bytes;
    JSON-looking content is never parsed and these values control no behavior. *)

type io_fingerprints =
  { input_fingerprint : string
  ; output_fingerprint : string
  }

val digest_tool_io :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  io_fingerprints option

module For_testing : sig
  val normalize_json : Yojson.Safe.t -> Yojson.Safe.t
end
