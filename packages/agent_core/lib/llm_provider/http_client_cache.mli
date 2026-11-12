(** Idle connection cache behind {!Http_client.cache}.

    Parks reusable transport connections per origin, closes the ones idle for
    longer than [idle_ttl_seconds] on its monotonic clock, and closes every
    parked connection when the switch the cache was created with is
    released. *)

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
    {!Reuse_verdict.close_reason}. A [Park] that finds the origin full, the
    cache stopped, or the connection's owner switch off (see {!checkout})
    closes the connection without a reason and is not counted here. *)
type close_counts =
  { request_failed : int
  ; request_not_delivered : int
  ; not_persistent : int
  ; body_not_drained : int
  ; transport_ended : int
  }

(** Snapshot of the cache for observability. [closed_after_reuse] counts the
    part of [closed_total] whose connection had been parked before, so a
    reused connection's failures can be told from a new one's (RFC-0492 §6). *)
type stats =
  { idle_per_host : (string * int) list
  ; total_idle : int
  ; reuse_count_total : int
  ; create_count_total : int
  ; closed_total : close_counts
  ; closed_after_reuse : close_counts
  }

(** Create a cache bound to [sw]. [max_idle_per_host] caps the idle
    connections kept per origin and [idle_ttl_seconds] is how long one may sit
    idle, measured on [mono_clock] from when it was parked. {!checkout} never
    hands out a connection idle for longer; it closes it instead. A daemon on
    [sw] also closes expired connections every [idle_ttl_seconds /. 2.] on
    [mono_clock].

    @raise Invalid_argument if [max_idle_per_host < 1], or if
    [idle_ttl_seconds] is under 1 ns, not finite, or 2{^53} ns (about 104
    days) or longer. *)
val create
  :  sw:Eio.Switch.t
  -> mono_clock:_ Eio.Time.Mono.t
  -> ?max_idle_per_host:int
  -> ?idle_ttl_seconds:float
  -> unit
  -> t

val stats : t -> stats

(** A checked-out connection with its cache, its origin, and whether it was
    parked before or opened by [create] for this checkout. {!release} ends it
    once; closing its connection directly would skip the cache's counts. *)
type lease

val lease_connection : lease -> connection

(** A lease on a parked connection for the origin idle for at most the TTL;
    otherwise on the connection [create] opens. The caller holds the lease
    until {!release}. Expired connections for the origin are closed on the
    way. Counts a reuse for the first case and a created connection for a
    [create] that returns [Ok], whose [Error] is returned as it is.

    [create] runs in the calling fiber with an owner switch of the new
    connection's own. A daemon on the cache's switch runs that switch until
    the connection is closed. A fiber [create] forks there outlives the
    request. If such a fiber raises, it fails the owner switch only: the
    failure is logged, the cache's switch keeps running, and the connection
    is closed instead of being handed out or parked again. Cancelling the
    cache's switch cancels every owner switch.

    Once the cache is stopped no parked connection is handed out. When the
    cache's switch is cancelled or finished, a checkout that would open a
    connection raises as [Eio.Switch.check] does. *)
val checkout
  :  t
  -> Key.t
  -> create:(sw:Eio.Switch.t -> (connection, 'e) result)
  -> (lease, 'e) result

(** Ends a lease. [Park] parks its connection for later reuse, or closes it
    when the origin already holds [max_idle_per_host] idle connections, the
    cache is stopped, or its owner switch is off. [Close reason] closes it and counts [reason] in
    [closed_total], and also in [closed_after_reuse] when the connection was
    parked before. Cancellation does not interrupt it.

    @raise Invalid_argument if the lease was already released. *)
val release : lease -> Reuse_verdict.t -> unit
