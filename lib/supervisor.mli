(** Supervisor — One-for-one Eio {b fiber} supervisor.

    {1 Scope of protection}

    Manages a set of named child fibers within a {b single OS process}.
    When a child fiber crashes, the supervisor decides whether to
    restart, back off and retry, or escalate within the same process.

    {b This module does NOT supervise the OS process itself.}  If the
    process exits — uncaught exception in a non-supervised fiber, OOM
    kill, signal, or kernel panic — there is no automatic restart from
    this layer.  Process-level recovery is the responsibility of an
    outer supervisor (launchd / systemd / a respawn-loop wrapper
    script) which is intentionally not bundled here per repo policy.

    Tracking: [#10828] ([no process-level supervisor]) records the
    gap and proposes operator-side runbook options.

    {1 Mechanics}

    Erlang/OTP-inspired but adapted to Eio's cooperative model:
    - Children are [(unit -> unit)] functions, not OS processes
    - Restart uses [Eio.Fiber.fork], not process spawn
    - Backoff uses [Eio.Time.sleep], not Erlang timers

    @since 2.102.0 *)

(** {1 Types} *)

(** Restart policy for a child. *)
type restart_strategy =
  | Permanent  (** Always restart on failure *)
  | Temporary  (** Never restart — failure is expected *)
  | Transient  (** Restart only on abnormal exit (exception) *)

(** Opaque child specification — construct via {!child}. *)
type child_spec

(** Opaque supervisor handle — construct via {!create}. *)
type t

(** Snapshot returned by {!status}. [strategy] is serialised as
    one of ["permanent" | "temporary" | "transient"]. *)
type child_status = {
  name : string;
  running : bool;
  disabled : bool;
  restart_count : int;
  strategy : string;
}

(** {1 Construction} *)

(** [child ~name ~start ?strategy ?max_restarts ?restart_window_s ()].
    Defaults: [strategy = Permanent], [max_restarts = 5],
    [restart_window_s = 60.0]. *)
val child :
  name:string ->
  start:(unit -> unit) ->
  ?strategy:restart_strategy ->
  ?max_restarts:int ->
  ?restart_window_s:float ->
  unit ->
  child_spec

val create : child_spec list -> t

(** {1 Lifecycle} *)

(** Start all children. Must be called within an [Eio.Switch]
    context. Idempotent — logs a warning and does nothing on a second
    call. *)
val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  t ->
  unit

(** Re-enable a child that was auto-disabled after exceeding
    [max_restarts] in [restart_window_s]. Returns [true] when a
    disabled child with [name] was re-enabled, [false] otherwise
    (unknown name or already running). *)
val reenable :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  t ->
  string ->
  bool

(** {1 Observation} *)

val status : t -> child_status list

val status_to_json : child_status -> Yojson.Safe.t
