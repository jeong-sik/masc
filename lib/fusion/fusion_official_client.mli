(** Run one fusion panelist on an official-client runtime.

    Fusion panels are fanned out through {!Agent_core.Async_agent.all}, which
    can only drive [Runtime_execution.Agent_core] runtimes. A panelist naming a
    Claude Code / Codex / Antigravity runtime therefore never produced an answer:
    a panel made only of them ended in [Panels_unavailable], and a mixed panel
    completed on quorum while those panelists silently contributed nothing.

    This module is the missing execution path. It runs a panelist as a
    stateless one-shot turn — no session resume, no dynamic tools — because a
    panelist answers a question and does not act. *)

val is_official_client : runtime_id:string -> bool
(** Whether [runtime_id] resolves to an official-client runtime, i.e. one that
    {!Fusion_agent_core.build_agent} cannot build an agent for. [false] for an
    unknown id: an id that resolves to nothing is not this module's failure to
    report, and the Agent_core path already names it precisely. *)

module For_testing : sig
  val missing_handle_detail : env_present:bool -> clock_present:bool -> string option
  (** The failure detail for an unresolvable Eio context, or [None] when both
      handles are present. Exposed because {!Eio_context} has no reset, so a
      test driving the real globals could reach these arms in only one order. *)

  val resolved_timeout_s
    :  runtime_id:string
    -> override_s:float option
    -> default_timeout_s:float
    -> float option
  (** Resolve the same declared turn timeout used by each official-client
      panel adapter. [override_s] (the preset group's declared deadline) wins
      when present; otherwise the runtime's inferred turn timeout applies and
      [turn-timeout-s = 0] produces [None]. *)

  val bounded_claude_probe_config
    :  fallback_timeout_s:float
    -> Runtime_claude_code.config
    -> Runtime_claude_code.config
  (** Keep Claude's login-only process bounded when its following model turn
      explicitly declares no deadline. *)
end

val run_panelist
  :  base_dir:string
  -> runtime_id:string
  -> system_prompt:string
  -> ?timeout_s:float
  -> ?output_schema:Yojson.Safe.t
  -> prompt:string
  -> unit
  -> (string, Fusion_types.panel_failure) result
(** Execute [prompt] as a single turn on [runtime_id] and return the answer text.

    [timeout_s] is the preset group's declared deadline. When present it wins
    over the runtime-inferred turn timeout, because it is this request's
    explicit statement while the runtime value is a default shared by every
    consumer of that runtime. When absent the adapter resolves its own deadline
    exactly as before. It does not move [admission_timeout_s], which bounds
    waiting for admission rather than the answer.

    [output_schema] is a JSON Schema the client holds its own answer to. Every
    official client has a channel for one and no two are the same shape:
    [--json-schema] on the Claude and Antigravity CLIs, [outputSchema] on the
    Codex v2 [turn/start] request. On the two CLIs the mechanism is validation
    with a re-prompt, not constrained decoding, and
    the answer returned here is then the validated value rather than the
    narrated text: the Antigravity result event was measured on 2026-08-30
    carrying a fenced draft in [response] while [structured_output] held the
    object that passed.

    Codex carries it too, by a third route: the v2 [turn/start] request takes
    [outputSchema], which its own generated protocol schema describes as
    constraining the final assistant message. That binds the message itself, so
    there is no second field to prefer — the text returned here is already the
    constrained one.

    [base_dir] is the directory the official client is spawned in. There is no
    global accessor for the MASC base path, so callers thread it down from
    {!Fusion_tool.handle}, which already receives it.

    Requires the initialized Eio runtime: the process manager and clock come
    from {!Eio_context}, the same way the official-client login probe obtains
    them, so no fusion signature has to thread them through.

    Timeouts stay owned by each adapter's own configuration; this module adds no
    second turn deadline. Claude's login-only preflight remains bounded even
    when the following model turn explicitly has no deadline. *)
