(** Failure semantics for post-provider terminal effects.

    The classification is command policy, not a dashboard interpretation:
    durability-critical failures prevent terminal product success;
    best-effort projection failures are observed but never rewrite a committed
    turn into an execution failure. *)

type criticality =
  | Durability_critical
  | Best_effort

type terminal_effect =
  | Checkpoint_store
  | Execution_receipt
  | Owner_meta
  | Lifecycle_projection
  | Metrics_snapshot
  | Activity_graph
  | Decision_record
  | Usage_metrics
  | Terminal_fsm_projection

val effect_label : terminal_effect -> string
val failure_blocks_product_success : terminal_effect -> bool

val run_best_effort
  :  terminal_effect:terminal_effect
  -> on_error:(exn -> unit)
  -> (unit -> unit)
  -> unit
(** Execute a declared best-effort projection. Passing a critical effect is a
    programmer error. Cooperative cancellation is always re-raised. *)

val matrix_to_yojson : unit -> Yojson.Safe.t
