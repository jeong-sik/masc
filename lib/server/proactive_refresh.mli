(** Proactive_refresh -- Reusable refresh loop with circuit breaker.

    Runs a compute function periodically, with exponential backoff on
    consecutive failures. *)

type phase =
  | Warm_cache
  | Refresh

type timeout =
  { label : string
  ; phase : phase
  ; timeout_s : float
  ; elapsed_s : float
  }

type failure =
  | Timed_out of timeout
  | Raised of exn

val failure_message : failure -> string
(** Render a failure only at an operator/cache/wire boundary. Timeout rendering
    preserves the existing [Failure("refresh_timeout ...")] text contract. *)

type config = {
  label : string;           (** Log prefix, e.g. "execution" or "mission". *)
  interval_s : float;       (** Base refresh interval in seconds. *)
  max_backoff_s : float;    (** Cap for exponential backoff. *)
  failure_threshold : int;  (** Consecutive failures before backoff kicks in. *)
  timeout_s : float;        (** Per-attempt timeout. *)
  on_failure : (failure -> unit) option;  (** Called on timeout or exception. *)
  wakeup : unit Eio.Stream.t option;  (** Optional event-driven refresh signal. *)
  wakeup_coalesce_s : float;
      (** Fixed leading-edge window after a wake signal. Signals observed at
          its end are coalesced before one compute; any signal left queued can
          trigger the next pass. *)
  change_read_spacing_s : float;
      (** Change-driven workers only. A read caused by an input change starts
          no sooner than this long after the previous read caused by an input
          change started; [0.0] applies no spacing. A change that arrives
          after the spacing has passed starts its read at once, so a quiet
          source is still read on its first change. The initial read, a
          semantic deadline and a failure retry keep their own times and open
          no spacing. *)
  warm_delay_s : float;    (** Delay before cold-start warm-cache compute (0.0 = immediate). *)
  warn_first_failure : bool;  (** Log a warning on the very first refresh failure. *)
}

val default_config : label:string -> interval_s:float -> config
(** [default_config ~label ~interval_s] returns a config with
    [max_backoff_s = 60.0], [failure_threshold = 3], [timeout_s = 10.0] and
    no change-read spacing. *)

module For_testing : sig
  val should_warn_refresh_failure :
    ?warn_first_failure:bool -> failure_threshold:int -> int -> bool
end

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:config ->
  compute:(unit -> 'a) ->
  on_result:('a -> unit) ->
  unit
(** Start a refresh loop with warm cache and circuit breaker.

    [compute] produces a value; [on_result] stores it (typically writing
    to a ref).  Warm-cache and recurring runs live in child fibers owned by
    [sw], with every attempt bounded by [config.timeout_s].

    When [config.wakeup] is provided, queued signals interrupt the recurring
    sleep. If [wakeup_coalesce_s] is positive, the first signal opens that
    fixed leading-edge window; signals observed at its end are then drained
    before one compute. A signal left queued can trigger the next bounded
    window. The stream must have enough capacity that mutation-side
    writers cannot block.

    When [config.on_failure] is set, it is called on timeout or exception,
    allowing callers to record the failure (e.g. mark_cached_surface_error). *)

val start_on_change :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  changes:unit Eio.Stream.t ->
  config:config ->
  compute:(unit -> 'a) ->
  on_result:('a -> unit) ->
  unit
(** Serialize the initial read and change-driven reads in one worker. A
    successful read waits indefinitely for [changes]; it has no periodic
    refresh. A signal during a read remains owed after that read finishes.

    [warm_delay_s] delays only the initial read; an input change can bring it
    forward. A subsequent change first waits out [change_read_spacing_s]
    measured from the start of the previous change-driven read, then uses
    [wakeup_coalesce_s]'s bounded leading window; every change observed by
    then is answered by the one read that follows. Failure retains a retry, using [interval_s] and the existing
    exponential backoff; a new input can bring that retry forward. Every
    attempt keeps [timeout_s], and switch cancellation ends both reads and
    waits. The worker is a daemon, so a normal [Switch.run] return also retires
    its idle wait before release callbacks unsubscribe the inputs.
    [config.wakeup] is unused: [changes] is the sole input mailbox.

    Install the input subscription before starting this worker. Its publisher
    must retain a signal without blocking the authoritative writer. *)

val start_on_change_or_deadline :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  changes:unit Eio.Stream.t ->
  config:config ->
  next_deadline:('a -> float option) ->
  compute:(unit -> 'a) ->
  on_result:('a -> unit) ->
  unit
(** As {!start_on_change}, with the next semantic deadline returned by the
    successful observation. The deadline uses [clock]'s Unix-time domain.
    [None] waits only for a change. An elapsed deadline is consumed once,
    including when the read crossed it; a successful subsequent observation
    must return its next deadline or [None]. This is not a refresh cadence.
    Retry deadlines remain owned by the existing typed failure policy. If an
    observation is retained but [on_result] reports a partial read failure,
    its already observed semantic deadline can bring that retry forward;
    it does not postpone that deadline until the retry interval. *)
