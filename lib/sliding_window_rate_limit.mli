(** Sliding Window Rate Limiter for masc

    Provides sliding-window rate limiting per client/agent key.
    Unlike token-bucket (Rate_limit), this bounds requests within
    a strict time window — at most [max_requests] every [window_sec]
    seconds per key.

    @since 0.5.0 *)

(** {1 Types} *)

(** Opaque sliding-window rate limiter instance. *)
type t

(** {1 Creation} *)

val create : window_sec:float -> max_requests:int -> unit -> t
(** [create ~window_sec ~max_requests ()] creates a new limiter allowing
    at most [max_requests] per [window_sec] seconds per key. *)

(** {1 Rate Checking} *)

val check : t -> key:string -> bool
(** [check t ~key] records one request for [key] at the current time.
    Returns [true] if the request is within the window limit,
    [false] if rate-limited. *)

val remaining : t -> key:string -> int
(** [remaining t ~key] returns how many more requests [key] can make
    in the current window without being rate-limited. *)

val window_sec : t -> float
(** The configured window duration. *)

val max_requests : t -> int
(** The configured maximum requests per window. *)

(** {1 Cleanup} *)

val cleanup : t -> older_than_seconds:float -> int
(** [cleanup t ~older_than_seconds] removes entries not accessed in
    [older_than_seconds]. Returns count of keys removed. *)