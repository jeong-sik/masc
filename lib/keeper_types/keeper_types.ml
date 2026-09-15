(** Keeper_types — health, continuity, and context types.

    Formerly a facade that re-exported [Keeper_meta_contract],
    [Keeper_types_profile], [Keeper_meta_json], and [Keeper_meta_store]
    via [include]. RFC-0205 removed the facade: consumers now access
    those modules directly via qualified names.

    This module owns only the types that cannot live closer to their
    consumer without creating circular dependencies. *)

(** Fiber-level health for keeper supervisor monitoring.
    Defined here (not in Keeper_supervisor) to avoid circular
    dependencies between keeper_status_runtime and the keeper supervisor. *)
type fiber_health =
  | Fiber_alive (** Fiber running, promise unresolved *)
  | Fiber_zombie (** Registry entry exists but fiber terminated *)
  | Fiber_unknown (** Not in supervised registry *)

(** Keeper-level health, a projection of the registry phase and the turn
    history. Serialized to string at JSON boundaries only. Defined here (not
    in Keeper_status_runtime) so operator_control_snapshot can parse JSON
    into the same type. *)
type keeper_health =
  | KH_healthy (** Keepalive running and at least one turn recorded *)
  | KH_idle (** Keepalive running, no turn recorded yet *)
  | KH_offline (** Keepalive not running: the phase admits no turn *)

(** Keeper continuity state — derived from health + keepalive status. *)
type keeper_continuity =
  | Continuity_healthy (** Runtime aligned with durable state *)
  | Continuity_recovering (** Reconciling back into live presence *)
  | Continuity_not_running (** Keepalive fiber not running *)

(** Per-tool usage entry for keeper tool tracking.
    Defined here so Keeper_registry can embed it without depending
    on Keeper_tools_agent_core (avoids module init order issues). *)
type tool_call_entry =
  { count : int
  ; successes : int
  ; deferred : int
  ; failures : int
  ; last_used_at : float
  }

(* ================================================================ *)
(* Working Context Types (moved from Keeper_working_context)         *)
(* ================================================================ *)

type working_context =
  { checkpoint : Agent_core.Checkpoint.t }

type session_context =
  { session_id : string
  ; session_dir : string
  }
