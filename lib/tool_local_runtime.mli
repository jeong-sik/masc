
(** Tool_local_runtime — local model runtime management and
    benchmarking tools.

    Facade module that provides MCP dispatch / schemas plus the
    deliberate status / verify / probe / bench adapter exports below.
    Implementation split across:

    - {!Tool_local_runtime_core}: types, helpers, process discovery,
      model fetching.
    - {!Tool_local_runtime_http}: HTTP helpers (curl wrappers, JSON
      member access).
    - {!Tool_local_runtime_verify}: runtime contract verification.
    - {!Tool_local_runtime_probe}: native Ollama timing / KV
      inference probe.

    Core types and cmdline/model-discovery helpers are intentionally
    kept on {!Tool_local_runtime_core}; this top-level module no
    longer re-exports that surface.

    The two [handle_*] functions [dispatch] routes to
    ([handle_runtime_verify], [handle_runtime_ollama_probe]) plus the
    [Tool_spec.register] side-effect block stay private.  The .mli pins
    the dispatch / schemas contract. Probe and verification helpers remain on
    their owning modules instead of being re-exported here. *)

(** {1 MCP dispatch contract} *)

val dispatch :
  Tool_local_runtime_core.context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_local_runtime_core.tool_result option
(** [dispatch ctx ~name ~args] dispatches the named MCP tool call.

    Recognised names:
    - [masc_runtime_verify] -> {!runtime_verify_json}
    - [masc_runtime_ollama_probe] -> {!runtime_ollama_probe_json}

    Returns [None] for unrecognised names so the caller can fall
    through to other dispatchers. *)

val schemas : Masc_domain.tool_schema list
(** Two schemas pinned at the contract seam:
    [masc_runtime_verify] (4 optional properties: [runtime_pool],
    [expected_model], [expected_slots], [expected_ctx]) and
    [masc_runtime_ollama_probe] (9 optional properties).  Adding a
    new tool requires extending both this list and {!dispatch}. *)
