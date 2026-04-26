(** Shutdown — Structured graceful shutdown with defined phases.

    Phases execute in order:
    1. Notify  — Broadcast shutdown intent to connected clients
    2. Drain   — Wait for in-flight requests to complete (configurable timeout)
    3. Cleanup — Run registered hooks (cancel fibers, flush state, save checkpoint)
    4. Exit    — Terminate the Eio switch

    @since 2.102.0 *)

(** {1 Configuration} *)

type config =
  { notify_delay_s : float
  ; drain_timeout_s : float
  ; cleanup_timeout_s : float
  ; force_timeout_s : float
  }

val default_config : config
val config_from_env : unit -> config

(** {1 Phase Tracking} *)

type phase =
  | Running
  | Notifying
  | Draining
  | Cleaning
  | Exiting
  | Done

val phase_to_string : phase -> string

type state

val create : ?config:config -> unit -> state

(** {1 Hook Registry} *)

type hook =
  { name : string
  ; priority : int
  ; action : unit -> unit
  }

val register : name:string -> ?priority:int -> (unit -> unit) -> unit
val sorted_hooks : unit -> hook list

(** {1 Global Shutdown Flag} *)

val is_shutting_down_global : unit -> bool

(** {1 Phase Execution} *)

val initiate
  :  state
  -> clock:'a Eio.Time.clock
  -> reason:string
  -> notify_fn:(string -> unit)
  -> drain_check:(unit -> bool)
  -> exit_fn:(unit -> unit)
  -> unit

(** {1 Queries} *)

val current_phase : state -> phase
val is_shutting_down : state -> bool
val elapsed : state -> float
