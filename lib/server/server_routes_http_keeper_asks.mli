(** Keeper Ask HTTP routes: the operator answers a Keeper's question and
    lists the questions. {!handle_keeper_ask_answer} serves
    [POST /api/v1/keepers/ask-answer] and {!handle_keeper_asks_list} serves
    [GET /api/v1/keepers/asks]; both are registered by
    [Server_routes_http_routes_dashboard]. The response builders and the
    follow-up frame serializer are exposed so other surfaces and tests build
    the same bodies. *)

(** The route's answer once an answer is recorded: [delivered] false means
    the Keeper could not be told, which is not a success. *)
val ask_answer_response :
  ask_id:string ->
  actor:string ->
  answer_count:int ->
  open_remaining:int ->
  delivered:bool ->
  Http.Status.t * Yojson.Safe.t

val ask_already_answered_response :
  ask_id:string -> answers:Keeper_ask.answer list -> answered_at:float ->
  delivered:bool -> Http.Status.t * Yojson.Safe.t
(** Conflict receipt for the canonical first answer, never the requesting
    surface's losing choices. Delivery can still await automatic recovery. *)

type ask_followup_frame =
  | Followup_started of Keeper_ask_answer_wake.followup_identity
  | Followup_source of Keeper_ask_answer_wake.followup_identity * Keeper_ask_answer_wake.followup_source
  | Followup_completed of Keeper_ask_answer_wake.followup_identity
val ask_followup_frame_json :
  workspace:Yojson.Safe.t -> state_ready:bool -> keeper_name:string -> ask_id:string ->
  ask_followup_frame -> Yojson.Safe.t
(** Canonical source-stream frame. Each phase carries the same workspace,
    Keeper, Ask and committed answer identity. Source frames contain only their
    actual source; serializing a frame does not certify stream completion. *)

val handle_keeper_ask_answer :
  actor:string -> Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [POST /api/v1/keepers/ask-answer].

    Reads [{"name", "ask_id", "answers": [{"question_id", "response"}], ...}]
    where a response is [{"kind": "chose", "choice_ids": [...]}],
    [{"kind": "wrote", "text": ...}], or [{"kind": "skipped"}]. Optional
    ["session_id"] records which dashboard session answered. The body has no
    ["actor_id"] field: who answered is [actor], the authenticated caller
    (task-1662) — a self-reported identity would let the answering client
    write any name into the log. The response echoes [actor] so the caller
    sees what was recorded.

    Two surfaces can submit for one ask at once and nothing locks the log. The
    fold settles on first write, so a submission that lost returns [`Conflict]
    carrying the answer that landed rather than a bare rejection: the surface
    showing it has to be able to say what was chosen instead.

    The original durable ask owns answer admission, including when its Keeper
    is offline or unregistered. Delivery still records its own durable wake
    outcome and does not claim a live Keeper acted on the answer.

    [`Not_found] means the recorded ask is unknown, [`Bad_request] that
    the submissions do not satisfy the recorded question, and [`Conflict] that
    the ask was already answered or withdrawn. *)

val handle_keeper_asks_list :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [GET /api/v1/keepers/asks?name=<keeper>&include_resolved=<bool>].

    Without [name] this covers the whole fleet and every row names the Keeper
    it belongs to; with [name] it narrows to one. Durable question logs remain
    visible when their Keeper is offline or unregistered. A named read returns
    [`Not_found] only when both its log and live registration are absent.
    Read/discovery errors return 503, not a successful empty question list.
    Counts and rows come from the same authoritative fold. Defaults to open
    questions only.

    [expected_base_path] and [expected_masc_root], when provided, must each
    occur once and match the receiving config's canonical roots before any
    questions are read. Invalid pairs return 400; another workspace returns
    409. Every successful named/fleet response carries those actual roots in
    [workspace] and the actual [state_ready] observation, allowing the TUI to
    verify this response without a health read. Booting responses remain unread.

    A surface renders these rows and answers through
    {!handle_keeper_ask_answer}, sending back choice ids taken from the rows it
    was given. No surface matches on label text, so rewording a choice cannot
    orphan an answer already recorded. *)
