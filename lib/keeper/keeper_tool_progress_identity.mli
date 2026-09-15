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

(** One matched ToolUse/ToolResult pair of a keeper's history. *)
type history_pair =
  { tool_name : string
  ; input : Yojson.Safe.t
  ; output_text : string
  }

(** The fingerprints of one keeper's previous history walk. *)
module History_memo : sig
  type t

  val create : unit -> t
end

(** The history memo of [keeper_name] under [base_path], created on first use
    and kept for the life of the process. *)
val history_memo : base_path:string -> keeper_name:string -> History_memo.t

(** [digest_history_pairs memo pairs] answers [digest_tool_io] for each pair, in
    order. A pair [memo] holds from the previous call is not recomputed. After
    the call [memo] holds exactly [pairs]. *)
val digest_history_pairs :
  History_memo.t -> history_pair list -> io_fingerprints option list

module For_testing : sig

end
