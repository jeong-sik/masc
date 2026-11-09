(** Keeper control HTTP routes: the operator answers a held tool call, reads
    the held calls and the running turns, sets a Keeper's approval stance, and
    moves or stops a running turn. {!handle_keeper_tool_approval} and the
    handlers that follow it are registered by
    [Server_routes_http_routes_dashboard]. *)

val handle_keeper_tool_approval :
  actor:string -> Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Drives [POST /api/v1/keepers/tool-approval].

    [actor] is the authenticated caller (task-1662): the decision outlives
    the HTTP request, so who made it is threaded here, written into the
    late-answer memory and the emitted log line, and echoed back as
    [actor] in the JSON body.

    Reads [{"name", "tool_call_id", "decision"}] where decision is
    ["approve"] or ["deny"], and releases the matching held tool call.

    Returns [{settled: true}] when a wait was actually released, and
    [{settled: false}] when none was: the call had already timed out, was
    answered, or was never held. That is reported rather than treated as
    success, so an operator is not told a call was approved when nothing was
    listening for it. *)

val handle_keeper_turns_list :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Drives [GET /api/v1/keepers/turns].

    One row per registered keeper naming whether a turn is running right now
    ([turn] is [null] or [{lane; started_at_unix; interrupt_token; preview}]).
    Live Owner projection,
    not a store read: the durable keeper meta cannot answer this, which is
    why the TUI keeper list polls this route for its "answering now" badge.
    A failed keeper-name census is a 500, never an empty fleet.
    [preparation_details_for=<name>] includes only that current owner's scope
    history; other previews carry an unrequested [null] timeline. This query
    selects payload volume and never replaces the exact Owner token check. *)

val handle_keeper_tool_approvals_list :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Drives [GET /api/v1/keepers/tool-approvals].

    Projects every held tool call from the shared approval registry:
    [{pending: [{keeper, tool_call_id, tool, args, question, because,
    asked_at, timeout_sec}]}], oldest first. Live registry state only — a wait
    exists exactly while its turn is parked on it. This is what lets an
    operator answer a call whose owning stream watcher is gone; without it
    such a call can only time out (masc#30034). [because] is the policy's
    one-line reason for asking — the listing is the only place an operator
    sees it, so it rides with the question. *)

val handle_keeper_tool_approval_mode_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Drives [GET /api/v1/keepers/tool-approval-mode]: the keepers moved off
    the default stance, as
    [{overrides: [{keeper, mode}], default:"auto", restore_error}]. A keeper
    absent from the list is [auto]. [restore_error] is [null] while the
    persisted store reads cleanly and a string when the last boot replay or
    set could not read it — a corrupt store must not look identical to an
    empty one. *)

val handle_keeper_tool_approval_mode_set :
  actor:string ->
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Drives [POST /api/v1/keepers/tool-approval-mode]. Reads
    [{"name", "mode"}] where mode is ["auto"] or ["yolo"], validates the
    keeper is registered, and persists the stance the approval gate
    consults per call; it survives restarts and is replayed at boot.
    [actor] is the authenticated operator who changed the stance and is
    recorded in the change log and the persisted row. *)

val handle_keeper_run_next :
  Mcp_server.server_state -> actor:string -> Httpun.Request.t -> Http_reqd.t -> unit
(** Prioritize the authenticated caller's exact queued operation, then signal
    only the observed current turn. Existing inputs and other queue order stay intact. *)

val handle_keeper_memory_catch_up :
  actor:string -> Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** [POST /api/v1/keepers/memory-catch-up], admin only. Validates the expected
    workspace and persisted Keeper, then schedules its existing serialized
    Librarian path. The receipt never authorizes replay of an unknown dispatch
    or reports its Memory as caught up. Paused Keepers can use this path. *)

val handle_keeper_turn_interrupt :
  actor:string -> Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Drives [POST /api/v1/keepers/turn/interrupt].
    Accepts an [interrupt_token] from the turns listing to signal only the
    observed switch. A changed or repeated token is declined without touching
    its successor. Tokens and [request_id] are mutually exclusive.
    Reads [{"name": "<keeper>", "request_id": "<operation>"}]. With a
    request id it asks {!Keeper_owner.interrupt_running_operation} for a
    mailbox-linearized compare-and-interrupt and echoes that id; a stale
    request can never cancel its replacement. The name-only form remains for
    operator surfaces that do not own a chat operation and uses
    {!Keeper_registry.interrupt_current_turn}.

    [signalled] is not a completed cancellation: the signal still has to
    reach the running fiber, and a fiber parked in an uncancellable section
    keeps running. The turn state, not this response, says whether the turn
    ended. *)

module For_testing : sig
  val control_public_error :
    Server_keeper_chat_public_error.kind -> string -> Server_keeper_chat_public_error.t
  (** The real control-route failure boundary: retain diagnostic text in its
      operator log and return only fixed public facts with a generated ID. *)
end
