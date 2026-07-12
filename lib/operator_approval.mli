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

(** {1 Operator approval mode} *)

type approval_mode =
  | Manual
  | Auto_low_risk
(** Closed operator approval mode. [Manual] queues gated actions for a
    human. [Auto_low_risk] may only auto-approve the explicit
    auto-eligible band set. *)

type risk_band =
  | Band_low
  | Band_medium
  | Band_high
  | Band_critical
  | Band_unclassified
(** Typed approval risk band used by the mode decision. Unknown or
    missing classifications must be represented as [Band_unclassified]. *)

type approval_mode_queue_reason =
  | Separation_of_duties_floor
  | Metadata_unavailable
  | Automatic_approval_prohibited
  | Manual_mode
  | Not_auto_eligible

type approval_mode_decision =
  | Queue_for_operator of {
      mode : approval_mode;
      band : risk_band;
      reason : approval_mode_queue_reason;
    }
  | Auto_approved of {
      mode : approval_mode;
      band : risk_band;
    }

type approval_mode_change = {
  previous : approval_mode;
  current : approval_mode;
  actor : string;
  changed_at : string;
}

val approval_mode_to_string : approval_mode -> string
val approval_mode_of_string : string -> approval_mode option
val parse_approval_mode_json : Yojson.Safe.t -> (approval_mode, string) result
val risk_band_to_string : risk_band -> string
val risk_band_of_agent_sdk : Agent_sdk.Approval.risk_level -> risk_band
val auto_eligible_bands : risk_band list
val auto_eligible_bands_json : unit -> Yojson.Safe.t
val approval_mode_queue_reason_to_string : approval_mode_queue_reason -> string

val decide_approval_mode :
  mode:approval_mode -> band:risk_band -> approval_mode_decision
(** Apply RFC-0319's separation-of-duties floor before the mode branch.
    [Band_critical], [Band_high], and [Band_unclassified] always queue. *)

val approval_mode_path : base_path:string -> string
val read_approval_mode : base_path:string -> (approval_mode, string) result
val read_approval_mode_or_manual : base_path:string -> approval_mode
val approval_mode_status_json : base_path:string -> Yojson.Safe.t

val set_approval_mode :
  Workspace.config ->
  actor:string ->
  approval_mode ->
  (approval_mode_change, string) result

val approval_mode_change_json : approval_mode_change -> Yojson.Safe.t

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
