(** The four spawn tools.

    RFC spawn-a-process-that-outlives-the-call §3.6. [Spawn_registry] holds the
    processes; this is the surface a caller reaches them through.

    Every failure is a value whose message names the next move rather than
    reporting that something went wrong, in the sense [Subset_rewrite] set: a
    handle that names nothing says the process is gone and to spawn again,
    because "it failed" leaves a caller retrying the same call. *)

type context = {
  registry : Spawn_registry.t;
  sw : Eio.Switch.t;
      (** The switch a spawned process belongs to. Taken from the caller
          rather than made here, so whoever owns the turn owns what it
          started. *)
}

val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option
(** [None] for a name this module does not own, which is how a tag dispatch
    asks whether a call is one of these. *)
