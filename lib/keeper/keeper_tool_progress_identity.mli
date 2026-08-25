(** Opaque tool I/O fingerprints. Typed JSON input is canonicalized by field
    order. Output that parses as JSON is canonicalized and digested with the
    measurement field ([execution_time_ms]) dropped at every depth — the
    repeated-call yield in [Keeper_agent_run] compares these fingerprints, so
    a field that measures the call must not name its identity. Output that is
    not JSON is redacted and hashed as bytes. *)

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

end
