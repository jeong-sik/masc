(** Original committed inputs shared by server freshness workers and mounted
    Dashboard readers. Snapshot output is never another input. *)

type keeper_change =
  | Phase of { previous : Keeper_state_machine.phase; current : Keeper_state_machine.phase }
  | Composite
  | Row
  | Turn
  | Turn_preview
  | Chat
  | Native_tasks
  | Child_content
  | Memory_journal
  | Async_requests
  | Asks
  | Tool_approval_waits
  | Tool_approval_mode
  | Gate_settings
  | Event_queue
  | Waiting_inventory of Keeper_waiting_inventory_broadcast.source

type store_change =
  | Schedule
  | Pending_confirms
  | Goals
  | Runtime_config
  | Skill_catalog
  | Lane_addon_exports
  | Tools

type gate_change =
  | Approvals
  | Rules
  | Mode
  | External_mode
  | Installation_asks of string

type agent_core_change =
  | Started
  | Completed
  | Failed
  | Yielded
  | Input_required
  | Tool_called
  | Tool_completed
  | Turn_completed

type t =
  | Dataset of Workspace_dataset_event.dataset
  | Keeper of { keeper : string; change : keeper_change }
  | Every_keeper_row
  | Chat_operation of { keeper : string; operation_id : string }
  | Gate of gate_change
  | Connector of string
  | Store of store_change
  | Board
  | Execution_invalidated
  | Agent_core of { keeper : string option; change : agent_core_change }
  | Telemetry_sample
      (** A committed [Dashboard_agent_core_bridge] sample. The published
          entry, shared timestamp and matching provider/model identity are
          checked; metric rows and provider/model labels are not retained. *)
  | Transport_state
      (** Actual listener/session/connection/gRPC/TLS lifecycle metadata.
          Snapshot fanout, downstream delivery and mirrored metrics are not
          source inputs. No listener errors, addresses or payloads retained. *)
  | Telemetry_gap of {
      source : Telemetry_unified_source.source option;
      keeper : string option;
    }
      (** A coverage-gap append in this exact workspace. Unknown legacy source
          names remain [None]; gap rows, traces and error text are not retained. *)
  | Keeper_tool_call of { keeper : string }
      (** An actual canonical tool-call ledger append, including async flush. *)
  | Keeper_approval_audit of { keeper : string; event : Keeper_approval.Audit.event }
      (** An actual approval audit row; no tool arguments or decision text. *)
  | Workspace_agent_signal of { agent : string }
      (** An original source-dated agent record changed; heartbeat-only writes
          affect execution signal policy without changing the Clients roster. *)
  | Workspace_messages of {
      request_id : string;
      mention_delivery : Masc_domain.message_mention_delivery;
    }
      (** The existing committed message/delivery notification, without text. *)

val of_event : Sse.external_event -> t option
(** Validate exact wire names and input identities. Unknown or malformed
    input, whole snapshot output and [Dashboard_observation] are ignored.
    [Execution_invalidated] is the explicit compact invalidation, never an
    [execution_snapshot] containing a computed snapshot. Only exact JSON-RPC
    2.0 [notifications/board] and [notifications/tools/list_changed]
    notification envelopes are unwrapped; protocol replies, requests with an
    id and unrelated notification methods are not observation inputs.
    No rows or tool/chat
    content are retained in [t]. *)

val subscribe :
  sw:Eio.Switch.t -> base_path:string -> ?observer_instance_id:string ->
  (t -> unit) -> unit
(** Subscribe before the initial read using the canonical runtime authority.
    Scope and visibility selection belong to {!Sse.subscribe_publication_inputs}.
    Non-external observer publications (Schedule, Goal, pending confirms and
    exports included) use that same exact publication boundary. Coverage gaps
    additionally use their exact after-append hook, comparing roots resolved
    before the append and before subscription. Callbacks are
    synchronous and must not block or yield. Switch release unsubscribes only
    this listener. *)
