(** Shared Operator read diagnostics and failure retry cadence. Snapshot and
    Digest publication/cache authority belongs to their captured-scope owners. *)

val operator_refresh_interval_s : float
(** Existing failure-only retry interval; no successful idle scan. *)
val operator_snapshot_extra : unit -> (string * Yojson.Safe.t) list
