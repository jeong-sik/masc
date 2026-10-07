(** Opaque tool I/O fingerprints. Typed JSON input is canonicalized by field
    order. Output identity is the tool's answer ({!Keeper_tool_answer}): the
    repeated-call yield in [Keeper_agent_run] compares these fingerprints, so
    a receipt field that changes on every call must not name its identity. A
    tool whose answer is its whole output gets the canonical digest of the
    JSON, or the redacted byte hash of output that is not JSON. The answer is a
    function of the tool name and the output text, so the memo key and a
    history replay agree with the live call. Input identity keeps an opaque
    digest of [next_page_token] cursors outside secret-bearing parents so
    advancing pagination is not mistaken for a repeated call; observability
    JSON still masks those cursor values. *)

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
