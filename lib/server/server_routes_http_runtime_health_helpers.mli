(** /health probe building blocks. *)

val server_start_time : float
val health_path_diagnostics : unit -> Server_base_path_diagnostics.t
val health_uptime_secs : unit -> int
val health_uptime_string : int -> string
val protocol_json : listener:string -> Yojson.Safe.t
val quick_gc_json : unit -> Yojson.Safe.t

val scheduler_json : unit -> Yojson.Safe.t
(** The main-domain scheduler-lag ring ([Scheduler_lag.global]) with the
    worker-domain count; the [/health] [scheduler] block. *)
