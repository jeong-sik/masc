(** Fact changes in the compacted archive and live commit log. The chronological
    projection powers the diff. The historical-search projection shows only the
    last removal of each fact that is still absent from current Memory. *)

open Keeper_memory_os_types

type left =
  { fact : fact (** As Memory held it when it left. *)
  ; removal : Librarian_effects.removal
  ; at : float (** When the line that removed it was committed. *)
  ; line_at : int (** Byte offset of that line in the commit log (or 0 in cold archive). *)
  }

type t =
  { left : left list
  ; unreadable : int
  }

(** Serialize cold-archive reads and [compact_log] rewrites for the same
    commit-log path across domains/fibers in this process. *)
val with_path_lock : log_path:string -> (unit -> 'a) -> 'a

(** Old sidecars record a removal and its time. New sidecars store the exact
    sequence, revision, source and added/removed facts of each commit. A
    conflicting sequence is excluded and counted as unreadable. *)
type history =
  { unsequenced : left list
  ; changes : Librarian_memory_change.t list
  ; unreadable : int
  ; live_lines : int
  }

val history_unlocked : string -> (history, Private_jsonl_scan.error) result
val history : string -> (history, Private_jsonl_scan.error) result
val left_of_history : history -> current:fact list -> t
val write_history : archive_path:string -> history -> (unit, string) result

(** [current] is the Memory the snapshot holds now. Reads the live commit log
    first and then the cold compacted archive (if present), replaying the live
    log on top of cold entries so concurrent log compaction can never drop an
    entry in the gap between archive write and log rewrite. *)
val read : string -> current:fact list -> (t, Private_jsonl_scan.error) result
