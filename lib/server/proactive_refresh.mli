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
      (** Fixed leading-edge window after a wake signal. Sibling signals are
          drained before one compute; the bound avoids debounce starvation. *)
  warm_delay_s : float;    (** Delay before cold-start warm-cache compute (0.0 = immediate). *)
  warn_first_failure : bool;  (** Log a warning on the very first refresh failure. *)
}

val default_config : label:string -> interval_s:float -> config
(** [default_config ~label ~interval_s] returns a config with
    [max_backoff_s = 60.0], [failure_threshold = 3], [timeout_s = 10.0]. *)

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
    fixed leading-edge window; sibling signals are then drained before one
    compute. Signals arriving during compute remain queued for the next
    bounded window. The stream must have enough capacity that mutation-side
    writers cannot block.

    When [config.on_failure] is set, it is called on timeout or exception,
    allowing callers to record the failure (e.g. mark_cached_surface_error). *)
