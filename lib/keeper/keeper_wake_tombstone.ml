(** RFC-0246: Wake-cascade recovery tombstone.

    A keeper latched in a no-progress loop (see
    {!Keeper_no_progress_loop_detector}) is suppressed from being woken by
    automatic board-reactive or heartbeat signals, so it cannot be re-woken by
    its own or a peer's no-progress board post and thrash indefinitely.

    Wake origins that represent operator intent ([Operator_direct]) or an
    explicit @mention bypass the tombstone — the operator is overriding.

    The detector owns the single source of truth (streak + latched); this
    module only turns that boolean into a typed [wake_decision] so callers
    cannot silently drop the suppression reason. OpenClaw recovery-tombstone
    pattern (docs.openclaw.ai/automation). *)

type wake_origin =
  | Mention
  | Board_reactive
  | Heartbeat
  | Operator_direct
  | Self_cadence
    (* RFC-0294 R2b: the keeper's own self-cadence (scheduled-autonomous) clock.
       An automatic wake like [Heartbeat]/[Board_reactive], so it must NOT bypass
       the tombstone — a latched keeper kept re-waking on its self-clock was the
       gap RFC-0246 left open. *)
[@@deriving show, eq]

(** Why an automatic wake was suppressed. Only the tombstone class today; the
    per-key dedup window is tracked separately in {!Keeper_registry} and may be
    unified into a richer [wake_suppression] later (P2). *)
type wake_suppression =
  | Tombstoned_no_progress_loop
[@@deriving show, eq]

type wake_decision =
  | Wake_allowed
  | Suppressed of wake_suppression
[@@deriving show, eq]

(** Operator-direct wake and explicit @mention bypass the tombstone. *)
let bypasses_tombstone (origin : wake_origin) =
  match origin with
  | Operator_direct | Mention -> true
  | Board_reactive | Heartbeat | Self_cadence -> false

(** Gate decision for an automatic wake of [keeper_name]. Reads the
    no-progress loop detector's latched state — the single source of truth —
    and returns a typed [wake_decision] so the caller must handle the
    [Suppressed] arm rather than silently dropping a bool. *)
let decide ~(origin : wake_origin) ~keeper_name =
  if bypasses_tombstone origin then Wake_allowed
  else if Keeper_no_progress_loop_detector.is_latched ~keeper_name then
    Suppressed Tombstoned_no_progress_loop
  else Wake_allowed

(** Stable label for metrics/logs. *)
let suppression_label (s : wake_suppression) =
  match s with Tombstoned_no_progress_loop -> "tombstone_no_progress_loop"

(** Stable wake-origin label for metrics/logs (RFC-0303 Phase 1). Lets the turn
    decision surface record WHY a keeper woke, so the share of automatic
    [Self_cadence] wakes (the ones that manufacture passive turns) is
    observable before Phase 2 gates them on a stimulus. *)
let origin_label (o : wake_origin) =
  match o with
  | Mention -> "mention"
  | Board_reactive -> "board_reactive"
  | Heartbeat -> "heartbeat"
  | Operator_direct -> "operator_direct"
  | Self_cadence -> "self_cadence"
