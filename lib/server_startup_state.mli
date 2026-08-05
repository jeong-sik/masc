(** Server_startup_state — In-memory singleton that tracks which
    startup phase the server is in, plus the pending lazy-task list, errors,
    and path/config
    resolution snapshots.

    The state is a process-global mutable [ref]. All observers and
    mutators go through this module so [to_yojson] can render a
    consistent snapshot. *)

(** {1 Types} *)

type phase =
  | Blocking    (** Bootstrapping — HTTP not serving yet *)
  | Lazy        (** Serving, but some background tasks still pending *)
  | Ready       (** Fully ready *)
  | Degraded    (** A lazy task failed; serving with [last_error] set *)

(** Wire string: ["blocking" | "lazy" | "ready" | "degraded"]. *)
val phase_to_string : phase -> string

(** Singleton record. Exposed because a handful of callers use
    [Server_startup_state.((!state).state_ready)] etc. instead of
    going through a getter. Prefer {!is_live} / {!to_yojson} /
    {!elapsed_since_start} for new code. *)
type t = {
  phase : phase;
  state_ready : bool;
  pending_lazy_tasks : string list;
  last_error : string option;
  path_diagnostics : Yojson.Safe.t option;
  config_resolution : Yojson.Safe.t option;
  started_at : float;
}

(** Process-global state reference. Observers should prefer the
    typed accessors above; [state] is exposed only to preserve the
    existing [(!state)] call sites. *)
val state : t ref

(** {1 Observation} *)

(** [true] once the HTTP accept loop can serve requests (always
    [true] after socket bind). *)
val is_live : unit -> bool

val pending_lazy_tasks : unit -> string list

(** [true] iff {!pending_lazy_tasks} is empty. *)
val lazy_tasks_complete : unit -> bool

(** Seconds elapsed since startup began. *)
val elapsed_since_start : unit -> float

(** Default startup watchdog timeout in seconds
    ([MASC_STARTUP_WATCHDOG_SEC] default). *)
val default_watchdog_timeout_sec : float

(** Effective watchdog timeout from env, clamped to [[30, 600]]. *)
val watchdog_timeout_sec : unit -> float

(** Seconds a blocking init step may spend before the startup watchdog would
    exit the process, with [reserve_sec] set aside for the boot stages that
    run after that step. Clamped at [0.] so a caller that is already over
    budget is told to skip rather than handed a negative deadline. Deriving a
    sub-budget here keeps it tied to {!watchdog_timeout_sec} instead of
    drifting as an independent constant. *)
val remaining_watchdog_budget_sec : reserve_sec:float -> float

(** Current snapshot as JSON:
    [{phase, state_ready, pending_lazy_tasks,
      last_error, path_diagnostics,
      config_resolution, elapsed_sec, watchdog_timeout_sec}]. *)
val to_yojson : unit -> Yojson.Safe.t

(** {1 Transitions} *)

(** Reset to [Blocking] / not-ready. *)
val reset : unit -> unit

val mark_blocking : unit -> unit

type state_ready_transition_stage =
  | Boot_completion
  | Readiness_publication

type state_ready_error =
  | State_ready_transition_rejected of
      { stage : state_ready_transition_stage
      ; reason : string
      }

val state_ready_error_to_string : state_ready_error -> string

(** Complete the lifecycle and publish readiness as one validated state
    update. No partial transition is stored
    when any product invariant rejects the publication. *)
val mark_state_ready : unit -> (unit, state_ready_error) result

(** Record the lazy-task inventory while startup is still blocking. This does
    not publish readiness or transition the server lifecycle to [Serving]. It
    lets Keeper autoboot observe the complete lazy-task barrier before the
    queue consumer ACK permits readiness publication. *)
type lazy_prepare_error =
  | Lazy_state_transition_rejected of string

val lazy_prepare_error_to_string : lazy_prepare_error -> string

val prepare_lazy_tasks : tasks:string list -> (unit, lazy_prepare_error) result

(** Remove [task] from pending. When the list empties, transition
    to [Ready] (unless already [Degraded], which is preserved). *)
val finish_lazy_task : task:string -> unit

(** Remove [task], set [phase = Degraded] and record [error] in
    [last_error]. *)
val fail_lazy_task : task:string -> error:string -> unit

val mark_degraded : error:string -> unit

(** Persist path-diagnostics and config-resolution JSON snapshots
    for the next {!to_yojson} call. *)
val note_runtime_resolution :
  path_diagnostics:Yojson.Safe.t ->
  config_resolution:Yojson.Safe.t ->
  unit
