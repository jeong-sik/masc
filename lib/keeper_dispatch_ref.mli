(** RFC-0182 §3.1 — keeper dispatch dependency inversion ref.

    Same pattern as [Coord_dispatch_ref] and [Persona_dispatch_ref].
    [Tool_keeper] lives in lib/ (late in module order) but is the
    natural home of keeper coordination tools.  Importing it from
    [Agent_tool_in_process_runtime] (early in lib/keeper) would close
    a cycle.

    Resolution: register ctx-free entry points from [Tool_keeper] into
    the ref at module load.  [Agent_tool_in_process_runtime] reads the
    ref at dispatch time.

    The [~agent_name] parameter carries the caller keeper's agent name
    (typically [meta.agent_name]) so tools like [masc_keeper_status]
    that fall back to "self" when the [name] arg is empty can resolve
    the right target. *)

val dispatch
  : (config:Coord.config
     -> agent_name:string
     -> name:string
     -> args:Yojson.Safe.t
     -> (bool * string) option)
      ref
