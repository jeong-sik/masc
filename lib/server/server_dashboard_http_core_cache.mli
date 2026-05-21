(** Cache key, timeout, and projection diagnostics helpers for dashboard HTTP. *)

val dashboard_request_timeout_s : float
val shell_warmed : bool Atomic.t
val _shell_warmed : bool Atomic.t
val shell_warming : bool Atomic.t
val _shell_warming : bool Atomic.t
val last_good_shell : Yojson.Safe.t Atomic.t
val _last_good_shell : Yojson.Safe.t Atomic.t
val with_dashboard_timeout
  :  clock:_ Eio.Time.clock
  -> (unit -> Yojson.Safe.t)
  -> Yojson.Safe.t
val cache_partition_segment : Coord.config -> string
val dashboard_cache_key : Coord.config -> string -> string -> string
val dashboard_mission_timeout_s : float
val attach_projection_diagnostics : Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t

val projection_diagnostics_json
  :  surface:string
  -> started_at:float
  -> extra:(string * Yojson.Safe.t) list
  -> Yojson.Safe.t
  -> Yojson.Safe.t

val with_projection_diagnostics
  :  surface:string
  -> started_at:float
  -> extra:(string * Yojson.Safe.t) list
  -> Yojson.Safe.t
  -> Yojson.Safe.t

val initialized_json_opt : ?allow_initializing:bool -> Yojson.Safe.t -> Yojson.Safe.t option
