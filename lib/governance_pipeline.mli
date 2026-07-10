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
val risk_level_to_int : risk_level -> int

val confirm_threshold : string -> risk_level option
(** Minimum risk level that requires confirmation for the given governance level.
    Returns [None] for "development" (no threshold-triggered confirmation
    needed) or when HITL thresholds are disabled. This threshold does not
    include the hard-forbidden auto-approval override applied by {!decide}. *)

val keeper_confirm_threshold : string -> risk_level option
(** Keeper-specific confirmation threshold.
    Keepers are more autonomous than front-door tool dispatch, so production
    keepers confirm from High upward while the generic production surface
    confirms only Critical. *)

val assess_risk : tool_name:string -> input:Yojson.Safe.t -> risk_level
(** Classify tool risk using, in order:
    - tool metadata overrides (readonly/destructive)
    - payload-sensitive destructive semantics for selected mutation fields
    - name/action heuristics as a deterministic fallback
    - keeper mutation floor: keeper file/PR mutations are elevated to at least High

    Result classes:
    - Critical: destructive ops or destructive payload semantics
    - High: write ops
    - Medium: state-changing reads
    - Low: readonly/status/query surfaces *)

val auto_approval_hard_forbidden :
  risk:risk_level -> Keeper_meta_contract.keeper_meta option -> bool
(** True when auto-approval must be blocked regardless of HITL threshold. *)

val decide :
  ?meta:Keeper_meta_contract.keeper_meta ->
  governance_level:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  unit ->
  governance_decision
(** Evaluate a tool call against governance policy and return a decision.
    - development: allow Low/Medium/High while HITL is enabled, audit High+Critical,
      but always confirm hard-forbidden calls
    - production: confirm Critical, audit Medium+
    - enterprise: confirm High+Critical, audit all
    - paranoid: confirm Medium+High+Critical, audit all

    [meta] is optional because front-door governance is server-scoped:
    it classifies the tool call itself and does not need keeper runtime
    state. The [runtime_auto_approval_blocked] component of
    [auto_approval_hard_forbidden] is keeper-scoped (it inspects
    [meta.runtime.last_blocker]), so passing [None] from the front door
    is intentional and correct.

    Hard-forbidden calls (Critical risk or keeper runtime blocker) always
    require confirmation, even if they would otherwise fall below the
    governance threshold, and even when HITL thresholds are disabled, so
    disabling HITL cannot silently auto-approve destructive operations. *)

val make_pre_hook :
  ?meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  governance_level:string ->
  unit ->
  Tool_dispatch.pre_hook
(** Create a Tool_dispatch pre_hook closure for the given governance level.
    Returns [Pass] (proceed) for allowed calls,
    [Reject result] (short-circuit) for confirm-required or denied calls.

    [meta] is forwarded to {!decide}; see {!decide} for the scope note. *)

val install :
  ?meta:Keeper_meta_contract.keeper_meta ->
  config:Workspace.config ->
  governance_level:string ->
  unit ->
  unit
(** Register the governance pipeline as a Tool_dispatch pre_hook.
    Reads governance level from the [governance_level] argument.
    Called once at server startup.

    [meta] is forwarded to {!make_pre_hook}; see {!decide} for the scope
    note. The server bootstrap caller passes [None] because front-door
    governance is server-scoped. *)

(** {1 Combinatorial Risk — Lethal Trifecta}

    Simon Willison's "Lethal Trifecta": an agent simultaneously holding
    untrusted input + sensitive access + state modification = security risk.
    When all 3 classes are present, state-modifying tools get risk escalation.

    @since 2.264.0 *)

type capability_class =
  | External_input      (** Receives data from untrusted external sources *)
  | Sensitive_access    (** Can read potentially sensitive data *)
  | State_modification  (** Can modify system state *)

val tool_capabilities : string -> capability_class list
(** Return capability classes for a tool name. Empty for unclassified tools. *)

val assess_trifecta :
  active_tool_names:string list -> int * bool * bool * bool
(** Compute trifecta status from active tool names.
    Returns [(class_count, has_external, has_sensitive, has_state_mod)]. *)

val combinatorial_risk_escalation :
  trifecta_active:bool ->
  tool_name:string ->
  base_risk:risk_level ->
  input:Yojson.Safe.t ->
  risk_level
(** If trifecta is active and the tool is a state_modification tool,
    escalate risk to at least High. Otherwise return base_risk unchanged. *)

type hitl_approval_grant
(** Cycle-scoped, one-shot authorization derived from a durable
    [Hitl_resolved] wake. The type is abstract so callers cannot reset or forge
    its consumed state. *)

val hitl_approval_grant_of_resolution :
  Keeper_event_queue.hitl_resolution -> hitl_approval_grant option
(** Return a fresh one-shot grant for an approved resolution. Rejected and
    edited resolutions do not authorize a tool call. *)

val to_oas_approval_callback :
  config:Workspace.config ->
  governance_level:string ->
  keeper_name:string ->
  ?meta:Keeper_meta_contract.keeper_meta ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?lane_policy:Keeper_approval_queue.lane_policy ->
  ?hitl_approval_grant:hitl_approval_grant ->
  unit ->
  Agent_sdk.Hooks.approval_callback
(** Build an OAS approval callback with HITL approval handling.

    Pre-computes trifecta status from the keeper's active shard tool set.
    When trifecta is active, state-modifying tools get risk escalation.

    With [lane_policy = Blocking] (the compatibility default), a tool that
    exceeds the governance threshold suspends via
    [Keeper_approval_queue.submit_and_await]. With [Nonblocking], the approval
    is registered with [Keeper_approval_queue.submit_pending_observer], the
    approval callback returns a
    typed-in-protocol rejection, and the resolution wake starts a later
    independent Keeper cycle. Production Keeper runs use [Nonblocking] so
    ordinary tool approval cannot monopolize the Keeper lane.

    [hitl_approval_grant] authorizes only the exact keeper/tool/full-input
    fingerprint approved by the operator, and is atomically consumed once.
    It is scoped by the caller to the independent cycle opened by that wake;
    there is no persisted blanket rule or time-based grant.

    Tools below the threshold are auto-approved unless auto-approval is
    explicitly forbidden. Critical risk and runtime safety blockers still enter
    the operator approval queue even when HITL thresholds are otherwise
    disabled. Soft destructive tool-name/op heuristics are HITL-dependent.

    @since 2.262.0 (#5902, #5907) *)
