(** Server_startup_state — In-memory singleton that tracks which
    startup phase the server is in, plus backend identification,
    pending lazy-task list, error/fallback notes, and path/config
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
  backend_mode : string;
  pending_lazy_tasks : string list;
  last_error : string option;
  fallback_reason : string option;
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

(** Current snapshot as JSON:
    [{phase, state_ready, backend_mode, pending_lazy_tasks,
      last_error, fallback_reason, path_diagnostics,
      config_resolution, elapsed_sec, watchdog_timeout_sec}]. *)
val to_yojson : unit -> Yojson.Safe.t

(** {1 Transitions} *)

(** Reset to [Blocking] / not-ready. [backend_mode] defaults to
    ["unknown"]. *)
val reset : ?backend_mode:string -> unit -> unit

val mark_blocking : backend_mode:string -> unit

type ready_backend =
  | Memory_backend
  | Filesystem_backend

val ready_backend_to_string : ready_backend -> string

type state_ready_transition_stage =
  | Boot_completion
  | Backend_resolution
  | Readiness_publication

type state_ready_error =
  | State_ready_transition_rejected of
      { stage : state_ready_transition_stage
      ; reason : string
      }

val state_ready_error_to_string : state_ready_error -> string

(** Complete the lifecycle, resolve the exact initialized backend, and publish
    readiness as one validated state update. No partial transition is stored
    when any product invariant rejects the publication. *)
val mark_state_ready : backend:ready_backend -> (unit, state_ready_error) result

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

(** Record the fallback reason (e.g. ["using filesystem backend
    because PG unreachable"]). *)
val note_fallback : string -> unit

(** Persist path-diagnostics and config-resolution JSON snapshots
    for the next {!to_yojson} call. *)
val note_runtime_resolution :
  path_diagnostics:Yojson.Safe.t ->
  config_resolution:Yojson.Safe.t ->
  unit
