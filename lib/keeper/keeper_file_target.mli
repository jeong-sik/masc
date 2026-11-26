(** The file a completed Keeper filesystem tool call named, fixed by the
    producer when it executed.

    [relative_path] is {!Keeper_alerting_path.confined_relative_path} of the
    confined path the tool resolved. Every Keeper filesystem resolver confines
    to the Keeper's sandbox root alone, the same directory the server's
    [Ws_keeper] workspace scope reads from
    ({!Keeper_sandbox.host_root_abs_of_meta}), so the path names the same file
    there. [lines] are the lines of the current file the call touched, 1-based
    and inclusive. [None] means the producer has no such range; it is never
    filled from another source. *)

type t = private
  { relative_path : string
  ; lines : Keeper_file_change_evidence.line_range option
  }

val changed : Keeper_alerting_path.confined_path -> Keeper_file_change_evidence.t option -> t
(** A completed write or edit with the evidence it recorded. An overwrite
    carries its [new_range]. An edit carries the [new_range] of its first
    occurrence; a first occurrence that deleted its lines, and an edit whose
    ranges were omitted, carry none. No evidence (an append, an edit that
    changed nothing) carries none. *)

val read : Keeper_alerting_path.confined_path -> start_line:int -> returned_lines:int -> t
(** A completed read of [returned_lines] lines starting at [start_line].
    Zero lines carry no range. Raises [Invalid_argument] for a start below one
    or a negative count, which a parsed read window cannot produce. *)

val to_yojson : t -> Yojson.Safe.t
(** [{"path": relative_path, "lines": {"start_line", "end_line"}}]; [lines]
    is absent when there is no range. *)
