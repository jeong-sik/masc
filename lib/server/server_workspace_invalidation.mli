module Make (Key : Map.OrderedType) : sig
  val start :
    sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t ->
    publish:(Key.t -> unit) -> (Key.t -> unit)
  (** Coalesce each typed key independently, preserving a change that arrives
      during its publication. Enqueue never waits for fanout. A failed
      publication retains its key and retries; successful idle has no timer. *)
end

val start :
  sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t ->
  publish:(base_path:string -> unit) -> (base_path:string -> unit)
(** Return a short, non-yielding enqueue callback. A switch-owned worker
    coalesces each workspace's pending changes and retries failed publications
    on a monotonic clock. Cooperative waits in one workspace do not hold up
    another; synchronous transport work can still share locks. *)
