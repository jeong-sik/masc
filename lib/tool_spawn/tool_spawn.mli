(** The four spawn tools.

    RFC spawn-a-process-that-outlives-the-call §3.6. [Spawn_registry] holds the
    processes; this is the surface a caller reaches them through.

    Every failure here is a value, not an exception, and every message says what
    to do next in the sense [Subset_rewrite] established: a handle that names
    nothing says the process is gone, not that something went wrong.

    The per-tool handlers and the argument readers stay inside. {!dispatch} is
    how a tool call arrives and the only thing that decides which handler
    answers it; a caller reaching past it for [handle_read] would be choosing
    the handler by hand and skipping the name check that pairs the two. *)

type context =
  { registry : Spawn_registry.t
  ; sw : Eio.Switch.t
        (** The switch the spawned processes are attached to. They outlive the
            call that started them, so the caller's switch decides how long. *)
  }

val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option
(** [dispatch ctx ~name ~args] answers a tool call, or [None] when [name] is not
    one of the spawn tools. [Eio.Cancel.Cancelled] passes through: a cancelled
    fiber is not a tool failure to report. *)

val schemas : Masc_domain.tool_schema list
(** Every spawn tool schema, for a surface publishing the set. *)
