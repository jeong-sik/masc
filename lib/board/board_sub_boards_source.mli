(** Exact source authority for sub-board policy. Caller owns persistence;
    filesystem work runs outside the Board state mutex. *)
open Board_types

type read =
  | Complete of {
      observation : sub_boards_source_observation;
      rows : sub_board list;
      diagnostics : sub_boards_source_diagnostic list;
    }
  | Partial of {
      observation : sub_boards_source_observation;
      rows : sub_board list;
      errors : sub_boards_row_error list;
      diagnostics : sub_boards_source_diagnostic list;
    }
  | Unavailable of {
      failure : sub_boards_source_failure;
      diagnostics : sub_boards_source_diagnostic list;
    }

val read : store -> read
val publish_read : store -> read -> unit
val fail_read : store -> read -> exn -> Printexc.raw_backtrace -> read
val finish_read : read -> (unit, board_error) result
(** Complete reload replaces both policy indexes. Partial rows are display
    data only. Neither reload nor an ordinary write clears an uncertain write
    or interrupted model publication; these require a fresh store. *)

type publication
type write =
  | Written of {
      publication : publication;
      diagnostics : sub_boards_source_diagnostic list;
    }
  | Not_written of {
      failure : sub_boards_source_failure;
      diagnostics : sub_boards_source_diagnostic list;
    }
  | Unknown of {
      failure : sub_boards_source_failure;
      diagnostics : sub_boards_source_diagnostic list;
    }

val append : store -> sub_board -> write
val rewrite : store -> string -> write
(** Rewrite bytes must be captured from the model in the same persistence
    interval. Both operations compare the exact loaded bytes and cursor under
    the existing stable file lock. They never adopt an after-write reread. *)
val acknowledge_publication : store -> publication -> (unit, board_error) result
(** Call only after normal model publication. Acknowledge the exact store-owned
    receipt. Until then all normal policy operations refuse. *)
val fail_publication : store -> publication -> exn -> Printexc.raw_backtrace -> 'a
(** Retain projection failure before propagating the original exception or a
    reserved cleanup cause. Does not clear known-success evidence. *)
val finish_write : write -> ('a, board_error) result -> ('a, board_error) result
(** Finish after model publication/acknowledgement on known success. Preserve
    the original reserved cleanup cause through the shared Board carrier. *)
val require_readable : store -> (unit, board_error) result
