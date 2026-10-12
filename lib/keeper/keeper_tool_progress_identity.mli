(** Opaque tool I/O fingerprints. Typed JSON input is canonicalized by field
    order. Output identity is the tool's answer ({!Keeper_tool_answer}): the
    repeated-call yield in [Keeper_agent_run] compares these fingerprints, so
    a receipt field that changes on every call must not name its identity. A
    tool whose answer is its whole output gets the canonical digest of the
    JSON, or the redacted byte hash of output that is not JSON. The answer is a
    function of the tool name and verified output evidence, so the memo key and a
    history replay agree with the live call. Input identity keeps an opaque
    digest of [next_page_token] cursors outside secret-bearing parents so
    advancing pagination is not mistaken for a repeated call; observability
    JSON still masks those cursor values. *)

type io_fingerprints =
  { input_fingerprint : string
  ; output_fingerprint : string
  }

(** Stored semantic declarations require [base_path] and are recomputed from
    integrity-checked owned blob bytes on each call. Failure keeps blob identity. *)
val digest_tool_io :
  ?base_path:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  unit -> io_fingerprints option

(** One matched ToolUse/ToolResult pair of a keeper's history. *)
type history_pair =
  { tool_name : string
  ; input : Yojson.Safe.t
  ; output_text : string
  }

(** The fingerprints of one keeper's previous history walk. *)
module History_memo : sig
  type ledger_call =
    { position : Keeper_tool_call_index.position
    ; tool_use_id : string option
    ; tool_name : string
    ; fingerprints : io_fingerprints
    }
  type ledger_seed =
    { ledger_dir : string
    ; judged : Keeper_tool_call_index.frontier
    ; through : Keeper_tool_call_index.frontier
    ; calls : ledger_call list
    }
  type t
  val ledger_seed : t -> ledger_seed option
  val hold_ledger_seed : t -> ledger_seed -> unit
  (** Parsed fingerprint evidence shares the history memo's keeper/base owner.
      Setup replaces it at a yield and removes rows from retired ledger files.
      No tool input/output bodies are retained. *)

  val create : unit -> t
end

(** The history memo of [keeper_name] under [base_path], created on first use
    and kept for the life of the process. *)
val history_memo : base_path:string -> keeper_name:string -> History_memo.t

(** [digest_history_pairs memo pairs] answers [digest_tool_io] for each pair.
    Inline pairs are memoized under the base and exact bytes. Stored markers
    are reverified on every walk; without [base_path], declarations are ignored. *)
val digest_history_pairs :
  ?base_path:string -> History_memo.t -> history_pair list -> io_fingerprints option list

module For_testing : sig

end
