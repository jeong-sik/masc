type attention_kind =
  | Pending_ask of { ask_id : string; keeper : string }
  | Held_tool_approval of { request_id : string; keeper : string; tool : string }
  | Goal_confirmation of { goal_id : string }
  | Board_quarantine of { keeper : string; count : int }

type live_state =
  | Healthy
  | Working of { detail : Say.t }
  | Needs_attention of attention_kind
  | Degraded of { reason : Say.t }
  | Down of { reason : Say.t }
  | Idle

type incident_source =
  | Source_keeper of string
  | Source_runtime of string
  | Source_sandbox of string
  | Source_client_http
  | Source_stream

type incident_status =
  | Resolved
  | Retried
  | Superseded
  | Dismissed

type incident = {
  id : int;
  occurred_at_unix : float;
  source : incident_source;
  summary : Say.t;
  detail : string;
  status : incident_status;
}

type transport_error =
  | Connect_refused
  | Timeout
  | Http_status of int
  | Stream_eof
  | Protocol_error of string
  | Other_io of string

type source_freshness =
  | Connecting
  | Live of { last_event_ns : Clock.Mono.t; revision : int }
  | Reconnecting of {
      last_live_ns : Clock.Mono.t option;
      attempt : int;
      reason : transport_error;
    }
  | Stale of { last_live_ns : Clock.Mono.t; age_sec : float }
  | Disconnected of { since_ns : Clock.Mono.t; reason : transport_error }
  | Workspace_mismatch of {
      expected_instance : string;
      observed_instance : string;
    }

let requires_human_action = function
  | Needs_attention _ -> true
  | Healthy | Working _ | Degraded _ | Down _ | Idle -> false

let is_live_fault = function
  | Down _ | Degraded _ -> true
  | Healthy | Working _ | Needs_attention _ | Idle -> false

let live_severity_rank = function
  | Down _ -> 5
  | Needs_attention _ -> 4
  | Degraded _ -> 3
  | Working _ -> 2
  | Healthy -> 1
  | Idle -> 0

let is_transport_live = function
  | Live _ -> true
  | Connecting | Reconnecting _ | Stale _ | Disconnected _
  | Workspace_mismatch _ ->
      false

let equal_attention_kind a b =
  match a, b with
  | Pending_ask x, Pending_ask y ->
      String.equal x.ask_id y.ask_id && String.equal x.keeper y.keeper
  | Held_tool_approval x, Held_tool_approval y ->
      String.equal x.request_id y.request_id
      && String.equal x.keeper y.keeper
      && String.equal x.tool y.tool
  | Goal_confirmation x, Goal_confirmation y ->
      String.equal x.goal_id y.goal_id
  | Board_quarantine x, Board_quarantine y ->
      String.equal x.keeper y.keeper && Int.equal x.count y.count
  | Pending_ask _, (Held_tool_approval _ | Goal_confirmation _ | Board_quarantine _)
  | Held_tool_approval _, (Pending_ask _ | Goal_confirmation _ | Board_quarantine _)
  | Goal_confirmation _, (Pending_ask _ | Held_tool_approval _ | Board_quarantine _)
  | Board_quarantine _, (Pending_ask _ | Held_tool_approval _ | Goal_confirmation _) ->
      false

let equal_live_state a b =
  match a, b with
  | Healthy, Healthy | Idle, Idle -> true
  | Working x, Working y -> Say.equal x.detail y.detail
  | Needs_attention x, Needs_attention y -> equal_attention_kind x y
  | Degraded x, Degraded y -> Say.equal x.reason y.reason
  | Down x, Down y -> Say.equal x.reason y.reason
  | Healthy, (Working _ | Needs_attention _ | Degraded _ | Down _ | Idle)
  | Working _, (Healthy | Needs_attention _ | Degraded _ | Down _ | Idle)
  | Needs_attention _, (Healthy | Working _ | Degraded _ | Down _ | Idle)
  | Degraded _, (Healthy | Working _ | Needs_attention _ | Down _ | Idle)
  | Down _, (Healthy | Working _ | Needs_attention _ | Degraded _ | Idle)
  | Idle, (Healthy | Working _ | Needs_attention _ | Degraded _ | Down _) ->
      false

let equal_incident_source a b =
  match a, b with
  | Source_keeper x, Source_keeper y
  | Source_runtime x, Source_runtime y
  | Source_sandbox x, Source_sandbox y ->
      String.equal x y
  | Source_client_http, Source_client_http | Source_stream, Source_stream ->
      true
  | Source_keeper _, (Source_runtime _ | Source_sandbox _ | Source_client_http | Source_stream)
  | Source_runtime _, (Source_keeper _ | Source_sandbox _ | Source_client_http | Source_stream)
  | Source_sandbox _, (Source_keeper _ | Source_runtime _ | Source_client_http | Source_stream)
  | Source_client_http, (Source_keeper _ | Source_runtime _ | Source_sandbox _ | Source_stream)
  | Source_stream, (Source_keeper _ | Source_runtime _ | Source_sandbox _ | Source_client_http) ->
      false

let equal_incident_status a b =
  match a, b with
  | Resolved, Resolved
  | Retried, Retried
  | Superseded, Superseded
  | Dismissed, Dismissed ->
      true
  | Resolved, (Retried | Superseded | Dismissed)
  | Retried, (Resolved | Superseded | Dismissed)
  | Superseded, (Resolved | Retried | Dismissed)
  | Dismissed, (Resolved | Retried | Superseded) ->
      false

let equal_incident a b =
  Int.equal a.id b.id
  && Float.equal a.occurred_at_unix b.occurred_at_unix
  && equal_incident_source a.source b.source
  && Say.equal a.summary b.summary
  && String.equal a.detail b.detail
  && equal_incident_status a.status b.status

let equal_transport_error a b =
  match a, b with
  | Connect_refused, Connect_refused
  | Timeout, Timeout
  | Stream_eof, Stream_eof ->
      true
  | Http_status x, Http_status y -> Int.equal x y
  | Protocol_error x, Protocol_error y | Other_io x, Other_io y ->
      String.equal x y
  | Connect_refused, (Timeout | Http_status _ | Stream_eof | Protocol_error _ | Other_io _)
  | Timeout, (Connect_refused | Http_status _ | Stream_eof | Protocol_error _ | Other_io _)
  | Http_status _, (Connect_refused | Timeout | Stream_eof | Protocol_error _ | Other_io _)
  | Stream_eof, (Connect_refused | Timeout | Http_status _ | Protocol_error _ | Other_io _)
  | Protocol_error _, (Connect_refused | Timeout | Http_status _ | Stream_eof | Other_io _)
  | Other_io _, (Connect_refused | Timeout | Http_status _ | Stream_eof | Protocol_error _) ->
      false

let equal_source_freshness a b =
  match a, b with
  | Connecting, Connecting -> true
  | Live x, Live y ->
      Clock.Mono.equal x.last_event_ns y.last_event_ns
      && Int.equal x.revision y.revision
  | Reconnecting x, Reconnecting y ->
      Option.equal Clock.Mono.equal x.last_live_ns y.last_live_ns
      && Int.equal x.attempt y.attempt
      && equal_transport_error x.reason y.reason
  | Stale x, Stale y ->
      Clock.Mono.equal x.last_live_ns y.last_live_ns
      && Float.equal x.age_sec y.age_sec
  | Disconnected x, Disconnected y ->
      Clock.Mono.equal x.since_ns y.since_ns
      && equal_transport_error x.reason y.reason
  | Workspace_mismatch x, Workspace_mismatch y ->
      String.equal x.expected_instance y.expected_instance
      && String.equal x.observed_instance y.observed_instance
  | Connecting, (Live _ | Reconnecting _ | Stale _ | Disconnected _ | Workspace_mismatch _)
  | Live _, (Connecting | Reconnecting _ | Stale _ | Disconnected _ | Workspace_mismatch _)
  | Reconnecting _, (Connecting | Live _ | Stale _ | Disconnected _ | Workspace_mismatch _)
  | Stale _, (Connecting | Live _ | Reconnecting _ | Disconnected _ | Workspace_mismatch _)
  | Disconnected _, (Connecting | Live _ | Reconnecting _ | Stale _ | Workspace_mismatch _)
  | Workspace_mismatch _, (Connecting | Live _ | Reconnecting _ | Stale _ | Disconnected _) ->
      false
