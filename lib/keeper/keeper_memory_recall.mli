(** Keeper_memory_recall — history/tail JSONL reading for memory surfaces.

    The keyword-classifier recall eval was removed with the legacy memory
    bank: recall is the keeper's own judgment via the [keeper_memory_search]
    tool, not a substring heuristic. *)

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

val read_file_tail_lines_with_completion :
  string -> max_bytes:int -> max_lines:int
  -> (string list * tail_completion, Keeper_memory_recall_exn_class.t) result
(** As {!read_file_tail_lines_result}, and additionally reports whether the
    final line was terminated. The window's leading partial line is already
    dropped by the reader; this covers the trailing end. *)

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

val recent_user_messages :
  Agent_core.Types.message list -> max_n:int -> string list

val load_history_user_messages_result :
  path:string ->
  max_n:int ->
  (string list, Keeper_memory_recall_exn_class.t) result
(** Typed history loader.  On [Error class] the caller can distinguish
    "no user messages in the history file" ([Ok []]) from "the history
    file read failed" ([Error class]).

    @since RFC-0149 §3.1 *)
