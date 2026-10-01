(** The Candle ledger file, [<base path>/.masc/candle-ledger.jsonl]
    (RFC-goal-candle-ledger 3.1).

    Rows are only ever appended. Every read and every append goes through one
    family of [Fs_compat] private JSONL functions (the cursor family), because
    that family's lock only excludes writers that use the same family. Appends
    fsync and roll back on failure.

    A row that does not read fails the whole read. Paying and buying refuse to
    run on a ledger nobody can read, so a bad row has to stop them, not be
    skipped. Settlement rows must also agree with preceding obligation,
    Snapshot and Candidates rows. Reads and appends use the same pure payout
    admission. *)

val path : base_path:string -> string

(** The ledger as one read saw it, and the position that read ended at. *)
type view

val events : view -> Candle_event.t list
(** In file order. *)

type read_error =
  | Store_failed of
      { path : string
      ; detail : string
      }
  | Row_rejected of
      { path : string
      ; line_number : int  (** From 1. *)
      ; detail : string
      }
  | Locked of { path : string }
      (** Another process holds the ledger's lock. The read did not wait for it. *)

val read_error_to_string : read_error -> string

val read : base_path:string -> (view, read_error) result
(** A missing file is an empty ledger. A file that ends inside a row is a
    {!Store_failed}: {!recover_at_start} is the only place that cuts it. *)

val recover_at_start : base_path:string -> (view, read_error) result
(** {!read} for server start only. A tail that ends inside a row, left by an
    append that never finished, is cut back to the last full row and the cut is
    fsynced, so appends can follow. *)

type 'error update_error =
  | Read_failed of read_error
  | Refused of 'error  (** The caller's [decide] returned [Error]. Nothing was written. *)
  | Event_unwritable of string
      (** An event would not read back, or a new [Paid] row does not satisfy
          the current payout arithmetic. Nothing was written. *)
  | Write_failed of
      { path : string
      ; detail : string
      }
  | Write_locked of { path : string }
      (** Another process took the ledger's lock between the read and the
          append. Nothing was written. *)

val update_error_to_string : ('error -> string) -> 'error update_error -> string

val update :
  base_path:string
  -> (view -> (Candle_event.t list * 'result, 'error) result)
  -> ('result, 'error update_error) result
(** Reads the ledger, lets [decide] look at it and name the events to append,
    and appends them if the file is still as it was read. If another writer
    appended first, nothing is written and [update] reads again and asks
    [decide] again, so [decide] must give an answer that depends only on the
    view it is given. There is no count or time limit: a round that fails this
    way means another writer finished one.

    A lock that another process holds is not waited for. [update] returns
    [Read_failed (Locked _)] or [Write_locked _] at once, and the caller decides
    whether to ask again later.

    An empty event list writes nothing. Any other failure, an unreadable file
    or a write that failed, is returned and not retried. New [Paid] rows pass
    {!Candle_payment.validate_for_append}; reading existing rows never invokes
    that check or changes their recorded allocations. *)
