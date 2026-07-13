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
  | Fiber_dead (** Fiber resolved; lane restart is required *)
  | Fiber_unknown (** Not in supervised registry *)

(** Keeper-level health state — derived from agent status, keepalive
    fiber, and supervisor monitoring. Serialized to string at JSON
    boundaries only. Defined here (not in Keeper_status_runtime) so
    operator_control_snapshot can parse JSON into the same type. *)
type keeper_health =
  | KH_healthy (** Keepalive alive, recent turns, no quiet_reason *)
  | KH_idle (** Keepalive alive but no recent activity *)
  | KH_offline (** Agent not present or status=offline/inactive *)
  | KH_stale (** Last seen too long ago or zombie flag from agent *)
  | KH_degraded (** graphql_error or model_error quiet_reason *)
  | KH_zombie (** Fiber terminated but registry entry exists *)
  | KH_dead (** Explicit durable Dead tombstone *)

(** Keeper continuity state — derived from health + keepalive status. *)
type keeper_continuity =
  | Continuity_healthy (** Runtime aligned with durable state *)
  | Continuity_recovering (** Reconciling back into live presence *)
  | Continuity_not_running (** Keepalive fiber not running *)

(** Per-tool usage entry for keeper tool tracking.
    Defined here so Keeper_registry can embed it without depending
    on Keeper_tools_oas (avoids module init order issues). *)
type tool_call_entry =
  { count : int
  ; successes : int
  ; failures : int
  ; last_used_at : float
  }

(* ================================================================ *)
(* Working Context Types (moved from Keeper_working_context)         *)
(* ================================================================ *)

type working_context =
  { checkpoint : Agent_sdk.Checkpoint.t
  ; max_tokens : int
  }

type session_context =
  { session_id : string
  ; session_dir : string
  }
