(** Env-gated capture of the MASC->OAS request boundary (redacted).

    Records the exact request MASC assembles and hands to OAS per keeper turn —
    system prompt, user message, and the replayed conversation history
    ([initial_messages]) — so degenerate-repetition feedback loops can be
    diagnosed from the actual input rather than from digests/sizes (the only
    signal available today). String content is passed through
    {!Llm_provider.Secret_redactor} before it is written.

    Writes are best-effort and dated under
    [<masc_root>/wire-capture/YYYY-MM/DD.jsonl] (same [Dated_jsonl] per-day
    store the cost ledger uses). A write failure is logged and never interrupts
    the turn.

    Motivation: the request boundary is the primary suspect for
    self-reinforcing repetition — the keeper's own prior visible text is
    replayed into [initial_messages] with no content-level dedup guard. This
    capture makes that input observable. See
    [docs/masc-keeper-repetition-blast-radius-design-2026-07-02.html] (Phase O).

    Disabled unless [MASC_KEEPER_WIRE_CAPTURE] is [1]/[true]/[yes]. *)

val enabled : unit -> bool
(** [enabled ()] is [true] when [MASC_KEEPER_WIRE_CAPTURE] is set to an
    affirmative value ([1], [true], [yes], case-insensitive). When [false],
    {!capture_request} is a no-op with no filesystem access. *)

val capture_request :
  base_path:string ->
  keeper_name:string ->
  turn_id:int ->
  system_prompt:string ->
  user_message:string ->
  history_messages:Agent_sdk.Types.message list ->
  unit
(** [capture_request ~base_path ~keeper_name ~turn_id ~system_prompt
    ~user_message ~history_messages] appends one redacted request record.
    No-op unless {!enabled}. [turn_id] is the 1-based keeper turn index. *)
