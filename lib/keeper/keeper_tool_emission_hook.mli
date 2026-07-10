(** Tier K4 — keeper-side capture of tagged tool results into the
    multimodal pipeline (Cycle 27).

    Layer above K3: K3 ([Multimodal.Tool_emission]) provides the
    deterministic detector + emitter that turns a single tagged JSON
    result into the [working_context["multimodal_artifacts"]] bag.
    K4 wires that detector into the live keeper turn so tool authors
    do not need to write any keeper-side glue — they only set the
    two reserved JSON keys (see [Multimodal.Tool_emission]) and the
    rest happens automatically.

    Pipeline:

      keeper agent runs                  ← Agent.run
        │
        │ each PostToolUse event
        ▼
      [accumulator]                      ← K4 (this module)
        │
        │ post_turn_lifecycle
        ▼
      drain_into_working_context         ← K4
        │
        │ Multimodal.Tool_emission.emit_from_tool_results
        ▼
      working_context["multimodal_artifacts"]
        │
        │ apply_multimodal_wirein        ← K1 (already wired)
        ▼
      Multimodal.Workspace_holder

    Feature flag: [MASC_TOOL_EMISSION] (default off). When off,
    [make_post_tool_use_hook] still installs but is a no-op, and
    [drain_into_working_context] returns the working_context
    unchanged. Independent of [MASC_MULTIMODAL] (K1) — both must be
    on for the full chain. *)

(** Per-turn mutable accumulator. Holds parsed
    [Yojson.Safe.t] results captured during Agent.run. Thread-safe
    via [Stdlib.Mutex] (PostToolUse hooks may fire from worker
    fibers). *)
type accumulator

(** Allocate a fresh empty accumulator. *)
val create_accumulator : unit -> accumulator

(** Reads the [MASC_TOOL_EMISSION] env var. Returns [true] for
    [1], [true], [TRUE]; [false] otherwise (including unset). *)
val masc_tool_emission_enabled : unit -> bool

(** Build a [PostToolUse] hook handler that captures tool output
    content as JSON into the accumulator.

    The handler is a no-op when [masc_tool_emission_enabled ()] is
    [false]. Parse failures (non-JSON tool output) are silently
    ignored — only valid JSON enters the accumulator.

    All hook events return [Continue]. The hook is purely
    observational: it never aborts a tool call, never adjusts
    params, never elicits input. *)
val make_post_tool_use_hook : accumulator -> Agent_sdk.Hooks.hook

(** Wrap an existing [Agent_sdk.Hooks.hooks] record so that
    [post_tool_use] also routes through the K4 accumulator hook.

    If the record already has a [post_tool_use] hook, both hooks
    fire in sequence; the original hook's decision is preserved
    (the K4 hook's [Continue] is overridden by the original's
    decision). If the record has no [post_tool_use] hook, only the
    K4 hook is installed. *)
val install_into_hooks :
  accumulator ->
  Agent_sdk.Hooks.hooks ->
  Agent_sdk.Hooks.hooks

(** Drain the accumulator and merge any tagged tool results into
    [working_context["multimodal_artifacts"]] via
    [Multimodal.Tool_emission.emit_from_tool_results].

    After draining, the accumulator is empty (so subsequent turns
    start fresh).

    When [masc_tool_emission_enabled ()] is [false] OR the
    accumulator is empty, returns [working_context] unchanged. *)
val drain_into_working_context :
  accumulator ->
  working_context:Yojson.Safe.t option ->
  Yojson.Safe.t option

(** Snapshot currently captured tool-result JSONs without draining them.
    The returned list preserves capture order. *)
val snapshot : accumulator -> Yojson.Safe.t list

(** Atomically remove and return all captured items in capture order. *)
val take_all : accumulator -> Yojson.Safe.t list

(** Restore a previously taken oldest-first batch behind any items captured
    since the take. Used only when durable admission fails. *)
val restore : accumulator -> Yojson.Safe.t list -> unit

(** Emit an immutable captured batch into a working context without reading or
    mutating an accumulator. *)
val emit_snapshot_into_working_context :
  Yojson.Safe.t list ->
  working_context:Yojson.Safe.t option ->
  Yojson.Safe.t option

(** Number of items currently held in the accumulator. Useful for
    tests and metrics. *)
val accumulator_size : accumulator -> int

(** Process-wide singleton accumulator. Retained for backwards
    compatibility with callers that pre-date Tier K4c per-keeper
    isolation. Production wire-up (K4b) now uses
    [accumulator_for_keeper] instead so concurrent multi-keeper tool
    emissions do not bleed across attribution boundaries.

    Tests and other call sites that need an isolated accumulator
    should use [create_accumulator] instead. *)
val global_accumulator : accumulator

(** Tier K4c — per-keeper accumulator registry.

    Look up (or lazily create) the accumulator owned by [keeper_name].
    Both the producer side ([Keeper_run_tools.install_into_hooks]
    pre-Agent.run) and the consumer side
    ([Keeper_post_turn.apply_tool_emission_wirein] post-Agent.run) MUST
    pass the same [keeper_name] so the in-flight items captured during
    a turn drain back into the same working_context.

    The keeper name is the canonical identifier (
    [Keeper_metadata.t.name] / [lifecycle.updated_meta.name]) — stable
    across turns. Trace ids rotate per turn and are NOT suitable here.

    Thread-safe; safe for concurrent calls from multiple keeper fibers. *)
val accumulator_for_keeper : string -> accumulator

(** Snapshot of keeper names with a registered accumulator, in
    ascending order. Useful for metrics/diagnostics. *)
val registered_keeper_names : unit -> string list

(** Remove a keeper's accumulator entry from the registry. Intended
    for keeper teardown paths (process shutdown, keeper down/repair).
    Safe to call on a name that was never registered (no-op). *)
val drop_keeper_accumulator : string -> unit
