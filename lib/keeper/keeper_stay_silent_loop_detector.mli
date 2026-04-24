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

    Pure in-memory; no file I/O. Single-domain Mutex since the
    keeper lifecycle is serialised through the after-turn hook.

    Threshold source: env [MASC_STAY_SILENT_LOOP_THRESHOLD] with
    default 10 (#9926 proposal 2).

    Observability contract:
    - [masc_keeper_stay_silent_streak{keeper=X}] gauge carries the
      current streak length (0..N).
    - [masc_keeper_stay_silent_loop_detected_total{keeper=X}]
      counter increments each time the streak crosses the
      threshold. Latched: does not increment again until the
      streak resets to 0.
    - A [Log.Keeper.warn] fires on first crossing, tagged [#9926].
      Subsequent crossings only bump the metric. *)

(** Update streak for [keeper_name] based on [speech_act] from the
    latest turn. [speech_act] is the string form already emitted by
    {!Masc_mcp.Keeper_social_model_types.speech_act_to_string} —
    we match on the literal ["stay_silent"] rather than the variant
    so this module does not couple to the social-model type. *)
val record_turn : keeper_name:string -> speech_act:string -> unit

(** Current consecutive stay_silent count for [keeper_name]. *)
val current_streak : keeper_name:string -> int

(** Reset streak for [keeper_name] — used on keeper restart or
    operator-triggered unstick. *)
val reset : keeper_name:string -> unit

(** Reset all per-keeper state. Test-only. *)
val reset_all_for_test : unit -> unit

(** Threshold from env var [MASC_STAY_SILENT_LOOP_THRESHOLD]
    (default 10). Re-read on every call; safe for test-time
    [Unix.putenv]. *)
val threshold : unit -> int
