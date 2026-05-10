(** Keeper_tag_dispatch — Tag-based tool dispatch for keeper context.

    Bridges the gap between keeper's available context (config, agent_name,
    Eio globals) and the module-specific contexts needed by [Tool_*.dispatch].

    Callers must try {!Tool_dispatch.dispatch} (handler registry) first;
    this module is the fallback for tools present only in [tag_registry].
    See [mcp_server_eio_execute.ml] [dispatch_by_tag] for the MCP server
    counterpart.

    Issue: #4579 *)

(** [dispatch ~config ~agent_name ~tag ~name ~args] routes [tag] to the
    corresponding [Tool_*.dispatch] with a minimal keeper-shaped context.

    Returns:
    - [Some (true, msg)] on successful dispatch.
    - [Some (false, msg)] when the tool is blocked in keeper context
      ([Mod_control] mutators, most [Mod_inline] tools, [Mod_compact],
      [Mod_keeper], [Mod_operator]) or when the underlying dispatch reports
      failure. [masc_approval_pending] is the keeper-safe [Mod_inline]
      exception.
    - [None] only if the selected module does not recognise [name] (does
      not happen when [tag] was obtained via [Tool_dispatch.lookup_tag]).

    Exceptions from inner dispatchers are caught and normalised into
    [Some (false, "keeper dispatch error …")] with the exception type
    stripped of internal paths to avoid leaking server internals.
    [Eio.Cancel.Cancelled] is re-raised. *)
val dispatch :
  config:Coord.config ->
  agent_name:string ->
  tag:Tool_dispatch.module_tag ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.t option
