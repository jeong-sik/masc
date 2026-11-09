(** Keeper_memory_recall — history/tail JSONL reading for memory surfaces.

    Disk history rows parse through [Keeper_context_core.message_of_json]:
    a row that fails (including old rows without content blocks) counts as
    unreadable rather than as empty text. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** {1 File Reading} *)

type tail_completion =
  | Complete
  | Partial_last_line
(** Whether the last returned line was newline-terminated in the file.
    [Partial_last_line] means an append was in flight during the read: the
    row is not lost, it is simply not finished yet. This is what separates a
    truncated write at the tail of an append-only log from real corruption,
    which [Read_drop_reason.Tail_partial_write] exists to classify. *)

type tail_lines = {
  lines : string list;  (** Oldest first. *)
  completion : tail_completion;
  from_file_start : bool;
      (** The read began at the file's first byte and kept every line, so the
          file held no line before [lines] when it was opened. *)
}

val read_file_tail_lines_with_completion :
  string -> max_bytes:int -> max_lines:int
  -> (tail_lines, Keeper_memory_recall_exn_class.t) result
(** As {!read_file_tail_lines_result}, and additionally reports both ends of
    the read: whether the final line was terminated, and whether the read
    reached the file's start. The window's leading partial line is already
    dropped by the reader. *)

val read_file_tail_lines_result :
  string -> max_bytes:int -> max_lines:int
  -> (string list, Keeper_memory_recall_exn_class.t) result
(** Result-returning tail reader.  [Ok []] covers both "no recorded
    memory" (file missing, or [max_lines <= 0]) and "empty file"; the
    caller cannot disambiguate at this entry point and should not try.
    [Error class] surfaces an IO/parse failure classified through the
    bounded {!Keeper_memory_recall_exn_class.t} closed sum so callers
    can branch on a typed value instead of inspecting a stringified
    exception (RFC-0149 §3.1).

    Use this entry point when the caller can produce a meaningful
    operator-visible signal on [Error] (e.g. propagate
    {b Memory_unavailable} up the chain instead of silently rendering
    an empty summary).

    @since RFC-0149 Phase 1 *)

val record_memory_recall_read_error :
  site:string -> string -> Keeper_memory_recall_exn_class.t -> unit
(** Emit the bounded read-failure metric and WARN line for call sites
    that intentionally degrade after consuming
    {!read_file_tail_lines_result}.  This is logging only; callers must
    choose their own degraded value explicitly. *)

(** {1 User Message Extraction} *)

val user_messages_newest_first : Agent_core.Types.message list -> string list
(** Visible User-role text excluding runtime-context carriers;
    invalid or duplicate carrier provenance is omitted with a diagnostic. *)

val load_history_user_messages_result :
  path:string ->
  limit:int ->
  accept:(string -> bool) ->
  (string list, Keeper_memory_recall_exn_class.t) result * int
(** Scan retained user messages newest-first until [limit] messages satisfy
    [accept], or the file ends. Internal History sources and runtime-context
    carriers remain excluded. Invalid or duplicate carrier provenance counts
    as an unreadable row rather than searchable User-role text.
    There is no raw-row or candidate-message cap. A missing file is [Ok []];
    other read failures are [Error class]. The second value counts visited
    rows that could not be decoded, including those visited before a failure.
    [accept] runs on the calling fiber. Its effects are not rolled back on
    [Error], so callers must keep tentative selection state local to this read. *)
