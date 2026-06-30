(** Keeper_approval_queue — Eio.Promise-based HITL approval for keeper tools.

    When a keeper's OAS Agent invokes a tool that requires approval,
    the agent fiber is suspended via [Eio.Promise.await]. An operator
    can then approve/reject via the dashboard approval HTTP handler,
    which resolves the promise and resumes the agent.

    @since 2.262.0 (#5907) *)

(** Risk level of a pending approval. *)
type risk_level =
  | Low
  | Medium
  | High
  | Critical

(** [Agent_sdk.Hooks.approval_decision] alias used as the resolver type. *)
type decision = Agent_sdk.Hooks.approval_decision

type approval_audit_decision =
  | Approval_resolved of decision
  | Approval_expired of string

(** Pending approval entry — the suspended-fiber side of the
    Eio.Promise rendez-vous. *)
type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; action_key : string
  ; input_hash : string
  ; sandbox_target : string
  ; sandbox_profile : string option
  ; backend : string option
  ; input : Yojson.Safe.t
  ; risk_level : risk_level
  ; requested_at : float
  ; turn_id : int option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; runtime_contract : Yojson.Safe.t option
  (* Legacy/internal OAS model hint. Public approval JSON redacts this field. *)
  ; selected_model : string option
  ; disposition : string option
  ; disposition_reason : string option
  ; audit_base_path : string
  ; resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option
  ; on_resolution : (Agent_sdk.Hooks.approval_decision -> unit) option
  }

(** Persisted auto-approval rule that can satisfy a pending entry
    without a human prompt. *)
type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; sandbox_profile : string option
  ; backend : string option
  ; request_fingerprint : string
  ; request_fingerprint_preview : string
  ; max_risk : risk_level
  ; created_at : float
  ; created_by : string option
  ; last_matched_at : float option
  ; match_count : int
  ; source_approval_id : string option
  }

(** Match metadata returned alongside a rule lookup. *)
type rule_match =
  { rule_id : string
  ; matched_by : string
  }

(** Result of [resolve_with_policy] — when the operator opted to
    remember the decision as a rule, [remembered_rule] carries it. *)
type resolution_result =
  { remembered_rule : approval_rule option
  }

(** Error variant returned by the [resolve] family. *)
type resolve_error =
  | Not_found of string
  | Already_resolved of string

val resolve_error_to_string : resolve_error -> string

val risk_level_to_string : risk_level -> string
val risk_level_to_int : risk_level -> int
val risk_level_of_string : string -> risk_level option
val approval_decision_to_string : decision -> string
val approval_audit_decision_to_string : approval_audit_decision -> string

(** {1 Rule store (persisted)} *)

(** List every persisted rule for the given [base_path]. *)
val list_rules : base_path:string -> unit -> approval_rule list

(** Render the persisted rules as a dashboard-facing JSON document. *)
val list_rules_dashboard_json : base_path:string -> unit -> Yojson.Safe.t

(** Per-keeper policy summary projection consumed by the dashboard. *)
val policy_summary_json :
  base_path:string -> keeper_name:string -> Yojson.Safe.t

(** Insert or fetch an approval rule. Returns [(rule, created)]:
    [created = true] when a new rule was persisted, [false] when an
    equivalent rule already existed for the
    [(keeper_name, tool_name, request_fingerprint)] key. Save errors
    are logged but not surfaced to the caller. *)
val upsert_rule :
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  risk_level:risk_level ->
  ?sandbox_profile:string ->
  ?backend:string ->
  ?runtime_contract:Yojson.Safe.t ->
  ?created_by:string ->
  ?source_approval_id:string ->
  unit ->
  approval_rule * bool

(** Delete the rule whose [id] matches. *)
val delete_rule :
  base_path:string -> id:string -> unit -> (approval_rule, string) result

(** Find a rule that satisfies the given keeper / tool / input
    request, updating [last_matched_at] and [match_count] on hit. *)
val find_matching_rule :
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  risk_level:risk_level ->
  ?sandbox_profile:string ->
  ?backend:string ->
  ?runtime_contract:Yojson.Safe.t ->
  unit ->
  rule_match option

(** {1 Audit log} *)

val audit_approval_event :
  base_path:string ->
  event_type:string ->
  id:string ->
  keeper_name:string ->
  tool_name:string ->
  risk_level:risk_level ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  ?goal_ids:string list ->
  ?sandbox_target:string ->
  ?runtime_contract:Yojson.Safe.t ->
  ?selected_model:string ->
  ?disposition:string ->
  ?disposition_reason:string ->
  ?rule_match:rule_match ->
  ?source_approval_id:string ->
  ?auto_approved:bool ->
  ?decision:approval_audit_decision ->
  unit ->
  unit

val audit_rule_event :
  base_path:string -> event_type:string -> approval_rule -> unit

val approval_audit_pending_event : string
(** Event tag persisted when an approval is pending. *)

val approval_audit_resolved_event : string
(** Event tag persisted when an approval is resolved. *)

val approval_audit_hard_forbidden_event : string
(** Event tag persisted when governance rejects a hard-forbidden approval. *)

val approval_audit_soft_forbidden_event : string
(** Event tag persisted when governance rejects a soft-forbidden approval. *)

val recent_resolved_history_limit : int
(** Default dashboard history length for resolved HITL approvals. *)

(** Read recent audit entries (default last 20), optionally filtered
    by keeper. *)
val read_recent_audit :
  base_path:string ->
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  Yojson.Safe.t list

(** Read recent resolved audit entries (default last 20). *)
val list_recent_resolved_json :
  base_path:string -> ?n:int -> unit -> Yojson.Safe.t list

module For_testing : sig
  val reset_audit_store : unit -> unit
  val first_cmd_token : string -> string option
end

(** {1 Submit & await} *)

val default_noncritical_approval_timeout_s : float
(** Default operator wait used by [submit_and_await] for non-critical
    approvals. OAS/runtime bridge deadlines that wrap keeper execution must
    not be shorter than this, otherwise a valid HITL wait is misclassified as
    provider idleness. *)

(** Submit a tool call for approval and suspend the calling fiber.
    Returns the operator's decision when the promise is resolved.
    Called from the OAS approval_callback (inside the agent fiber). *)
val submit_and_await :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  risk_level:risk_level ->
  base_path:string ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  ?goal_ids:string list ->
  ?sandbox_target:string ->
  ?sandbox_profile:string ->
  ?backend:string ->
  ?runtime_contract:Yojson.Safe.t ->
  ?selected_model:string ->
  ?disposition:string ->
  ?disposition_reason:string ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?timeout_s:float ->
  unit ->
  Agent_sdk.Hooks.approval_decision

(** Submit a tool call for approval without suspending the caller —
    the supplied [on_resolution] callback is invoked when the
    operator resolves. Returns the new pending entry's id, or the
    existing id when an equivalent entry is already pending. *)
val submit_pending :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  risk_level:risk_level ->
  base_path:string ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  ?goal_ids:string list ->
  ?sandbox_target:string ->
  ?sandbox_profile:string ->
  ?backend:string ->
  ?runtime_contract:Yojson.Safe.t ->
  ?selected_model:string ->
  ?disposition:string ->
  ?disposition_reason:string ->
  on_resolution:(Agent_sdk.Hooks.approval_decision -> unit) ->
  unit ->
  string

(** {1 Resolve (operator action)} *)

(** Resolve a pending approval and optionally remember the decision
    as a rule. Returns [Not_found] when [id] is absent or
    [Already_resolved] on concurrent-resolve race. *)
val resolve_with_policy :
  base_path:string ->
  id:string ->
  decision:Agent_sdk.Hooks.approval_decision ->
  ?remember_rule:bool ->
  ?created_by:string ->
  unit ->
  (resolution_result, resolve_error) result

(** Convenience over [resolve_with_policy] that discards the
    resolution result. Called from the dashboard approval HTTP
    handler and the MCP runtime. *)
val resolve :
  id:string ->
  decision:Agent_sdk.Hooks.approval_decision ->
  (unit, resolve_error) result

(** {1 Query} *)

val list_pending_json : unit -> Yojson.Safe.t
val list_pending_dashboard_json : unit -> Yojson.Safe.t

(** Detail view of a single pending entry with input + runtime
    contract included. *)
val get_pending_json : id:string -> Yojson.Safe.t option

val pending_count : unit -> int
val pending_count_for_keeper : keeper_name:string -> int
val has_pending_for_keeper : keeper_name:string -> bool

(** {1 Timeout cleanup} *)

(** Reject all non-[Critical] approvals waiting longer than
    [max_wait_s]. [Critical] entries are exempt — they originate
    from indefinite-wait operator gates and must be resolved
    manually. *)
val expire_stale : max_wait_s:float -> unit
