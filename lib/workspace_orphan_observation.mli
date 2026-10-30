(** Observation-only workspace orphan-task metrics. *)

val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  Workspace.config ->
  (unit -> unit)
(** Start the orphan-task gauge Pulse at the existing maintenance interval.
    Every status class is emitted, including zero counts. Observation never
    stops a Keeper, releases a task or changes its membership. The returned
    function requests shutdown of this Pulse; Keeper owner stopping remains
    the server shutdown caller's responsibility. *)
