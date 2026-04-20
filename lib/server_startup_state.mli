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

val mark_state_ready : backend_mode:string -> unit

(** Transition to [Lazy] with [tasks] pending (or directly to
    [Ready] when [tasks = []]). *)
val activate_lazy : backend_mode:string -> tasks:string list -> unit

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
