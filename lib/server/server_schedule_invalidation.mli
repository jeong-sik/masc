val start : sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t -> unit
(** Wake full health on store attempts and asynchronously publish coalesced,
    workspace-scoped invalidations to SSE observers. *)

module For_testing : sig
  val start :
    sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t -> publish:(base_path:string -> unit) ->
    invalidate:(base_path:string -> unit) -> unit
end
