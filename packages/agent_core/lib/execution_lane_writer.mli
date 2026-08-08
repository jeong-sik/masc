(** Lane-local single-writer actor for the recursive execution journal.

    Construction returns before filesystem initialization finishes. Semantic
    mutations are accepted as typed journal transactions, committed by the
    actor, and acknowledged only after the journal authority is durable.

    This module is private to OAS. It owns no product policy and exposes no
    storage primitive or raw-event append path. *)

type t
type 'a ticket

type reconciliation_evidence = private
  { first_outcome_unknown : Execution_journal.error
  ; latest_outcome_unknown : Execution_journal.error
  ; outcome_count : int
  }

type reconciliation_wake_source =
  | Durability_health_changed
  | Operator_requested

type reconciliation_wake_event =
  | External_wake of reconciliation_wake_source
  | Close_requested

type scope_failure =
  | Initialization_failed of Execution_journal.error
  | Initialization_reconciliation_failed of
      { evidence : reconciliation_evidence
      ; reconciliation_error : Execution_journal.error
      }
  | Mutation_writer_failed of Execution_journal.error
  | Reconciliation_failed of
      { evidence : reconciliation_evidence
      ; reconciliation_error : Execution_journal.error
      }
  | Reconciliation_interrupted of
      { evidence : reconciliation_evidence
      ; interruption : exn
      }
  | Reconciliation_unresolved_on_close of { evidence : reconciliation_evidence }
  | Supervisor_cancelled of exn
  | Unexpected_exception of exn

(** Both causes are retained when callback failure coincides with a typed
    durability-scope shutdown failure. *)
exception Callback_failed_after_scope_failure of exn * scope_failure

type submit_error =
  | Admission_closed
  | Admission_failed of scope_failure

type ticket_error =
  | Transaction_rejected of Execution_journal.error
  | Scope_failed of scope_failure

type ticket_phase =
  | Queued
  | Committing
  | Reconciling
  | Settled

type admission =
  | Accepting
  | Draining
  | Failed of scope_failure
  | Closed

type worker_phase =
  | Starting
  | Idle
  | Committing_group
  | Reconciling_group
  | Awaiting_reconciliation_wake

type 'a receipt =
  { value : 'a
  ; through : Execution_journal.cursor
  ; group_event_count : int
  }

type stats =
  { admission : admission
  ; worker_phase : worker_phase
  ; queue_depth : int
  ; in_flight_commands : int
  ; accepted : int
  ; settled : int
  ; committed_groups : int
  ; committed_commands : int
  ; committed_events : int
  ; reconciliation_unknowns : int
  ; reconciliation_wakes : int
  ; current_reconciliation : reconciliation_evidence option
  ; last_reconciliation_wake : reconciliation_wake_event option
  }

type read_error =
  | Journal_not_ready
  | Journal_reconciling
  | Journal_unavailable of scope_failure
  | Journal_read_failed of Execution_journal.error

type page = private
  { events : Execution_event.t list
  ; next_cursor : Execution_journal.cursor
  ; high_watermark : Execution_journal.cursor
  ; has_more : bool
  }

(** Run a fresh durability scope inside an OAS-owned supervisor. The callback
    may fork work on [sw]. When it returns normally, the wrapper stops
    admission, drains every accepted command, joins the actor, and only then
    returns its value. A callback exception also stops admission and lets the
    actor finish or reconcile every actor-owned durability operation before the
    original exception is re-raised; the supervisor fiber never settles an
    in-flight durability group itself. [codec] borrows a shared
    {!Execution_runtime.t} whose owning switch must be outside and outlive this
    complete call; the lane never creates, sizes, or closes that application
    resource. *)
val run
  :  codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> ?correlation_id:Execution_event.Correlation_id.t
  -> (sw:Eio.Switch.t -> t -> 'a)
  -> ('a, scope_failure) result

(** Resume an existing durability scope with the same owned-supervisor
    lifecycle and outer codec-executor lifetime contract as {!run}. *)
val resume
  :  codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> (sw:Eio.Switch.t -> t -> 'a)
  -> ('a, scope_failure) result

(** Linearized admission. No timer, capacity, event count, token, cost, or turn
    budget controls acceptance. *)
val submit : t -> 'a Execution_journal.Transaction.t -> ('a ticket, submit_error) result

(** Await a terminal ticket settlement. Cancelling this waiter never cancels
    the accepted transaction or the actor. *)
val await : 'a ticket -> ('a receipt, ticket_error) result

val ticket_phase : 'a ticket -> ticket_phase

(** Await the first usable journal view or its exact terminal initialization
    failure. This is the deterministic boundary for read-only consumers; it
    performs no polling and does not submit a synthetic mutation. *)
val await_ready : t -> (unit, scope_failure) result

(** Stop admission. Every transaction accepted before this call is drained and
    settled before [await_closed] returns. This operation is idempotent. *)
val close : t -> unit

val await_closed : t -> (unit, scope_failure) result
val close_and_await : t -> (unit, scope_failure) result

(** Signal that external durability health or operator state changed while the
    actor is waiting after a repeated unknown outcome. Returns [true] only when
    this call atomically claims the next reconciliation cycle; concurrent or
    early signals return [false] and are never reported as accepted work. The
    signal carries no retry count or deadline; it is an event, not an execution
    budget. *)
val wake_reconciliation : t -> source:reconciliation_wake_source -> bool

(** Lossless projection reads use the journal cursor as their SSOT. A caller
    may retain its last acknowledged cursor and replay after any wake hint. *)
val current_cursor : t -> (Execution_journal.cursor, read_error) result

val find_node
  :  t
  -> Execution_event.Node_id.t
  -> (Execution_journal.node_view option, read_error) result

val find_run
  :  t
  -> Execution_event.Run_id.t
  -> (Execution_journal.run_view option, read_error) result

val read_page
  :  t
  -> after:Execution_journal.cursor
  -> ?through:Execution_journal.cursor
  -> limit:int
  -> unit
  -> (page, read_error) result

(** Observations only. None of these values participates in admission,
    batching, pausing, cancellation, or termination. *)
val stats : t -> stats

val scope_failure_to_string : scope_failure -> string
val submit_error_to_string : submit_error -> string
val ticket_error_to_string : ticket_error -> string
val read_error_to_string : read_error -> string
