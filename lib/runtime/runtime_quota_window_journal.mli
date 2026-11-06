(** Provider-stated quota windows kept across server restarts.

    {!Runtime_quota_window} holds what providers said about their quota in
    process memory. A restart dropped it, so a Keeper whose every path rested
    on a stated window sent the refused account one more request after each
    boot: on 2026-11-06 three Keepers did so after the boots at 03:10:41Z,
    04:54:55Z and 05:36:05Z, two of them on a Muse quota stated to reset at
    2026-11-09T00:00:00Z.

    This store appends each stated window the table takes to one private
    JSONL file, {!path}, and reads them back before any Keeper starts. Rows
    are only appended, and only as rows the reader takes back: a window
    whose reset is not a finite number, or whose scope names an empty string,
    is logged and not written. A row whose reset has passed is not taken on
    read and stays in the file. A row this build cannot read is reported and
    not taken; it is never replaced by a default.

    Only stated windows reach the store ({!Runtime_quota_window.set_stated_window_sink}).
    An observation without a reset ends with the next success, which the
    store does not see, so keeping one would let a restart bring back a
    refusal that a later success had already answered. *)

val path : base_path:string -> string
(** [<base_path>/.masc/provider-quota-windows.jsonl]. *)

type row_error =
  | Not_json of
      { line : int
      ; message : string
      }
  | Malformed of
      { line : int
      ; error : Runtime_quota_window.stated_window_decode_error
      }
  | Incomplete_tail of { line : int }
      (** Bytes after the last newline: an append a crash cut short. The next
          append cuts them before it writes. *)

val row_error_to_string : row_error -> string

type restore_report =
  { ahead : int  (** Rows whose reset is still ahead; the table took them. *)
  ; passed : int  (** Rows whose reset had passed; not taken. *)
  ; rejected : row_error list  (** Rows not taken because they cannot be read. *)
  }

type restore_error =
  | Store_unreadable of
      { path : string
      ; detail : string
      }

val restore_error_to_string : restore_error -> string

val restore_then_record :
  base_path:string -> now:float -> (restore_report, restore_error) result
(** Read {!path}, note every readable window still ahead at [now] in
    {!Runtime_quota_window}, then install the sink that appends each window
    the table takes from now on. No sink is installed while the rows are
    noted, so restored windows are not appended again; a window another
    fiber notes in that span is held in memory only, which is why this runs
    before any Keeper walks. The sink is installed even when the store cannot
    be read, so windows stated after boot are still kept. A missing file is
    an empty store. *)
