(** MASC Workspace - Core workspace hub.

    This module ties together all Workspace sub-modules (utils, state, lifecycle,
    init, status, task, query, agent, gc). *)

(** {1 Included sub-modules} *)

include module type of Workspace_utils
include module type of Workspace_backlog
include module type of Workspace_bootstrap
include module type of Workspace_identity
include module type of Workspace_task_id
include module type of Workspace_state
include module type of Workspace_bootstrap
include module type of Workspace_identity
include module type of Workspace_task_id
include module type of Workspace_backlog
include module type of Workspace_broadcast
include module type of Workspace_lifecycle
include module type of Workspace_init
include module type of Workspace_status
include module type of Workspace_task
include module type of Workspace_task_schedule
include module type of Workspace_query
include module type of Workspace_gc
include module type of Workspace_agent
(** {1 Workspace lifecycle (overrides)} *)

(** Initialize MASC workspace with optional session binding.
    Wraps [Workspace_init.init] and calls [bind_session] when [agent_name] is provided. *)
val init : config -> agent_name:string option -> string

(** {1 Test hooks} *)

module For_testing : sig
  val warn_telemetry_drop :
    event:Workspace_telemetry_drop_event.t -> exn -> unit
  (** Emit the same observable drop marker used when audit/telemetry hooks
      cannot run. Exposed so tests do not depend on backend-specific
      [Effect.Unhandled] behavior.

      RFC-0088 §4 Option A (2026-05-15): the previous
      [~event_family:string -> ~event_kind:string] surface was replaced
      by the typed {!Workspace_telemetry_drop_event.t} sum. The Otel_metric_store
      label wire format is unchanged ([family_to_wire] / [kind_to_wire]
      are byte-for-byte compatible with the prior free-string values). *)
end


