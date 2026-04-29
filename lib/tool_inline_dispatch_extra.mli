(** Tool_inline_dispatch_extra — fallback inline-tool dispatch
    branch (board / mention handlers extracted from
    {!Tool_inline_dispatch}).

    Two external entries:
    - {!dispatch}: invoked when the main inline dispatch table has
      no match (catch-all branch in {!Tool_inline_dispatch.dispatch}).
    - {!ensure_board_post_author}: caller-identity enforcement on
      [masc_board_post] [author] field, exposed for direct test
      coverage.

    Internal: 11 helpers (activity emission, JSON field upsert,
    Prometheus counter, identity canonicalization, surface-of-
    record helpers, board author canonicalizer) stay private — the
    .mli pins the dispatch contract, not the identity-spoof
    plumbing. *)

(** {1 Caller-identity enforcement (test-visible)} *)

val ensure_board_post_author :
  agent_name:string -> Yojson.Safe.t -> Yojson.Safe.t
(** [ensure_board_post_author ~agent_name args] enforces the
    [masc_board_post] author-identity contract: when [args.author]
    differs from [agent_name] (after canonicalization), records
    the spoof attempt via the Prometheus counter and rewrites the
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

(** {1 Inline dispatch fallback} *)

val dispatch :
  config:Coord.config ->
  agent_name:string ->
  arguments:Yojson.Safe.t ->
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:_ ->
  name:string ->
  (bool * string) option
(** [dispatch ~config ~agent_name ~arguments ~state ~sw ~clock
      ~name] handles inline dispatch for tool [name] when the main
    table has no match.  Currently routes:

    - [masc_board_post] -> identity enforcement +
      {!Board_dispatch.create_post} +
      {!Notify.notify_mention} on [@target] +
      {!Auto_responder.maybe_respond} for auto-reply.
    - everything else -> [None] (caller falls through to remaining
      dispatchers).

    [config] / [state] / [sw] / [clock] are ignored at the entry
    today (board path doesn't need them) but kept in the
    signature for forward compat — adding new tool routes that
    require runtime resources will not break callers. *)
