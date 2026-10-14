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

val to_wire : t -> string
(** The [attention_reason] field of the status JSON. [Paused_on_blocker] and
    [Paused] both write ["paused"]; {!next_human_action} tells them apart. *)

val next_human_action : t -> string
(** The [next_human_action] field of the status JSON. *)
