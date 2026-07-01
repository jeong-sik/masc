(** No-progress loop detector for keeper lifecycle (#9926).

    masc-improver evidence from 2026-04-24: a single keeper spent
    13.3 hours of LLM time and burned 4.19M tokens across 40+
    consecutive no-progress turns, because the scheduler kept
    firing ticks on a keeper whose effective tool surface could not satisfy
    any backlog task.

    The scheduler-side fix (O(1) effective-surface gate, quarantine, backlog
    routing) is large and belongs in a follow-up. This module
    closes the **observability** half so runtime can detect the
    loop instead of letting it burn silently in the background.

    Pure in-memory; no file I/O. The caller owns durable recovery wiring
    because it has access to keeper meta, registry, and base path.

    Threshold source: code constant [10]. The retired threshold env knob is
    intentionally ignored so runtime behavior cannot drift per process.

    Observability contract:
    - [masc_keeper_no_progress_streak{keeper=X}] gauge carries the
      current streak length (0..N).
    - [masc_keeper_no_progress_loop_detected_total{keeper=X}]
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

type progress_identity = Keeper_tool_progress_identity.t

type no_progress_reason =
  | Empty
  | Thinking_only
  | Read_only
  | Repeated_identity
  | Surface_mismatch
  | Stale_task
  | Unclassified

val no_progress_reason_to_string : no_progress_reason -> string
val no_progress_reason_of_string : string -> no_progress_reason option

(** [turn_made_progress ~strong_evidence ~surface_requires_evidence] is the
    no-progress predicate (RFC-0239 §3 R3). A turn makes progress when it
    produced durable evidence ([strong_evidence]), or when its delivery surface
    does not require evidence ([surface_requires_evidence = false], e.g. a
    user-facing reply or a task claim). Pure; primitive bools keep this module
    decoupled from the social-model type. *)
val turn_made_progress :
  strong_evidence:bool -> surface_requires_evidence:bool -> bool

(** Update the per-keeper streak from the latest turn. [made_progress] is the
    caller's verdict (see {!turn_made_progress}): the streak increments on a
    no-progress turn and resets when a turn makes progress. Generalises the
    earlier literal silent speech-act match so a keeper that re-posts its
    "nothing to do" conclusion (a no-progress board post) also accrues the
    streak.

    [progress_identity], when present, is the stable fingerprint of the
    strong-evidence tool I/O for this turn. Repeating the same identity does
    not count as progress even when [made_progress] is true, because it is the
    budget-exhausted continuation loop class from #22695. The fingerprint must
    include input/output digests; a weak [(tool_name, outcome)] identity is not
    accepted by the builder.

    [threshold_override] is for high-confidence runtime containment signals
    where waiting for the product default would burn another autonomous budgeted
    turn. Non-positive overrides are ignored. *)
val record_turn :
  ?threshold_override:int ->
  ?progress_identity:progress_identity ->
  ?no_progress_reason:no_progress_reason ->
  keeper_name:string ->
  made_progress:bool ->
  unit ->
  record_outcome

(** Current consecutive no-progress count for [keeper_name]. *)
val current_streak : keeper_name:string -> int

(** Current no-progress reason for [keeper_name], if the current streak was
    classified by the caller. Repeated progress identities are classified in
    this module and override the caller-supplied reason. *)
val current_reason : keeper_name:string -> no_progress_reason option

(** RFC-0246: true iff this keeper is latched in a no-progress loop — the
    streak crossed the threshold and has not been reset by a progress turn.
    The wake-tombstone gate (see [Keeper_wake_tombstone]) reads this to decide
    whether to suppress an automatic (board-reactive/heartbeat) wake. *)
val is_latched : keeper_name:string -> bool

(** Reset streak for [keeper_name] — used on keeper restart or
    operator-triggered unstick. *)
val reset : keeper_name:string -> unit

(** Reset all per-keeper state. Test-only. *)
val reset_all_for_test : unit -> unit

(** Runtime threshold. *)
val threshold : unit -> int
