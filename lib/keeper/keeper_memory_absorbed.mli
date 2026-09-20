(** Facts the librarian absorbed into a new claim (RFC-0456 §4.2).

    A fact a new claim names in [absorbs] leaves the current snapshot because
    the new claim now says it, not because it was wrong. Its row is kept here,
    in a per-keeper append-only [<keeper>.memory-absorbed.jsonl], so its text
    outlives the snapshot and [keeper_memory_search] (source [absorbed] or
    [all]) can still reach it. The librarian writes the rows under the snapshot
    lock, after the next snapshot is built and printed and right before it
    replaces the old one; a failed write fails the pass, so no absorbed fact
    leaves the snapshot without its row here. The file is never rewritten or
    trimmed.

    A replace that fails after its rows are written leaves rows for a pass
    that did not commit. Such a row names a fact that is still current, or
    repeats the [memory_id] and [into] of a row a later pass commits, or --
    when the fact later leaves the snapshot another way -- names an [into]
    that never became current. *)

type record =
  { recorded_at : float (** Unix seconds, the librarian pass's clock. *)
  ; trace_id : string (** The librarian pass; empty when there is none. *)
  ; memory_id : string (** The absorbed fact. *)
  ; into : string (** The new claim that absorbed it. *)
  ; fact : Keeper_memory_os_types.fact (** The absorbed row as the snapshot held it. *)
  }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** {1 Codec} *)

val record_to_json : record -> Yojson.Safe.t

(** Field-exact. [memory_id] must be the identity of [fact], [into] a memory
    identity other than [memory_id], and [recorded_at] finite. *)
val record_of_json : Yojson.Safe.t -> (record, Keeper_memory_os_types.wire_error) result

(** {1 Store} *)

type append_error =
  | Invalid_record of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val append_error_to_string : append_error -> string

(** Every record in one durable append -- fsynced, and rolled back when the
    write fails -- or an error and nothing written. A store that ends mid-line
    holds the remains of an append a crash cut short; the append cuts them back
    to the last complete line before it writes
    ([Fs_compat.append_private_jsonl_durable_locked_result]). An empty list
    writes nothing. *)
val append_all
  :  keepers_dir:string
  -> keeper_id:string
  -> record list
  -> (unit, append_error) result

type read_error =
  | Not_json of string
  | Malformed of Keeper_memory_os_types.wire_error
  | Incomplete_line
      (** The file's last line has no newline: an append that never
          completed. *)

val read_error_to_string : read_error -> string

(** Every line in file order, numbered as in the file, each decoded or
    rejected on its own. Read under the writer's lock, so no append is half
    visible. A missing file is no lines; a file that cannot be read is
    [Error]. *)
val read
  :  keepers_dir:string
  -> keeper_id:string
  -> ((int * (record, read_error) result) list, string) result
