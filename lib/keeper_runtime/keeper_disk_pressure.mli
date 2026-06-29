(** Process-local disk exhaustion guard. *)

type disk_snapshot = {
  path : string;
  filesystem : string;
  total_bytes : int;
  used_bytes : int;
  available_bytes : int;
  capacity_percent : float;
  available_percent : float;
  mounted_on : string;
}

type snapshot_result =
  | Snapshot of disk_snapshot
  | Probe_error of string

type admission_block =
  | Disk_pressure_cooldown of float
  | Disk_probe_error of { detail : string }
  | Disk_free_space_low of {
      path : string;
      available_bytes : int;
      min_free_bytes : int;
      effective_min_free_bytes : int;
      available_percent : float;
      min_free_percent : float;
      percent_floor_max_bytes : int;
    }

type admission_decision =
  | Admit
  | Block of admission_block

val is_disk_exhaustion_text : string -> bool
val is_disk_exhaustion_exn : exn -> bool
val note_if_disk_exhaustion : ?site:string -> string -> unit
val note_exception : ?site:string -> exn -> unit
val active : ?now:float -> unit -> bool
val remaining_sec : ?now:float -> unit -> float
val reset_for_tests : unit -> unit
val probe_path : ?now:float -> string -> snapshot_result
val probe_masc_root : ?now:float -> masc_root:string -> unit -> snapshot_result
val admission_decision_of_snapshot : ?now:float -> snapshot_result -> admission_decision
val admission_decision : ?now:float -> masc_root:string -> unit -> admission_decision
val admit_turn : ?now:float -> masc_root:string -> unit -> bool
val disk_snapshot_to_json : disk_snapshot -> Yojson.Safe.t
val snapshot_result_to_json : snapshot_result -> Yojson.Safe.t
val admission_block_to_json : admission_block -> Yojson.Safe.t
val admission_decision_to_json : admission_decision -> Yojson.Safe.t

(** Stable kind tag per block constructor (mirrors
    {!Keeper_fd_pressure.admission_block_kind}). Display/skip-reason only;
    the sum type is the source of truth, the string is never parsed back. *)
val admission_block_kind : admission_block -> string

(** Human-readable one-line summary with the typed numbers (no df re-probe). *)
val admission_block_summary : admission_block -> string

val snapshot_json : ?now:float -> masc_root:string -> unit -> Yojson.Safe.t

module For_testing : sig
  val reset : unit -> unit
  val is_disk_exhaustion_text : string -> bool
  val is_disk_exhaustion_exn : exn -> bool
  val admission_decision_of_snapshot : ?now:float -> snapshot_result -> admission_decision
end
