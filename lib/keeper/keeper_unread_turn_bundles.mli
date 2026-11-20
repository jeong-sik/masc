(** The bundles that turn-log lines a Keeper's Memory writer has yet to read
    point at (RFC librarian-call-only-proposes §5.6).

    A [Closed] or [Reset] line names its content as slices of checkpoint
    bundles. A purge or a history clear afterwards writes a new head, and the
    startup object sweep keeps only what some root reaches. These bundles are
    roots too, so an unread line still reads the content it had when it was
    written.

    The first unread line is the [turn_log_offset] of the writer's commit log
    tail. It counts only when the tail names this turn log and the offset
    starts one of its lines. Otherwise, and when the tail cannot be read,
    every line of the turn log counts. A [Closed] line's bundles belong to the
    session of its [after] trace, a [Reset] line's to that of its [before]
    trace. *)

type error =
  | Listing_failed of
      { path : string
      ; detail : string
      }
  | Turn_log_unreadable of
      { keeper : string
      ; detail : string
      }
  | Line_undecodable of
      { keeper : string
      ; offset : int
      }

val error_to_string : error -> string

(** A session, and a bundle in it that an unread line points at. *)
type root =
  { session : string
  ; bundle : Agent_core.Checkpoint_objects.digest
  }

(** [read ~turns_dir ~memory_dir] reads the turn log in each directory under
    [turns_dir], with the commit log of the same Keeper under [memory_dir].
    A directory with no turn log has no root. A turn log that cannot be read,
    or one of its counted lines that does not decode, is an error: what it
    points at is unknown. *)
val read : turns_dir:string -> memory_dir:string -> (root list, error) result
