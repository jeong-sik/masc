(** Operator_approval — OAS Approval pipeline for operator action
    confirmation.

    Centralises the [confirm_required] logic (previously duplicated
    in 3 files) into a single OAS [Approval] pipeline with typed
    risk levels. Callers consume the predicates ([is_allowed] /
    [confirm_required]), the risk classifier ([risk_of_action]),
    and the public action lists; the [pipeline] / [evaluate_action]
    pair surfaces the OAS Approval gate for downstream policy
    decoders.

    @since OAS integration Phase F *)

(** {1 Action catalogue} *)

val high_risk_actions : string list
(** Action types that always require operator confirmation. Risk
    level is [Agent_sdk.Approval.High] and {!confirm_required} returns
    [true] for every member. *)

val allowed_actions : string list
(** Action types known to the operator surface. Members not in
    {!high_risk_actions} auto-approve through the pipeline; non-members
    fall through to the high-risk gate as [Medium]. *)

(** {1 Risk classification} *)

val risk_of_action : string -> Agent_sdk.Approval.risk_level
(** [High] when the action is in {!high_risk_actions}, [Low] when
    only in {!allowed_actions}, otherwise [Medium]. *)

val is_allowed : string -> bool
(** [true] iff the action is in {!allowed_actions}. *)

val confirm_required : string -> bool
(** [true] iff the action is in {!high_risk_actions}. *)

(** {1 OAS approval pipeline} *)

val pipeline : Agent_sdk.Approval.t
(** The composed pipeline: auto-approve allowed non-high-risk
    actions, then a [high_risk_gate] stage that emits
    [Reject "requires operator confirmation"] for high-risk
    actions and [Pass] otherwise. *)

val evaluate_action :
  action_type:string ->
  agent_name:string ->
  turn:int ->
  Agent_sdk.Hooks.approval_decision
(** Evaluate [action_type] against {!pipeline} with an empty input
    payload. The [agent_name] / [turn] pair is forwarded to the
    OAS approval context. *)
