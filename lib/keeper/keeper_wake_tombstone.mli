(** RFC-0246 wake-cascade recovery tombstone.

    Turns the no-progress loop detector's latched state into a typed
    [wake_decision] so automatic (board-reactive / heartbeat) wakes of a
    looping keeper are suppressed with a reason, while operator-direct wake
    and explicit @mention bypass. See {!Keeper_wake_tombstone}. *)

type wake_origin =
  | Mention
  | Board_reactive
  | Heartbeat
  | Operator_direct
  | Self_cadence
      (** RFC-0294 R2b: scheduled-autonomous self-cadence wake; an automatic
          origin that does NOT bypass the tombstone. *)
[@@deriving show, eq]

type wake_suppression =
  | Tombstoned_no_progress_loop
[@@deriving show, eq]

type wake_decision =
  | Wake_allowed
  | Suppressed of wake_suppression
[@@deriving show, eq]

val bypasses_tombstone : wake_origin -> bool

(** Gate decision for an automatic wake. [Suppressed Tombstoned_no_progress_loop]
    means the keeper is latched in a no-progress loop and must not be woken by
    board-reactive or heartbeat signals until it records a progress turn (which
    resets the detector) or an operator intervenes. *)
val decide : origin:wake_origin -> keeper_name:string -> wake_decision

val suppression_label : wake_suppression -> string

(** Stable wake-origin label for metrics/logs (RFC-0303 Phase 1). *)
val origin_label : wake_origin -> string
