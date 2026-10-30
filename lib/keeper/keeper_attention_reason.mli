(** Why a Keeper's status asks for an operator, decided by
    {!Keeper_status_bridge.attention_of_surface}. Each reason has one first
    action. *)

type t =
  | Approval_queue_unavailable
      (** The workspace approval queue could not be read. *)
  | Approval_pending  (** An approval for this Keeper is waiting. *)
  | Paused_on_blocker  (** Paused while a runtime blocker is recorded. *)
  | Runtime_attempts_exhausted
  | Provider_runtime_error
  | Fiber_unresolved
  | Runtime_blocked
      (** Any other runtime blocker class. *)
  | Paused  (** Paused with no runtime blocker. *)
  | Keepalive_stopped
      (** Not paused, no blocker, and the keepalive is not running. *)

val all : t list
(** Every reason, in declaration order. *)

val to_wire : t -> string
(** The [attention_reason] field of the status JSON. [Paused_on_blocker] and
    [Paused] both write ["paused"]; {!next_human_action} tells them apart. The
    dashboard labels these strings from its own lists ([ATTENTION_REASONS],
    [NEXT_HUMAN_ACTIONS]), which also hold reasons other surfaces write.
    [dashboard/src/api/fixtures/keeper-attention-reasons.json] holds what this
    module writes; a test here checks it against {!all}, and the dashboard's
    test checks that its lists contain it. *)

val next_human_action : t -> string
(** The [next_human_action] field of the status JSON. *)
