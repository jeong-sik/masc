(** Run one fusion panelist on an official-client runtime.

    Fusion panels are fanned out through {!Agent_core.Async_agent.all}, which
    can only drive [Runtime_execution.Agent_core] runtimes. A panelist naming a
    Claude Code / Codex / Antigravity / Muse Code runtime therefore never
    produced an answer:
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
  val claude_usage : Runtime_claude_code.turn_usage -> Fusion_types.usage
  val codex_usage : Runtime_codex_app_server.turn_usage -> Fusion_types.usage
  (** Account for vendor cache conventions and refuse replaced thread estimates. *)

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
  -> (string * Fusion_types.usage, Fusion_types.panel_failure) result
(** Execute [prompt] as a single turn on [runtime_id] and return the answer text and reported token usage.

    Typed Claude quota rejections update {!Runtime_quota_window} before error
    rendering. The scope is captured from the resolved runtime before dispatch,
    so catalog reloads cannot reattribute an in-flight result. Every official
    client transport success clears an observed exhaustion before the caller's
    output validation; provider-stated reset windows remain intact.

    [timeout_s] is the preset group's declared deadline. When present it wins
    over the runtime-inferred turn timeout, because it is this request's
    explicit statement while the runtime value is a default shared by every
    consumer of that runtime. When absent the adapter resolves its own turn
    timeout. It does not move [admission_timeout_s], which bounds waiting for
    admission rather than the answer.

    On every client the turn timeout is the longest silence allowed
    between stream messages, not a whole-turn limit: a client that keeps
    streaming can continue until its terminal or owner cancellation.
    On Codex the window is suspended while a tool
    item runs, since the app-server may write nothing until it completes. The
    same preset key on an Agent_core runtime is a whole-call deadline
    ([body_timeout_s]).

    [output_schema] is a JSON Schema the client holds its own answer to. The
    Claude, Antigravity and Codex clients each have a channel for one and no
    two are the same shape: [--json-schema] on the Claude and Antigravity
    CLIs, [outputSchema] on the Codex v2 [turn/start] request. On the two
    CLIs the mechanism is validation with a re-prompt, not constrained
    decoding, and
    the answer returned here is then the validated value rather than the
    narrated text: the Antigravity result event was measured on 2026-08-30
    carrying a fenced draft in [response] while [structured_output] held the
    object that passed.

    Codex carries it too, by a third route: the v2 [turn/start] request takes
    [outputSchema], which its own generated protocol schema describes as
    constraining the final assistant message. That binds the message itself, so
    there is no second field to prefer — the text returned here is already the
    constrained one.

    Muse Code's [muse serve] has no such channel, so a schema asked of a Muse
    Code runtime is a [Setup_failure] and no process starts.

    [base_dir] selects workspace state. Antigravity uses the configured OAuth
    source in a persistent account-specific HOME and spawns in its private
    native read workspace. Muse Code uses a fresh empty directory for the call,
    removed when it ends; creation failure is a [Setup_failure] and cleanup
    failure is logged. These working coordinates are not filesystem confinement
    guarantees; each client's managed read policy remains separate. Claude Code
    and Codex spawn in [base_dir]. Callers thread the base path down from
    {!Fusion_tool.handle}, which already receives it.

    Requires the initialized Eio runtime: the process manager and clock come
    from {!Eio_context}, the same way the official-client login probe obtains
    them, so no fusion signature has to thread them through.

    Timeouts stay owned by each adapter's own configuration; this module adds no
    second turn deadline. Claude's login-only preflight remains bounded even
    when the following model turn explicitly has no deadline. *)


type image_input = { media_type : string; base64_data : string }
type response = { text : string; model : string; usage : Fusion_types.usage }
type failure =
  | Setup_failure of string
      (** A setup cause without runtime attribution. The renderer adds the
          runtime ID supplied by the caller exactly once. *)
  | Codex_failure of Runtime_codex_app_server.error
  | Claude_failure of Runtime_claude_code.error
  | Claude_admission_failure of Runtime_claude_code.error
  | Antigravity_failure of Runtime_antigravity.error
  | Muse_failure of Runtime_muse_serve.error

val failure_detail : runtime_id:string -> failure -> string
(** The adapter's own failure text, naming [runtime_id] once. A
    [Setup_failure] gains the ID here. For log and status lines that should keep what {!panel_failure}
    folds away, such as a timeout's seconds. *)

val panel_failure : runtime_id:string -> failure -> Fusion_types.panel_failure
(** Project a client failure onto the panel vocabulary. A setup cause gains
    [runtime_id] at this boundary. Each
    adapter's own [Timeout] becomes
    {!Fusion_types.Timeout}; every other adapter failure becomes
    [Provider_error] carrying the runtime id. Keep [failure] intact until
    transport-specific failover decisions have consumed its admission/effect
    observations. *)

val run_with_images
  :  images:image_input list
  -> base_dir:string
  -> runtime:Runtime.t
  -> system_prompt:string
  -> ?timeout_s:float
  -> ?output_schema:Yojson.Safe.t
  -> prompt:string
  -> unit
  -> (response, failure) result
(** Stateless official-client turn using the same admission, quota accounting,
    deadlines and output-schema channels as [run_panelist]. Codex and Claude
    execute the admitted runtime snapshot and carry the supplied image bytes
    through their native transports. Antigravity rejects nonempty image input
    and, having no system-prompt channel, gets a nonempty [system_prompt]
    framed into its input ({!Antigravity_input_frame}); a missing frame label
    asset is a [Setup_failure]. Muse Code carries the image bytes over
    [muse serve], gets [system_prompt] framed the same way, and starts a new
    session in a private temporary workspace for each call. [model] is the transport's
    response identity. [usage] carries reported token counts; absent counts are
    not estimated. Claude/Antigravity prompt totals include cache tokens. Codex
    fresh-thread totals are usable only while its counter has not been replaced. *)
