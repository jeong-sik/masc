(** Env-gated capture of the MASC->AGENT_CORE request boundary (redacted).

    Records the effective request parameters MASC hands to AGENT_CORE per agent-core turn —
    system prompt, extra system context, tool schemas, and user message — so
    degenerate-repetition feedback loops can be diagnosed from the actual
    input rather than from digests/sizes. These are the parameters no other
    durable store holds: the AGENT_CORE checkpoint keeps [system_prompt] and the
    replayed messages, but nothing else keeps the per-turn injected context.
    Tool schemas use the same {!Agent_core.Tool.schema_to_json} projection AGENT_CORE
    prepares for the provider; the redacted schema array is stored once in the
    shared {!Tool_blob_store} under its content address and each request row
    carries a [tools_ref] normalized artifact reference instead of the inline
    array (measured 2026-08-18 on a live root: 2,702 rows held 2 unique
    ~80KB arrays — 99.3% of all capture bytes were copies). Blob maintenance
    already lists wire-capture as a durable consumer, so the blob expires with
    the last retained row that references it. String content is passed through
    {!Llm_provider.Secret_redactor} and the exact {!Keeper_secret_redaction}
    projection snapshot before it is written.

    The replayed conversation itself is recorded as [history_message_count]
    and [history_messages_digest] rather than as text. The text is already
    durable in the checkpoint and its [agent-core-snapshot-*] history, and this
    function runs once per agent-core turn: embedding it made one record as large as
    the checkpoint (measured 2026-08-05 on a live keeper: 14,465 messages =
    9.8MB per record, exhausting the 64MiB day-file budget after 7 records and
    skipping every request after that). The digest is the same MD5 the
    [context_injected] runtime manifest records, so a capture row joins to
    the manifest row and to the checkpoint that holds the text.

    Writes are best-effort and dated under
    [<masc_root>/wire-capture/YYYY-MM/DD.jsonl] (same [Dated_jsonl] per-day
    store the cost ledger uses). [MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES] is
    the store byte budget: the current day file rotates to a completed
    [DD.NNN.jsonl] segment at an eighth of the budget and capture
    continues in a fresh file, while the budget prunes the oldest
    completed files — so a busy day keeps a ring of its newest segments
    and sheds its oldest instead of going dark after the cap
    ([Dated_jsonl.append_rotating]). Retention is bounded by
    [MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS]. A write failure is
    logged and never interrupts the turn.

    Motivation: the request boundary is the primary suspect for
    self-reinforcing repetition — the keeper's own prior visible text is
    replayed into [initial_messages] with no content-level dedup guard. The
    replayed text is readable from the checkpoint; what was unreadable is the
    context this module injects on top of it, and what {!capture_response}
    pairs with it is the output that becomes the next turn's replayed input.
    Provider-independent structural redaction is composed with the exact
    Keeper secret projection snapshot; token formats are never inferred from
    product prefixes or lengths. See
    [docs/masc-keeper-repetition-blast-radius-design-2026-07-02.html] (Phase O).

    Disabled unless [MASC_KEEPER_WIRE_CAPTURE] is enabled through the feature
    flag registry / runtime config. *)

val enabled : unit -> bool
(** [enabled ()] is [true] when [MASC_KEEPER_WIRE_CAPTURE] is enabled through
    {!Env_config_keeper.KeeperWireCapture}. When [false], {!capture_request} is
    a no-op with no filesystem access. *)

type prune_error =
  | Retention_prune_failed of
      { path : string
      ; detail : string
      }

val prune_error_to_string : prune_error -> string

val prune_expired : masc_root:string -> (int, prune_error) result
(** Prune expired capture day-files using this module's configured retention
    SSOT. This is intentionally ungated: captures written while the feature
    was enabled must still expire after it is disabled. Startup blob maintenance
    calls this before scanning references, so expired diagnostic rows cannot
    retain a blob indefinitely. *)

val capture_request :
  base_path:string ->
  masc_root:string ->
  keeper_name:string ->
  turn_id:int ->
  agent_core_turn:int ->
  system_prompt:string ->
  extra_system_context:string option ->
  user_message:string ->
  history_messages:Agent_core.Types.message list ->
  tools:Agent_core.Tool.t list ->
  ?trace_id:Keeper_id.Trace_id.t ->
  unit ->
  unit
(** [capture_request ~base_path ~masc_root ~keeper_name ~turn_id ~agent_core_turn ~system_prompt
    ~extra_system_context ~user_message ~history_messages ~tools ~trace_id ()]
    appends one redacted request record ([kind:"request"]). No-op unless
    {!enabled}.
    [turn_id] is the 1-based keeper turn index; [agent_core_turn] disambiguates
    multiple AGENT_CORE/provider calls inside that keeper turn. [trace_id] is the
    keeper runtime trace id passed to AGENT_CORE as [session_id] for raw-trace
    correlation. [base_path] selects the exact Keeper secret projection
    snapshot; [masc_root] must already be the effective cluster-aware MASC
    root. [tool_schema_bytes] records the byte length of the exact unredacted
    compact JSON schema array while [tools_ref] points at its recursively
    redacted content in the shared blob store (see the module header).
    [history_messages] is consumed for [history_message_count] and
    [history_messages_digest] only; the messages themselves are not written
    (see the module header). *)

val capture_response :
  base_path:string ->
  masc_root:string ->
  keeper_name:string ->
  turn_id:int ->
  agent_core_turn:int ->
  response_text:string ->
  ?trace_id:Keeper_id.Trace_id.t ->
  unit ->
  unit
(** [capture_response ~base_path ~masc_root ~keeper_name ~turn_id ~agent_core_turn ~response_text
    ~trace_id ()] appends one redacted response record ([kind:"response"])
    paired with the request of the same [turn_id]. [agent_core_turn] is the 1-based
    AGENT_CORE/provider turn index inside the keeper turn, matching the request record.
    [trace_id] is the keeper runtime trace id passed to AGENT_CORE as [session_id] for
    raw-trace correlation. [base_path] selects the exact Keeper secret
    projection snapshot. This closes the loop for analysis: turn N's response
    is turn N+1's replayed history input. No-op unless {!enabled}. *)

val capture_request_projection_change :
  masc_root:string ->
  keeper_name:string ->
  turn_id:int ->
  agent_core_turn:int ->
  trace_id:Keeper_id.Trace_id.t ->
  runtime_profile:string ->
  memo:Keeper_projection_change.digest_memo ->
  previous:Keeper_projection_change.previous_request ->
  tools:Agent_core.Tool.t list ->
  messages:Agent_core.Types.message list ->
  Keeper_projection_change.previous_request
(** Called once per provider request with the values that request carries:
    its tool schemas, and its messages after projection without the
    extra-system-context carrier AGENT_CORE appends last, so [message_count]
    is one less than the provider received when a carrier was sent.
    Digests [tools] and [messages] on the CPU domain pool, compares them with
    [previous] through {!Keeper_projection_change.compare_requests}, and
    appends one [kind:"request_projection_change"] row. Returns the state the
    next request of the same keeper turn compares against: [Request_digested]
    when hashing succeeded, whether or not the row was written, and
    [Request_not_digested] after a hashing failure, which is logged as a
    warning. Cancellation propagates. Unless {!enabled} it digests and writes
    nothing and returns [Request_not_digested], so a request sent while
    capture is off is not compared across once capture is on again.

    The caller waits for it before the request is dispatched. While capture is
    on, every request therefore pays one serialization and SHA-256 of its tool
    schemas and of the messages [memo] has not seen in this keeper turn, plus
    one [memo] lookup per message.

    [trace_id], [turn_id] and [agent_core_turn] are the values the cost
    ledger records as [trace_id], [keeper_turn_id] and
    [agent_core_turn_ordinal] for the response to this request. *)

val capture_rejected_reasoning :
  base_path:string ->
  masc_root:string ->
  keeper_name:string ->
  ?turn_id:int ->
  ?trace_id:string ->
  runtime_id:string ->
  Agent_core.Types.api_response ->
  unit
(** Appends one redacted [kind:"rejected_reasoning"] record when the accept
    gate rejected a response whose only content is reasoning: the response's
    newest 64 KiB of reasoning (the window the stream repeat guard reads),
    its total length, the provider stop reason, and the longest periodic
    suffix {!Agent_core.Llm_provider.Periodic_suffix.find} sees in that
    window, so a block the guard did not end can be re-run against the rule
    offline. Any other response shape writes nothing. [turn_id] is the keeper
    turn when the caller has one. No-op unless {!enabled}. *)
