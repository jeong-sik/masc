(* RFC-0088 §4 Option A — typed event for the Coord async-context-free
   telemetry drop counter [Prometheus.metric_coord_telemetry_drop].

   See [.mli] for the public contract. The wire strings are chosen to be
   byte-for-byte compatible with the legacy free-string call sites in
   [lib/coord.ml] (lifecycle: "agent_lifecycle/{join,rejoin,leave}",
   task transition: "task_transition/<task_action>", accountability:
   "accountability/<task_action>") so the Grafana / alerting rules
   filtering on the existing label values keep matching. *)

type lifecycle_kind =
  | Lifecycle_join
  | Lifecycle_rejoin
  | Lifecycle_leave

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
  | Lifecycle_join -> "join"
  | Lifecycle_rejoin -> "rejoin"
  | Lifecycle_leave -> "leave"
;;

let kind_to_wire = function
  | Agent_lifecycle k -> lifecycle_kind_to_wire k
  | Task_transition action | Accountability action ->
    Masc_domain.task_action_to_string action
;;

let to_prometheus_labels t =
  [ "event_family", family_to_wire t; "event_kind", kind_to_wire t ]
;;

let pp fmt t = Format.fprintf fmt "%s/%s" (family_to_wire t) (kind_to_wire t)
