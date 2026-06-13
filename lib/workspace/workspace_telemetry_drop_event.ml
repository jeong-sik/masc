(* RFC-0088 §4 Option A — typed event for the Workspace async-context-free
   telemetry drop counter [Otel_metric_store.metric_workspace_telemetry_drop].

   See [.mli] for the public contract. The wire strings are chosen to be
   explicit names owned by the typed call sites in
   [lib/workspace.ml] (lifecycle: "agent_lifecycle/{session_bound,session_rebound,session_ended}",
   task transition: "task_transition/<task_action>", accountability:
   "accountability/<task_action>") so the Grafana / alerting rules
   filtering on the existing label values keep matching. *)

type lifecycle_kind =
  | Session_bound
  | Session_rebound
  | Session_ended

type t =
  | Agent_lifecycle of lifecycle_kind
  | Task_transition of Masc_domain.task_action
  | Accountability of Masc_domain.task_action

let family_to_wire = function
  | Agent_lifecycle _ -> "agent_lifecycle"
  | Task_transition _ -> "task_transition"
  | Accountability _ -> "accountability"
;;

let lifecycle_kind_to_wire = function
  | Session_bound -> "session_bound"
  | Session_rebound -> "session_rebound"
  | Session_ended -> "session_ended"
;;

let kind_to_wire = function
  | Agent_lifecycle k -> lifecycle_kind_to_wire k
  | Task_transition action | Accountability action ->
    Masc_domain.task_action_to_string action
;;

let to_metric_labels t =
  [ "event_family", family_to_wire t; "event_kind", kind_to_wire t ]
;;

let pp fmt t = Format.fprintf fmt "%s/%s" (family_to_wire t) (kind_to_wire t)
