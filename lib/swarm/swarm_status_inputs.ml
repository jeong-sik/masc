
open Swarm_status_types
open Swarm_status_json
open Swarm_status_parse

let read_operation_infos _config = []
let read_detachment_infos _config = []
let read_alert_infos _config = []
let read_decision_infos _config = []
let read_trace_infos ?limit:_ _config = []

let read_session_infos _config =
  (* Team_session_store removed — return empty *)
  []

let operation_infos_of_snapshot snapshot =
  snapshot
  |> U.member "operations"
  |> fun json -> list_member json "operations"
  |> List.map operation_of_json
  |> List.filter (fun (operation : operation_info) -> operation.operation_id <> "")

let detachment_infos_of_snapshot snapshot =
  snapshot
  |> U.member "detachments"
  |> fun json -> list_member json "detachments"
  |> List.map detachment_of_json
  |> List.filter (fun (detachment : detachment_info) ->
         detachment.detachment_id <> "")

let alert_infos_of_snapshot snapshot =
  snapshot
  |> U.member "alerts"
  |> fun json -> list_member json "alerts"
  |> List.map alert_of_json
  |> List.filter (fun (alert : alert_info) -> alert.alert_id <> "")

let decision_infos_of_snapshot snapshot =
  snapshot
  |> U.member "decisions"
  |> fun json -> list_member json "decisions"
  |> List.map decision_of_json
  |> List.filter (fun (decision : decision_info) -> decision.decision_id <> "")

let trace_infos_of_snapshot snapshot =
  snapshot
  |> U.member "traces"
  |> fun json -> list_member json "events"
  |> List.map trace_of_json
  |> List.filter (fun (trace : trace_info) -> trace.event_id <> "")
