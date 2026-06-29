(** Process-local file-descriptor exhaustion guard. *)

type nofile_cache =
  | Uninitialized
  | In_flight
  | Resolved of int option

val nofile_soft_limit_cache : nofile_cache Atomic.t

type system_fd_snapshot = {
  open_files : int;
  max_files : int;
  max_files_per_process : int option;
}

type admission_block =
  | Fd_pressure_cooldown of float
  | Probe_unknown of {
      probe : string;
      active_keepers : int;
      starting_keepers : int;
      projected_fds : int;
    }
  | Projected_fd_budget_exhausted of {
      soft_limit : int;
      open_fds : int option;
      active_keepers : int;
      starting_keepers : int;
      projected_fds : int;
    }
  | System_fd_budget_exhausted of {
      open_files : int;
      max_files : int;
      remaining_files : int;
      required_headroom : int;
      projected_fds : int;
      active_keepers : int;
      starting_keepers : int;
    }
  | Host_fd_hotspot_budget_exhausted of {
      open_files : int;
      max_files_per_process : int;
      remaining_files : int;
      required_headroom : int;
      projected_fds : int;
      active_keepers : int;
      starting_keepers : int;
    }

type admission_decision =
  | Admit
  | Block of admission_block

type external_level =
  | External_warn
  | External_crit

val is_fd_exhaustion_text : string -> bool
val is_fd_exhaustion_exn : exn -> bool
val cooldown_sec : unit -> float
val cas_monotonic_max : atom:float Atomic.t -> float -> bool
val note : ?site:string -> ?detail:string -> unit -> unit
val note_if_fd_exhaustion : ?site:string -> string -> unit
val note_exception : ?site:string -> exn -> unit
val active : ?now:float -> unit -> bool
val remaining_sec : ?now:float -> unit -> float
val projection_fields : ?now:float -> unit -> (string * Yojson.Safe.t) list
val degraded_projection_json : ?now:float -> unit -> Yojson.Safe.t
val degraded_trust_json : ?now:float -> unit -> Yojson.Safe.t
val engage_external : reason:string -> level:external_level -> ts:float -> unit -> unit
val reset_for_tests : unit -> unit
val process_nofile_soft_limit : unit -> int option
val process_open_fd_count : unit -> int option
val min_nofile_for_fleet : unit -> int
val admission_decision :
  ?soft_limit:int option ->
  ?open_fds:int option ->
  ?system_fds:system_fd_snapshot option ->
  active_keepers:int ->
  starting_keepers:int ->
  unit ->
  admission_decision
val admission_block_to_json : admission_block -> Yojson.Safe.t
val admission_decision_to_json : admission_decision -> Yojson.Safe.t
val admission_block_kind : admission_block -> string

(** Human-readable one-line summary with the typed numbers (no re-probe);
    mirrors {!Keeper_disk_pressure.admission_block_summary}. *)
val admission_block_summary : admission_block -> string

val runtime_state_json :
  ?soft_limit:int option ->
  ?open_fds:int option ->
  ?system_fds:system_fd_snapshot option ->
  active_keepers:int ->
  starting_keepers:int ->
  requested_keepers:int ->
  unit ->
  Yojson.Safe.t
val admit_start :
  ?soft_limit:int option ->
  ?open_fds:int option ->
  ?system_fds:system_fd_snapshot option ->
  active_keepers:int ->
  starting_keepers:int ->
  unit ->
  bool
val admit_turn :
  ?soft_limit:int option ->
  ?open_fds:int option ->
  ?system_fds:system_fd_snapshot option ->
  active_keepers:int ->
  unit ->
  bool
val cap_active_keepers_for_nofile : ?soft_limit:int option -> int -> int
