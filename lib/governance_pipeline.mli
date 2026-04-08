(** Governance_pipeline — Unified risk-based approval gate for tool dispatch.

    Classifies tool calls by risk level and enforces governance policy
    (development/production/enterprise/paranoid) as a Tool_dispatch pre_hook.
    Denied or confirm-required calls are short-circuited before the handler runs.

    Integration: call {!install} once at server startup.

    @since 2.128.0 *)

(** Risk classification for a tool invocation. *)
type risk_level =
  | Low       (** Pure reads: status, list, query *)
  | Medium    (** State-changing reads: claim, join, leave *)
  | High      (** Write ops: create, update, deploy *)
  | Critical  (** Destructive ops: delete, force-push, drop *)

(** Result of governance evaluation for a single tool call. *)
type governance_decision = {
  tool_name : string;
  risk : risk_level;
  action : [ `Allow | `Require_confirm of string | `Deny of string ];
  trace_id : string;
}

val risk_level_to_string : risk_level -> string

val assess_risk : tool_name:string -> input:Yojson.Safe.t -> risk_level
(** Classify tool risk using, in order:
    - tool metadata overrides (readonly/destructive)
    - payload-sensitive destructive semantics for selected mutation fields
    - name/action heuristics as a deterministic fallback

    Result classes:
    - Critical: destructive ops or destructive payload semantics
    - High: write ops
    - Medium: state-changing reads
    - Low: readonly/status/query surfaces *)

val decide :
  governance_level:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  governance_decision
(** Evaluate a tool call against governance policy and return a decision.
    - development: allow all, audit High+Critical
    - production: confirm Critical, audit Medium+
    - enterprise: confirm High+Critical, audit all
    - paranoid: confirm Medium+High+Critical, audit all *)

val make_pre_hook :
  config:Room.config ->
  governance_level:string ->
  Tool_dispatch.pre_hook
(** Create a Tool_dispatch pre_hook closure for the given governance level.
    Returns [Pass] (proceed) for allowed calls,
    [Reject result] (short-circuit) for confirm-required or denied calls. *)

val install : config:Room.config -> governance_level:string -> unit
(** Register the governance pipeline as a Tool_dispatch pre_hook.
    Reads governance level from the [governance_level] argument.
    Called once at server startup. *)

val to_oas_approval_callback :
  governance_level:string -> Oas.Hooks.approval_callback
(** Build an OAS-compatible approval callback using governance risk
    assessment. Wire into Agent Builder via [with_approval] so that
    autonomous agents are suspended at execution level when invoking
    tools above the governance threshold.

    Pipeline stages:
    1. risk_classifier — uses {!assess_risk} to set risk_level
    2. governance_threshold — rejects tools above the confirm threshold

    @since 2.262.0 (#5902) *)
