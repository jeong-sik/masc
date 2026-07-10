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

val append_jsonl : path:string -> Yojson.Safe.t -> unit
(** Append one JSON value as a JSONL row using the common per-path writer. *)

val append_jsonl_durable : path:string -> Yojson.Safe.t -> unit
(** Append one JSON value and fsync the file before returning. *)

val append_dated_jsonl :
  base_dir:string -> ts:float -> Yojson.Safe.t -> dated_path
(** Append one JSON value to the timestamp-selected dated path and return the
    path that was written. *)
