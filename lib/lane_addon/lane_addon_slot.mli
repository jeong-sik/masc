(** Engine-facing procedures that decide who holds a container, written
    against a [port] so the worker's command runner and an in-memory engine
    run the same code. No procedure here spawns a process. *)

type port = {
  read_engine :
    unit -> (Lane_addon_lifecycle.engine, Lane_addon_lifecycle.engine_fault) result;
      (** The identity of the engine the control command reaches now. *)
}

val proven :
  port -> expected:Lane_addon_lifecycle.engine ->
  lift:(Lane_addon_lifecycle.failure -> 'error) ->
  (unit -> ('value, 'error) result) -> ('value, 'error) result
(** Runs [work] only on the [expected] engine and returns its result only if
    the engine answering afterwards is still that one. The CLI follows an
    ambient context that another process can change between two commands, so
    an answer such as "no such container" counts only when the same engine
    was reached before and after it. A different engine, or an engine that
    cannot name itself, yields [Engine_mismatch]; one that does not answer
    yields [Engine_unreachable]. [work] is not run in either case. *)
