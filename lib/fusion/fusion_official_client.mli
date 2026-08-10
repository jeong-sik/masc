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

val run_panelist
  :  base_dir:string
  -> runtime_id:string
  -> system_prompt:string
  -> prompt:string
  -> (string, Fusion_types.panel_failure) result
(** Execute [prompt] as a single turn on [runtime_id] and return the answer text.

    [base_dir] is the directory the official client is spawned in. There is no
    global accessor for the MASC base path, so callers thread it down from
    {!Fusion_tool.handle}, which already receives it.

    Requires the initialized Eio runtime: the process manager and clock come
    from {!Eio_context}, the same way the official-client login probe obtains
    them, so no fusion signature has to thread them through.

    Timeouts stay owned by each adapter's own configuration; this module adds no
    second deadline, so a panel-level timeout still bounds the whole fan-out. *)
