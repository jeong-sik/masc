(** Tier K4 — keeper-side capture of tagged tool results into the
    multimodal pipeline (Cycle 27).

    Layer above K3: K3 ([Multimodal.Tool_emission]) provides the
    deterministic detector + emitter that turns a single producer-owned typed
    JSON result into the [working_context["multimodal_artifacts"]] bag. K4
    captures that typed value at the Keeper execution boundary; model-facing
    text is never parsed or promoted into structured data.

    Pipeline:

      keeper tool executes               ← Keeper_tool_execution.data
        │
        │ successful typed result
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

    The typed capture and wire-in are part of the normal Keeper runtime. They
    are not rollout-gated: providers and models remain configurable, while an
    external effect still crosses Gate at the tool execution boundary. *)

(** Per-turn mutable accumulator. Holds producer-owned typed
    [Yojson.Safe.t] results captured during Keeper tool execution. Thread-safe
    via [Stdlib.Mutex] because Keeper tool handlers may run on worker fibers. *)
type accumulator

(** Allocate a fresh empty accumulator. *)
val create_accumulator : unit -> accumulator

(** Capture one producer-owned typed result. Only a JSON object can carry the
    reserved multimodal fields; every other JSON variant, including a
    JSON-looking [`String], is ignored without reparsing. *)
val capture_typed_result : accumulator -> Yojson.Safe.t -> unit

(** Drain the accumulator and merge any tagged tool results into
    [working_context["multimodal_artifacts"]] via
    [Multimodal.Tool_emission.emit_from_tool_results].

    After draining, the accumulator is empty (so subsequent turns
    start fresh).

    When the accumulator is empty, returns [working_context] unchanged. *)
val drain_into_working_context :
  accumulator ->
  working_context:Yojson.Safe.t option ->
  Yojson.Safe.t option

(** Snapshot currently captured tool-result JSONs without draining them.
    The returned list preserves capture order. *)
val snapshot : accumulator -> Yojson.Safe.t list

val snapshot_artifact_refs : accumulator -> (Shared_types.Artifact_id.t list, string) result

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
    The producer execution boundary and
    [Keeper_post_turn.apply_tool_emission_wirein] MUST pass the same
    [keeper_name] so in-flight items captured during a turn drain back into the
    same working_context.

    The keeper name is the canonical identifier (
    [Keeper_metadata.t.name] / [lifecycle.updated_meta.name]) — stable
    across turns. Trace ids rotate per turn and are NOT suitable here.

    Thread-safe; safe for concurrent calls from multiple keeper fibers. *)
val accumulator_for_keeper : string -> accumulator

(** Keeper-keyed form of {!capture_typed_result}. *)
val capture_typed_result_for_keeper :
  keeper_name:string -> Yojson.Safe.t -> unit

(** Snapshot of keeper names with a registered accumulator, in
    ascending order. Useful for metrics/diagnostics. *)
val registered_keeper_names : unit -> string list

(** Remove a keeper's accumulator entry from the registry. Intended
    for keeper teardown paths (process shutdown, keeper down/repair).
    Safe to call on a name that was never registered (no-op). *)
val drop_keeper_accumulator : string -> unit
