(** Observation-only filesystem-space facts.

    This module never admits, delays, pauses, or rejects Keeper work. It
    records actual typed [ENOSPC] failures and exposes raw [df] observations. *)

type disk_snapshot =
  { path : string
  ; filesystem : string
  ; total_bytes : int
  ; used_bytes : int
  ; available_bytes : int
  ; capacity_percent : float
  ; available_percent : float
  ; mounted_on : string
  }

type snapshot_result =
  | Snapshot of disk_snapshot
  | Probe_error of string

val note_exception : ?site:string -> exn -> unit
(** Record and log only typed [Unix_error (ENOSPC, _, _)]. *)

val reset_for_tests : unit -> unit
val probe_path : ?now:float -> string -> snapshot_result
val probe_masc_root : ?now:float -> masc_root:string -> unit -> snapshot_result
val disk_snapshot_to_json : disk_snapshot -> Yojson.Safe.t
val snapshot_result_to_json : snapshot_result -> Yojson.Safe.t
val observation_fields : unit -> (string * Yojson.Safe.t) list
val snapshot_json : ?now:float -> masc_root:string -> unit -> Yojson.Safe.t

module For_testing : sig
  val reset : unit -> unit
end
