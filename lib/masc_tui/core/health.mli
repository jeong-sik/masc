(** Hard 3-channel state separation plus orthogonal transport freshness.

    - Channel 1 ({!attention_kind}): items awaiting an operator decision NOW.
    - Channel 2 ({!live_state}): authoritative live operational SSOT state.
    - Channel 3 ({!incident}): bounded historical/resolved incident trail that
      never feeds into {!live_state}.
    - Transport ({!source_freshness}): SSE/HTTP stream liveness, orthogonal to
      domain health. *)

type attention_kind =
  | Pending_ask of { ask_id : string; keeper : string }
  | Held_tool_approval of { request_id : string; keeper : string; tool : string }
  | Goal_confirmation of { goal_id : string }

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

type timeout_phase =
  | Timeout_connect
  | Timeout_connect_cooldown
  | Timeout_response
  | Timeout_stream_header
  | Timeout_stream_idle

type transport_error =
  | Connect_refused
  | Timeout
  | Timeout_detail of {
      phase : timeout_phase;
      after_sec : float option;
      path : string option;
    }
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

val requires_human_action : live_state -> bool
val is_live_fault : live_state -> bool
val live_severity_rank : live_state -> int
(** Higher values indicate higher operational urgency for sorting rosters. *)

val is_transport_live : source_freshness -> bool
val is_timeout : transport_error -> bool
(** [true] for both {!Timeout} and {!Timeout_detail}. *)

val timeout_detail_say :
  phase:timeout_phase ->
  after_sec:float option ->
  path:string option ->
  Say.t
(** Format a {!Timeout_detail} phase with optional duration and sanitized path
    in Korean and English. *)

val equal_attention_kind : attention_kind -> attention_kind -> bool
val equal_live_state : live_state -> live_state -> bool
val equal_incident_source : incident_source -> incident_source -> bool
val equal_incident_status : incident_status -> incident_status -> bool
val equal_incident : incident -> incident -> bool
val equal_timeout_phase : timeout_phase -> timeout_phase -> bool
val equal_transport_error : transport_error -> transport_error -> bool
val equal_source_freshness : source_freshness -> source_freshness -> bool
