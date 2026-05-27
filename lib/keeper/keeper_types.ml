(** Keeper_types - public keeper contract facade for profile, meta codec/store,
    and health types. *)

(* Utility functions, canonical helpers, profile defaults, and dir helpers
   extracted to Keeper_types_profile *)
include Keeper_types_profile

(* Policy/runtime/meta contract and pure helpers extracted from the
   store/JSON facade. Keeper_types includes this module for API
   compatibility. *)
include Keeper_meta_contract

(* JSON scrubbing, serialization, and parsing is factored out so this facade
   can focus on keeper meta store I/O and the public contract surface. *)
include Keeper_meta_json

(* Durable meta store I/O and CAS write helpers. *)
include Keeper_meta_store

(** Fiber-level health for keeper supervisor monitoring.
    Defined here (not in Keeper_supervisor) to avoid circular
    dependencies between keeper_status_runtime and the keeper supervisor. *)
type fiber_health =
  | Fiber_alive (** Fiber running, promise unresolved *)
  | Fiber_zombie (** Registry entry exists but fiber terminated *)
  | Fiber_dead (** Restart budget exhausted, manual recovery needed *)
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
  | KH_dead (** Restart budget exhausted *)

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
