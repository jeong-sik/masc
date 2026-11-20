(** The bundles the Keepers' turn logs name past where each Memory writer
    read, by session (RFC librarian-call-only-proposes §5.6). The checkpoint
    object sweep keeps them, so a line not yet read reads the content it was
    written with, whatever the session's heads hold since.

    A Keeper's turn log is [turns.jsonl] in its directory under
    [turns_dir]. Its unread lines start at the [turn_log_offset] of the tail
    line of its commit log in [memory_dir], when that line names the turn log
    the file's first line names and the offset starts a line of the file.
    Otherwise every line is read: no commit log, a tail line that does not
    read, another turn log's id, or an offset that is not a line start.

    A [Closed] line's slices are in the session of its [after.trace], and a
    [Reset] line's in that of its [before.trace], as the reader takes them. *)

type error =
  | Listing_failed of
      { path : string
      ; detail : string
      }
  | Turn_log_unreadable of
      { path : string
      ; detail : string
      }
  | Line_undecodable of
      { path : string
      ; offset : int
      }
  (** A line from where reading stands does not decode, so what it names is
      unknown. *)

val error_to_string : error -> string

(** The session's id to the hex digests of its bundles. Every Keeper
    directory under [turns_dir] with a turn log is read, whether the Keeper
    runs or not. *)
val read
  :  turns_dir:string
  -> memory_dir:string
  -> (Set.Make(String).t Map.Make(String).t, error) result
