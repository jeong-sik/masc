(** The states of a chat task that ends its turn to wait for a background
    receipt, and the transition between them for every event.

    The model is RFC-keeper-turn-ends-while-waiting-for-a-receipt-state-machine
    section 3.2 and the TLA+ model [KeeperReceiptWait]. A task's state is
    derived from its operation row and its owner record, so nothing here is
    stored. [step] is the table written down; the store tests drive each cell
    against the real store and compare. *)

(** What the owner record says about a task's requests. *)
type awaiting =
  | No_receipts  (** The task never waited, or its record holds no entry. *)
  | Receipt_pending  (** An entry whose receipt is not in the outbox yet. *)
  | Receipts_arrived  (** Every entry arrived. *)

val awaiting : Keeper_semantic_execution.receipt_obligation list -> awaiting

type task =
  | Queued  (** Never waited; claimable. *)
  | Waiting  (** Turn ended and a receipt is pending; not claimable. *)
  | Ready  (** Every awaited receipt arrived; claimable. *)
  | Running  (** Holds the slot. *)
  | Succeeded
  | Failed
  | Cancelled

val task : Keeper_chat_operation.state -> awaiting -> task
(** [Waiting] and [Ready] are [Queued] operation rows. Entries on a running or
    ended task do not change its state. *)

type receipt_presence =
  | Receipt_written  (** The request's receipt is already in the outbox. *)
  | Receipt_not_written  (** The worker is still running. *)

type event =
  | Claim
  | Wait of receipt_presence
  | Resolve
  | Complete
  | Fail
  | Cancel
  | Restart

type outcome =
  | Moves_to of task
  | Stays  (** Normal; nothing changes. *)
  | Rejected  (** The caller learns the event did not happen; nothing changes. *)

val step : task -> event -> outcome
(** Total over every task and event. A task that waits again is a [Running]
    task that [Wait]s, so its earlier entries are not removed until it ends. *)

val all_tasks : task list
val all_events : event list
(** Every task and every event, for tests that must reach each pair. *)

val task_to_string : task -> string
val event_to_string : event -> string
