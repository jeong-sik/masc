(** Shared JSONL writer primitives.

    This module owns the low-level path layout and append primitive shared by
    date-split JSONL stores. Domain modules still own their schemas, retention
    policy, read models, and hash-chain semantics. *)

type dated_path =
  { base_dir : string
  ; month_dir : string
  ; day_file : string
  ; path : string
  }

(** Create a directory and its parents when missing. *)

val dated_path : base_dir:string -> ts:float -> dated_path
(** Return the [base_dir/YYYY-MM/DD.jsonl] path for a UTC timestamp. *)

val dated_path_now : base_dir:string -> dated_path
(** Return the dated path for the current UTC day. *)

val day_key : ts:float -> string
(** ["YYYY-MM-DD"] naming the same UTC day whose file {!dated_path} picks for
    [ts]. Both come from one [Unix.gmtime] call.

    This is the key [Dated_jsonl.read_range ~since ~until] splits back into
    month and day to select files, so a reader that derives it independently
    is one edit away from filtering a layout the writer does not produce.

    Not for [Log]'s ring, which names flat [system_log_YYYY-MM-DD.jsonl]
    files and shares only the format, not the layout. *)

val append_jsonl : path:string -> Yojson.Safe.t -> unit
(** Append one JSON value as a JSONL row using the common per-path writer. *)

val append_dated_jsonl :
  base_dir:string -> ts:float -> Yojson.Safe.t -> dated_path
(** Append one JSON value to the timestamp-selected dated path and return the
    path that was written. *)
