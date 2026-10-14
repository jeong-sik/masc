(** Shared JSONL writer primitives.

    This module owns the UTC calendar day that date-split JSONL stores file
    rows under, and the append primitive. The day-file path of a store is
    [Dated_jsonl.Store.dated_path]. *)

val utc_calendar_day : ts:float -> int * int * int
(** [(year, month, day)] of [ts] in UTC. The day file a date-split store
    writes to and {!day_key} both come from this one [Unix.gmtime] call. *)

val day_key : ts:float -> string
(** ["YYYY-MM-DD"] naming the same UTC day whose file
    [Dated_jsonl.Store.dated_path] picks for [ts].

    This is the key [Dated_jsonl.read_range ~since ~until] splits back into
    month and day to select files, so a reader that derives it independently
    is one edit away from filtering a layout the writer does not produce.

    Not for [Log]'s ring, which names flat [system_log_YYYY-MM-DD.jsonl]
    files and shares only the format, not the layout. *)

val append_jsonl : path:string -> Yojson.Safe.t -> unit
(** Append one JSON value as a JSONL row using the common per-path writer. *)
