(** Mcp_server_eio_helpers — small utility functions extracted
    from [mcp_server_eio.ml] so [mcp_server_eio.ml] and
    [tool_inline_dispatch.ml] can share them without a circular
    dependency.

    Both helpers re-raise [Eio.Cancel.Cancelled] so an ambient
    cancel is propagated, then catch and log every other
    exception so a single bad message cannot bring the SSE loop
    down. *)

val log_mcp_exn : label:string -> exn -> unit
(** Log an MCP server error via [Log.Mcp.info]. The line is
    prefixed with ["[UNEXPECTED] "] for any exception outside the
    expected set ([Sys_error] / [Failure] / [Not_found] /
    [End_of_file] / [Yojson.Json_error] /
    [Yojson.Safe.Util.Type_error]) — the prefix is what
    operators grep for in production logs to find genuine
    surprises versus routine I/O / parse failures. *)

val wait_for_message_eio :
  clock:_ Eio.Time.clock ->
  Session.registry ->
  agent_name:string ->
  timeout:float ->
  Yojson.Safe.t option
(** Poll the session registry for a queued message for
    [agent_name], sleeping [2.0] s between polls via
    [Eio.Time.sleep], up to [timeout] seconds elapsed.

    Side effects:
    - Registers the agent's session if absent (failures are
      logged via {!log_mcp_exn} and swallowed).
    - Marks the session as listening for the duration of the
      wait and clears the flag on every exit path
      (timeout, message, exception, cancel).

    Returns:
    - [Some msg] when a message arrived before the deadline;
    - [None] on timeout, on [register]-failure mid-wait, or on a
      non-cancel exception during the loop;
    - [Eio.Cancel.Cancelled] is propagated unchanged. *)
