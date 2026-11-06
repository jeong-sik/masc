(** The runtime history's rows, kept between reads.

    A one-pass read went through every Keeper's [decisions.jsonl] and every
    cost day file the window touched. Kept, each file is read whole the first
    time and afterwards only the rows it gained
    ({!Dated_jsonl.fold_file_appended_entries_result}); a rotated or rewritten
    file is read again from its start. Each read drops the rows that left the
    window, so a reading equals what a one-pass read at the same moment
    gives.

    The value is immutable: {!refresh} returns a new one. *)

open Model_inference_metrics_entry

type t

val empty : t

type reading =
  { entries : raw_entry list  (** One per inference, decisions and costs merged. *)
  ; cost_read : cost_read_result
  ; decision_read : (unit, decision_read_error) result
  }

val refresh : base_path:string -> now:float -> window_minutes:int -> t -> t * reading
(** Read what the files gained since [t] read them, and answer the window
    that ends at [now]. A decision log that does not read this time keeps what
    it said before and makes the reading [Decision_files_unreadable]. *)

val next_change : t -> window_minutes:int -> after:float -> float option
(** The first instant after [after] at which a kept row leaves the window, or
    a kept cost day file leaves its date range, so the answer changes with no
    write. *)
