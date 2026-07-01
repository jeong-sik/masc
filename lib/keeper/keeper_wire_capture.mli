(** Env-gated capture of the MASC->OAS request boundary (redacted).

    Records the effective request parameters MASC hands to OAS per SDK turn —
    system prompt, extra system context, user message, and the replayed
    conversation history ([initial_messages]) — so degenerate-repetition
    feedback loops can be diagnosed from the actual input rather than from
    digests/sizes (the only signal available today). String content is passed through
    {!Llm_provider.Secret_redactor} before it is written.

    Writes are best-effort and dated under
    [<masc_root>/wire-capture/YYYY-MM/DD.jsonl] (same [Dated_jsonl] per-day
    store the cost ledger uses). Retention is bounded by
    [MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS] and
    [MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES]. A write failure is logged and never
    interrupts the turn.

    Motivation: the request boundary is the primary suspect for
    self-reinforcing repetition — the keeper's own prior visible text is
    replayed into [initial_messages] with no content-level dedup guard. This
    capture makes that input observable. See
    [docs/masc-keeper-repetition-blast-radius-design-2026-07-02.html] (Phase O).

    Disabled unless [MASC_KEEPER_WIRE_CAPTURE] is [1]/[true]/[yes]/[on]. *)

val enabled : unit -> bool
(** [enabled ()] is [true] when [MASC_KEEPER_WIRE_CAPTURE] is set to an
    affirmative value ([1], [true], [yes], [on], case-insensitive). When [false],
    {!capture_request} is a no-op with no filesystem access. *)

val capture_request :
  masc_root:string ->
  keeper_name:string ->
  turn_id:int ->
  sdk_turn:int ->
  system_prompt:string ->
  extra_system_context:string option ->
  user_message:string ->
  history_messages:Agent_sdk.Types.message list ->
  unit
(** [capture_request ~masc_root ~keeper_name ~turn_id ~sdk_turn ~system_prompt
    ~extra_system_context ~user_message ~history_messages] appends one redacted
    request record ([kind:"request"]). No-op unless {!enabled}. [turn_id] is the
    1-based keeper turn index; [sdk_turn] disambiguates multiple OAS/provider
    calls inside that keeper turn. [masc_root] must already be the effective
    cluster-aware MASC root. *)

val capture_response :
  masc_root:string ->
  keeper_name:string ->
  turn_id:int ->
  response_text:string ->
  unit
(** [capture_response ~masc_root ~keeper_name ~turn_id ~response_text] appends
    one redacted response record ([kind:"response"]) paired with the request of
    the same [turn_id]. This closes the loop for analysis: turn N's response is
    turn N+1's replayed history input. No-op unless {!enabled}. *)
