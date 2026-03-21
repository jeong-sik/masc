(** Proactive_refresh -- Reusable refresh loop with circuit breaker.

    Runs a compute function periodically, with exponential backoff on
    consecutive failures. *)

type config = {
  label : string;           (** Log prefix, e.g. "execution" or "mission". *)
  interval_s : float;       (** Base refresh interval in seconds. *)
  max_backoff_s : float;    (** Cap for exponential backoff. *)
  failure_threshold : int;  (** Consecutive failures before backoff kicks in. *)
  timeout_s : float;        (** Warm-cache timeout. *)
}

val default_config : label:string -> interval_s:float -> config
(** [default_config ~label ~interval_s] returns a config with
    [max_backoff_s = 600.0], [failure_threshold = 3], [timeout_s = 10.0]. *)

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:config ->
  compute:(unit -> 'a) ->
  on_result:('a -> unit) ->
  unit
(** Start a refresh loop with warm cache and circuit breaker.

    [compute] produces a value; [on_result] stores it (typically writing
    to a ref).  A warm-cache run executes synchronously before the async
    loop, bounded by [config.timeout_s]. *)
