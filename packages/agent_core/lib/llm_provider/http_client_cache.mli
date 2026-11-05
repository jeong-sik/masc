(** Idle connection cache behind {!Http_client.cache}.

    Parks reusable transport connections per origin, closes the ones idle for
    longer than [idle_ttl_seconds], and closes every parked connection when the
    switch the cache was created with is released. *)

type connection = [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t

(** Host identity for connection reuse. Path, query, and auth are not part of
    it: a connection to the same origin can carry requests with different URLs
    and headers. *)
module Key : sig
  type t =
    { scheme : string
    ; host : string
    ; port : int
    }
end

type t

(** Connections that {!release} closed on a [Close] verdict, by
    {!Reuse_verdict.close_reason}. A [Park] that finds the origin full or the
    cache stopped closes the connection without a reason and is not counted
    here. *)
type close_counts =
  { request_failed : int
  ; not_persistent : int
  ; body_not_drained : int
  ; transport_ended : int
  }

(** Snapshot of the cache for observability. *)
type stats =
  { idle_per_host : (string * int) list
  ; total_idle : int
  ; reuse_count_total : int
  ; create_count_total : int
  ; closed_total : close_counts
  }

(** Create a cache bound to [sw]. [max_idle_per_host] caps the idle
    connections kept per origin and [idle_ttl_seconds] is how long one may sit
    idle. {!checkout} never hands out a connection idle for longer; it closes
    it instead. [clock], if supplied, drives a background fiber that closes
    expired connections every [idle_ttl_seconds /. 2.]; without it they are
    closed at the next {!checkout} for their origin or when [sw] is
    released.

    @raise Invalid_argument if [max_idle_per_host < 1] or
    [idle_ttl_seconds <= 0]. *)
val create
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?max_idle_per_host:int
  -> ?idle_ttl_seconds:float
  -> unit
  -> t

val stats : t -> stats

(** A parked connection for the origin idle for at most the TTL, now owned
    by the caller; otherwise the result of [create], which must open its
    connection on the given switch. Expired connections for the origin are
    closed on the way. Counts a reuse for the first case and a created
    connection for a [create] that returns [Ok]. Always runs [create] once
    the cache is stopped. *)
val checkout
  :  t
  -> Key.t
  -> create:(sw:Eio.Switch.t -> (connection, 'e) result)
  -> (connection, 'e) result

(** Ends a checked-out connection. [Park] parks it for later reuse, or closes
    it when the origin already holds [max_idle_per_host] idle connections or
    the cache is stopped. [Close reason] closes it and counts [reason] in
    {!stats}. Cancellation does not interrupt it. *)
val release : t -> Key.t -> connection -> Reuse_verdict.t -> unit
