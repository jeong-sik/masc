open Masc_tui_core

type stream_id =
  | Stream_observer
  | Stream_fleet
  | Stream_model_metrics
  | Stream_tool_metrics_series
  | Stream_logs of { since_seq : int option }

let max_persistent_streams = 2
let max_view_scoped_streams = 1
let max_streams = max_persistent_streams + max_view_scoped_streams

let is_persistent = function
  | Stream_observer | Stream_fleet -> true
  | Stream_model_metrics | Stream_tool_metrics_series | Stream_logs _ -> false

let equal_stream_id a b =
  match a, b with
  | Stream_observer, Stream_observer
  | Stream_fleet, Stream_fleet
  | Stream_model_metrics, Stream_model_metrics
  | Stream_tool_metrics_series, Stream_tool_metrics_series ->
      true
  | Stream_logs x, Stream_logs y ->
      Option.equal Int.equal x.since_seq y.since_seq
  | ( Stream_observer
    , ( Stream_fleet
      | Stream_model_metrics
      | Stream_tool_metrics_series
      | Stream_logs _ ) )
  | ( Stream_fleet
    , ( Stream_observer
      | Stream_model_metrics
      | Stream_tool_metrics_series
      | Stream_logs _ ) )
  | ( Stream_model_metrics
    , (Stream_observer | Stream_fleet | Stream_tool_metrics_series | Stream_logs _) )
  | ( Stream_tool_metrics_series
    , (Stream_observer | Stream_fleet | Stream_model_metrics | Stream_logs _) )
  | ( Stream_logs _
    , ( Stream_observer
      | Stream_fleet
      | Stream_model_metrics
      | Stream_tool_metrics_series ) ) ->
      false

let equal_stream_kind a b =
  match a, b with
  | Stream_observer, Stream_observer
  | Stream_fleet, Stream_fleet
  | Stream_model_metrics, Stream_model_metrics
  | Stream_tool_metrics_series, Stream_tool_metrics_series
  | Stream_logs _, Stream_logs _ ->
      true
  | ( Stream_observer
    , ( Stream_fleet
      | Stream_model_metrics
      | Stream_tool_metrics_series
      | Stream_logs _ ) )
  | ( Stream_fleet
    , ( Stream_observer
      | Stream_model_metrics
      | Stream_tool_metrics_series
      | Stream_logs _ ) )
  | ( Stream_model_metrics
    , (Stream_observer | Stream_fleet | Stream_tool_metrics_series | Stream_logs _) )
  | ( Stream_tool_metrics_series
    , (Stream_observer | Stream_fleet | Stream_model_metrics | Stream_logs _) )
  | ( Stream_logs _
    , ( Stream_observer
      | Stream_fleet
      | Stream_model_metrics
      | Stream_tool_metrics_series ) ) ->
      false

let equal_plan a b = List.equal equal_stream_kind a b

let is_blocked_by_gate (m : Model.t) =
  let mismatch_blocked =
    match m.server_identity.mismatch_state with
    | Model.Mismatch_none -> false
    | Model.Mismatch_recovering | Model.Mismatch_halted -> true
  in
  m.freshness.server_offline
  || mismatch_blocked
  ||
  match m.nav.overlay with
  | Some (Nav.System_gate (Nav.Auth_gate | Nav.Server_offline)) -> true
  | Some
      ( Nav.System_gate (Nav.Micro_viewport | Nav.Media_viewer)
      | Nav.Palette
      | Nav.Settings _
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Help )
  | None ->
      false

let view_scoped_stream (m : Model.t) : stream_id option =
  match Model.active_dive m with
  | Some _ -> None
  | None -> (
      match m.nav.workspace with
      | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers -> None
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_quotas_credits
          | Nav.Runtime_failover_lanes
          | Nav.Runtime_fusion
          | Nav.Runtime_connectors
          | Nav.Runtime_addons_browser ->
              None
          | Nav.Runtime_efficiency_spend -> Some Stream_model_metrics
          | Nav.Runtime_tools_usage -> Some Stream_tool_metrics_series)
      | Nav.Infra -> (
          match m.infra.active_tab with
          | Nav.Infra_sandboxes | Nav.Infra_repos_changes | Nav.Infra_code ->
              None
          | Nav.Infra_activity_logs ->
              Some (Stream_logs { since_seq = m.infra.last_log_seq })))

let plan (m : Model.t) =
  if is_blocked_by_gate m then []
  else
    let persistent = [ Stream_observer; Stream_fleet ] in
    match view_scoped_stream m with
    | None -> persistent
    | Some s -> persistent @ [ s ]
