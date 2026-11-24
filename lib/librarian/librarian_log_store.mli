(** A Keeper's commit log on disk
    (RFC librarian-call-only-proposes §8.2 step 4, §8.6, §10): read the tail
    line, append at the end that was read, read every line from the first.

    The tail line is the last line that ends in a line break. Bytes after it
    are an append that was cut short. They were never a line: the tail stops
    before them and the next append cuts them. A file with no such line is a
    log that is not there.

    Every append names the end offset its caller read. An append whose end
    offset is no longer the end writes nothing. Nothing is kept in memory
    between calls. *)

val suffix : string
val archive_suffix : string

(** [keepers_dir] is the configuration's Keepers directory, where the
    snapshot is. *)
val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** Cold compacted archive sidecar path ([<keeper_id>.memory-archive.jsonl])
    storing historical removals flushed by log checkpoint compaction. *)
val archive_path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** Derive the cold archive sidecar path from a commit log path. *)
val archive_path_of_log_path : string -> string

type tail =
  | Nothing_written (** No file, or no complete line. *)
  | Written of
      { rows_end : int (** Just past the tail line. Append here. *)
      ; last_at : int (** Byte offset of the tail line. *)
      ; last : Librarian_log.line
      }

type undecodable =
  | Not_json
  | Malformed of Keeper_memory_os_types.wire_error

type read_error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Tail_undecodable of
      { offset : int
      ; rows_end : int (** Just past the line that does not decode. *)
      ; reason : undecodable
      }
  (** The tail line does not decode. Where reading stood was on that line,
      so nothing here says where to go on. *)
  | Moved_while_reading
  (** The second read did not find the line the first one ended at: the file
      was cut or replaced in between. *)

(** Reads the tail line and no line before it. *)
val read_tail : string -> (tail, read_error) result

type scanned =
  { at : int (** Byte offset of the line. *)
  ; line : (Librarian_log.line, undecodable) result
  (** A line that does not decode is given as such. It does not end the
      scan: a log an operator adopted past an unreadable tail keeps that
      line for good. *)
  }

(** Every complete line from the first, in order ({!Private_jsonl_scan}).
    No file is no line. *)
val fold
  :  string
  -> init:'acc
  -> f:('acc -> scanned -> 'acc)
  -> ('acc, Private_jsonl_scan.error) result

val fold_with_raw
  :  string
  -> init:'acc
  -> f:('acc -> scanned -> string -> 'acc)
  -> ('acc, Private_jsonl_scan.error) result
(** As {!fold}, with the original row bytes for lossless archival of decoding failures. *)

type append_error =
  | End_moved of
      { expected : int
      ; actual : int
      }
  (** The lines no longer end where the caller read them to end. Nothing was
      written. [actual] is the length of the file. It equals [expected] when
      the file was replaced by one of that length that ends in a fragment. *)
  | Directory_unavailable of
      { path : string
      ; detail : string
      }
  | Write_failed of
      { path : string
      ; detail : string
      }

type appended =
  { new_end : int
  ; at : int (** Byte offset of the line that was appended. *)
  }

(** Appends one line and makes it durable before it answers. [at_end] is
    [rows_end] of the tail the caller read, or [0] for [Nothing_written]. *)
val append
  :  path:string
  -> at_end:int
  -> Librarian_log.line
  -> (appended, append_error) result

(** Atomically replace the commit log with a single compacted checkpoint
    baseline line if the held end offset is still current, so future scans read only post-checkpoint commits. *)
val rewrite_compacted
  :  path:string
  -> at_end:int
  -> Librarian_log.line
  -> (appended, append_error) result
