(** Opaque tool I/O fingerprints. Typed JSON input is canonicalized by field
    order. Output identity is the tool's verified answer. Equal fingerprints
    identify equal answers; they do not prove that the application made no
    progress or authorize stopping a turn. Cursor values retain opaque identity
    outside secret-bearing parents while observability JSON masks them. *)

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
  type t
  val create : unit -> t
end

(** [digest_history_pairs memo pairs] answers [digest_tool_io] for each pair.
    Inline pairs are memoized under the base and exact bytes. Stored markers
    are reverified on every walk; without [base_path], declarations are ignored. *)
val digest_history_pairs :
  ?base_path:string -> History_memo.t -> history_pair list -> io_fingerprints option list

module For_testing : sig

end
