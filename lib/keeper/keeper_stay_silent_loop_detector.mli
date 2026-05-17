(** Stay-silent loop detector for keeper lifecycle (#9926).

    masc-improver evidence from 2026-04-24: a single keeper spent
    13.3 hours of LLM time and burned 4.19M tokens across 40+
    consecutive [stay_silent] turns, because the scheduler kept
    firing ticks on a keeper whose preset could not satisfy any
    backlog task.

    The scheduler-side fix (O(1) preset gate, quarantine, backlog
    routing) is large and belongs in a follow-up. This module
    closes the **observability** half so runtime can detect the
    loop instead of letting it burn silently in the background.

    Pure in-memory; no file I/O. The caller owns durable recovery wiring
    because it has access to keeper meta, registry, and base path.

    Threshold source: code constant [10]. The retired
    [MASC_STAY_SILENT_LOOP_THRESHOLD] env knob is intentionally ignored so
    runtime behavior cannot drift per process.

    Observability contract:
    - [masc_keeper_stay_silent_streak{keeper=X}] gauge carries the
      current streak length (0..N).
    - [masc_keeper_stay_silent_loop_detected_total{keeper=X}]
      counter increments each time the streak crosses the
      threshold. Latched: does not increment again until the
      streak resets to 0.
    - A [Log.Keeper.warn] fires on first crossing, tagged [#9926].
      The return value is [Loop_detected] only for that first crossing so
      callers can stamp a blocker and enqueue recovery once per episode. *)

type record_outcome =
  | Normal
  | Loop_detected of { streak : int; threshold : int }
  | Loop_reset of { previous_streak : int; was_latched : bool }

(** Update streak for [keeper_name] based on [speech_act] from the
    latest turn. [speech_act] is the string form already emitted by
    {!Masc_mcp.Keeper_social_model_types.speech_act_to_string} —
    we match on the literal ["stay_silent"] rather than the variant
    so this module does not couple to the social-model type. *)
val record_turn : keeper_name:string -> speech_act:string -> record_outcome

(** Current consecutive stay_silent count for [keeper_name]. *)
val current_streak : keeper_name:string -> int

(** Reset streak for [keeper_name] — used on keeper restart or
    operator-triggered unstick. *)
val reset : keeper_name:string -> unit

(** Reset all per-keeper state. Test-only. *)
val reset_all_for_test : unit -> unit

(** Runtime threshold. *)
val threshold : unit -> int
