(** Bounded stale-while-revalidate JSON caches shared by dashboard routes.
    Entry transitions are immutable; this module owns table publication and
    refresh execution. *)

type t

val ttl_s : float
(** Successful payloads remain fresh for this duration in seconds. *)

val max_entries : int
(** Maximum retained keys per cache. Admission evicts the least recently
    successfully refreshed entry, including an in-progress cold entry. *)

val create : unit -> t

val read_result :
  now:(unit -> float) -> sync_first:bool -> sw:Eio.Switch.t ->
  cache:t -> key:string -> placeholder:Yojson.Safe.t ->
  compute:(unit -> (Yojson.Safe.t, string) result) -> Yojson.Safe.t
(** Return fresh data, or stale data/a placeholder while one refresh owns the
    key. A cold [sync_first] fill runs in the caller's pool lane and returns its
    successful result immediately; other refreshes use the background lane.

    Ordinary failure preserves the last payload and measurement time, with subsequent
    reads exposing failure metadata beside stale data. Cancellation propagates and
    releases only that refresh's exact ownership. A cancelled switch cannot
    reserve new work; an evicted refresh cannot restore or overwrite its key.
    [now] supplies boundary time without changing process-wide configuration. *)

val read :
  sync_first:bool -> sw:Eio.Switch.t -> cache:t -> key:string ->
  placeholder:Yojson.Safe.t -> compute:(unit -> Yojson.Safe.t) -> Yojson.Safe.t
(** [read_result] with the system clock and a computation that raises on
    failure. The same cancellation, eviction and publication rules apply. *)
