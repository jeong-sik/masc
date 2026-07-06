(** Mcp_tool_runtime_board — MCP server-local board tool runtime.

    Two external entries:
    - {!dispatch}: invoked when the main MCP runtime router has
      no match (catch-all branch in {!Mcp_tool_runtime.dispatch}).
    - {!ensure_board_post_author}: caller-identity enforcement on
      [masc_board_post] [author] field, exposed for direct test
      coverage.

    RFC-0062 Phase 4c-2: {!dispatch} now returns [Tool_result.result option]
    instead of [(bool * string) option].

    Internal: 11 helpers (activity emission, JSON field upsert,
    Otel_metric_store counter, identity canonicalization, surface-of-
    record helpers, board author canonicalizer) stay private — the
    .mli pins the dispatch contract, not the identity-spoof
    plumbing. *)

(** {1 Caller-identity enforcement (test-visible)} *)

type board_post_id_extract_error =
  | Board_post_id_payload_not_object of { received_kind : string }
  | Board_post_id_missing_id
  | Board_post_id_id_not_string of { received_kind : string }
  | Board_post_id_blank_id

val board_post_id_extract_error_to_string :
  board_post_id_extract_error -> string

val extract_board_post_id_from_data_result :
  Yojson.Safe.t -> (string, board_post_id_extract_error) result
(** [extract_board_post_id_from_data_result data] extracts the created
    post id from structured [Tool_result.data].  It does not parse the
    human-facing [Tool_result.message] string; malformed or drifted
    payloads are returned as typed errors so runtime dispatch can log and
    count the failure explicitly. *)

val extract_board_post_id_from_data : Yojson.Safe.t -> string option
(** Compatibility projection over
    {!extract_board_post_id_from_data_result}.  New code that must
    distinguish parse/schema failures should use the Result-returning
    function. *)

val ensure_board_post_author :
  agent_name:string -> Yojson.Safe.t -> Yojson.Safe.t
(** [ensure_board_post_author ~agent_name args] enforces the
    [masc_board_post] author-identity contract: when [args.author]
    differs from [agent_name] (after canonicalization), records
    the spoof attempt via the Otel_metric_store counter and rewrites the
    author field to the canonical keeper name.

    Returns the (possibly mutated) [args] JSON object.  Specialised
    delegate of the internal [enforce_caller_identity] helper —
    same contract, [tool = "masc_board_post"] and
    [field = "author"] pinned. *)

val enforce_caller_identity :
  tool:string ->
  field:string ->
  agent_name:string ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** [enforce_caller_identity ~tool ~field ~agent_name args]
    enforces caller-identity contract for arbitrary
    [(tool, field)] pairs.  When [args.<field>] (after
    canonicalization) differs from [agent_name]'s canonical form,
    records the spoof attempt and rewrites the field.  Pinned for
    behaviour-tests under
    {!test/test_board_author_identity_10297} which cover all four
    board entries ([keeper_board_post] / [_comment] / [_vote] /
    [_comment_vote]).  Prefer {!ensure_board_post_author} for the
    [masc_board_post]/[author] specialisation. *)

(** {1 MCP runtime fallback} *)

val dispatch :
  config:Workspace.config ->
  agent_name:string ->
  arguments:Yojson.Safe.t ->
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:_ ->
  name:string ->
  start_time:float ->
  Tool_result.result option
(** [dispatch ~config ~agent_name ~arguments ~state ~sw ~clock
      ~name ~start_time] handles MCP server-local routing for tool [name]
    when the main runtime router has no match.  Currently routes:

    - [masc_board_post] -> identity enforcement +
      {!Board_dispatch.create_post} +
      {!Notify.notify_mention} on [@target].
    - everything else -> [None] (caller falls through to remaining
      dispatchers).

    [config] / [state] / [sw] / [clock] are ignored at the entry
    today (board path doesn't need them) but kept in the
    signature for forward compat — adding new tool routes that
    require runtime resources will not break callers. *)
