(** The facts that left a Keeper's Memory, read from its cold compacted
    archive sidecar (if present) plus the post-checkpoint tail of its commit
    log ([<keeper>.memory-log.jsonl]).

    After {!Librarian_store.compact_log} checkpoints the commit log, reading
    the archive avoids O(all-history) byte-0 scans of the live log: cold
    removals are served from [<keeper>.memory-archive.jsonl] and only commits
    after the latest [Checkpoint] baseline are folded from the live log. *)

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

(** Same as {!read} when the caller already holds {!with_path_lock} for [path]. *)
val read_unlocked : string -> current:fact list -> (t, Private_jsonl_scan.error) result

(** [current] is the Memory the snapshot holds now. Reads the live commit log
    first and then the cold compacted archive (if present), replaying the live
    log on top of cold entries so concurrent log compaction can never drop an
    entry in the gap between archive write and log rewrite. *)
val read : string -> current:fact list -> (t, Private_jsonl_scan.error) result

(** Atomically persist compacted cold archive entries to [archive_path]
    (one JSON object per line). *)
val write_cold_archive : archive_path:string -> left list -> (unit, string) result
