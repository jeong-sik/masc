(** Mcp_tool_runtime_board — MCP server-local board tool runtime.

    Two external entries:
    - {!dispatch}: invoked when the main MCP runtime router has
      no match (catch-all branch in {!Mcp_tool_runtime.dispatch}).
    - {!bind_caller_identity}: the identity binding {!dispatch} applies
      first, driven by the generated board registry, exposed so a test
      can pin that every declared field is bound.

    RFC-0062 Phase 4c-2: {!dispatch} now returns [Tool_result.result option]
    instead of [(bool * string) option].

    Internal: helpers (activity emission, JSON field upsert,
    Otel_metric_store counter) stay private — the
    .mli pins the dispatch contract, not the identity-spoof
    plumbing. *)

(** {1 Caller-identity enforcement (test-visible)} *)

val bind_caller_identity :
  name:string -> agent_name:string -> Yojson.Safe.t -> Yojson.Safe.t
(** [bind_caller_identity ~name ~agent_name args] applies
    {!enforce_caller_identity} for every field
    [Board_tool_registry.identity_fields_for_board_name] declares for
    the board tool [name] resolves to, in declaration order. A [name]
    that is not a board tool returns [args] unchanged. The registry is
    generated from [config/tools/masc_board_*.toml], the same source the
    Keeper runtime's [bind_board_identity] reads. *)

val enforce_caller_identity :
  tool:string ->
  field:string ->
  agent_name:string ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** [enforce_caller_identity ~tool ~field ~agent_name args]
    enforces caller-identity contract for arbitrary
    [(tool, field)] pairs.  When [args.<field>] (trimmed) differs from
    the trimmed [agent_name], records the spoof attempt and rewrites
    the field.  Pinned for
    behaviour-tests under
    {!test/test_board_author_identity_10297} which cover all four
    board entries ([masc_board_post] / [_comment] / [_vote] /
    [_comment_vote]). *)

module For_testing : sig
  val result_after_activity_projection :
    primary_result:Tool_result.result ->
    operation:Event_kind.Board.t ->
    (unit -> (unit, string) result) ->
    Tool_result.result
  (** A committed Board operation stays [Completed] if its activity projection
      fails. Its data, artifacts and media are retained, and metadata carries
      the failed projection separately. Failed/deferred primary operations do
      not attempt projection. *)
end

(** {1 MCP runtime fallback} *)

val dispatch :
  reader:Masc_board_handlers.Board_access.reader ->
  config:Workspace.config ->
  agent_name:string ->
  arguments:Yojson.Safe.t ->
  state:Mcp_server.server_state ->
  name:string ->
  Tool_result.result option
(** [dispatch ~config ~agent_name ~arguments ~state ~name] handles
    MCP server-local routing for tool [name] when the main runtime router has no
    match. Declared Board tools pass through identity binding and
    {!Board_tool.handle_tool}; other names return [None]. Successful post,
    comment, post/comment vote and delete operations also project Board
    activity. Projection failure is reported as observation metadata alongside
    the completed Board result. Post and comment notify mentions. The SSE
    notification, the activity record and the mention of a post or comment
    carry the text of the stored row, whichever of [body] and [content] the
    request sent it in. Board activity does not create Task performance
    records. *)
