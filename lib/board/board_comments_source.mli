(** Exact comments source observations and writes for one captured store.
    Caller owns persistence. IO never acquires a Board mutex recursively. *)
open Board_types

type read =
  | Complete of {
      observation : comments_source_observation;
      comments : comment list;
      diagnostics : comments_source_diagnostic list;
    }
  | Partial of {
      observation : comments_source_observation;
      comments : comment list;
      errors : comments_row_error list;
      diagnostics : comments_source_diagnostic list;
    }
  | Unavailable of {
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
  | Display_only of {
      comments : comment list;
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
(** Display-only complete prefix rows have no stable snapshot, durability or
    mutation/negative-read authority. A torn tail never permits truncation. *)

val read : store -> read
val publish_read : store -> read -> unit
(** Publish only after the state callback returns normally. Complete reads
    replace the complete comments model/index; partial rows remain display-only.
    Plain read/reload cannot clear an unknown write or unfinished publication. *)
val fail_read : store -> read -> stage:comments_source_stage ->
  exn -> Printexc.raw_backtrace -> read
val read_diagnostics : read -> comments_source_diagnostic list
val finish_read : read -> (unit, board_error) result

type 'a write_outcome =
  | Written of { value : 'a; diagnostics : comments_source_diagnostic list }
  | Not_written of {
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
  | Unknown of {
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
val write_diagnostics : 'a write_outcome -> comments_source_diagnostic list
val finish_write : 'a write_outcome -> ('a, board_error) result
(** Preserve the original reserved cause through the shared Board carrier.
    The carrier retains actual write success versus failure, including cleanup. *)

type append_receipt
val append : store -> admission:Board_comment_admission.t -> comment -> append_receipt write_outcome
(** Known success retains [Comments_publishing] and the actual resulting cursor
    paired with this call's intended bytes. It never substitutes a reread.
    Guard refusal means the append never ran. Executed guards preserve the
    actual append result and inner-to-outer cleanup diagnostics. *)
val publish_append : store -> append_receipt -> unit write_outcome
(** Acknowledge the exact store-owned receipt after a normal state callback.
    Rejected publication must first record the owned row's cleanup as dirty.
    Projection exceptions leave publishing evidence and deny ordinary writes. *)

type snapshot
val capture : store -> snapshot
(** Capture rows and their exact source expectation under persist then state. *)
val rewrite : store -> snapshot -> unit write_outcome
(** Stale captures, source identity/bytes changes and failed loads never grant
    rewrite authority. Proven transient nonwrites retain the prior expectation. *)

val require_readable : store -> (unit, board_error) result
val failure_to_board_error : comments_source_failure -> board_error
val diagnostic_to_string : comments_source_diagnostic -> string
val reserved_diagnostics : comments_source_diagnostic list ->
  (exn * Printexc.raw_backtrace) option

val settle : store -> comments_recovery_receipt option write_outcome
(** Explicit recovery of an unknown write. Fence a fresh snapshot with a durable
    exact-snapshot rewrite of those same bytes; never replay the old intended
    bytes or classify the old operation as written/nonwritten. Success retains
    the completed receipt before finishing can raise. Explicitly acknowledge
    receipt ownership, then perform a full model reload. Missing after a
    Present expectation is refused. Publishing is not storage uncertainty and
    cannot be cleared here. Some returns the interrupted operation and actual
    fence for caller retention; None means no unsettled write required IO. *)
val acknowledge_recovery : store -> comments_recovery_receipt -> (unit, board_error) result
(** Consume only the exact store-owned completed receipt once. The caller has
    received and retains the receipt; source authority still needs full reload. *)
