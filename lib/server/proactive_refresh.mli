(** Proactive_refresh -- Reusable refresh loop with circuit breaker.

    Runs a compute function periodically, with exponential backoff on
    consecutive failures. *)

type config =
  { label : string (** Log prefix, e.g. "execution" or "mission". *)
  ; interval_s : float (** Base refresh interval in seconds. *)
  ; max_backoff_s : float (** Cap for exponential backoff. *)
  ; failure_threshold : int (** Consecutive failures before backoff kicks in. *)
  ; timeout_s : float (** Warm-cache timeout. *)
  ; on_error : (exn -> unit) option (** Called on timeout or exception. *)
  ; health_check : (unit -> bool) option
    (** Pre-compute gate. If [Some f] and [f ()] returns [false], the cycle is skipped and backoff applied. *)
  ; warm_delay_s : float
    (** Delay before cold-start warm-cache compute (0.0 = immediate). *)
  }

(** [default_config ~label ~interval_s] returns a config with
    [max_backoff_s = 120.0], [failure_threshold = 5], [timeout_s = 10.0]. *)
val default_config : label:string -> interval_s:float -> config

(** Start a refresh loop with warm cache and circuit breaker.

    [compute] produces a value; [on_result] stores it (typically writing
    to a ref).  A warm-cache run executes synchronously before the async
    loop, bounded by [config.timeout_s].

    When [config.on_error] is set, it is called on timeout or exception,
    allowing callers to record the failure (e.g. mark_cached_surface_error). *)
val start
  :  sw:Eio.Switch.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:config
  -> compute:(unit -> 'a)
  -> on_result:('a -> unit)
  -> unit
