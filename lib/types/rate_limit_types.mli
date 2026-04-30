(** Foundational rate limit types — kept here to avoid circular
    dependencies between [masc_error] and the rate-limit consumers.

    Re-exported by {!Masc_error} via [include module type of
    Rate_limit_types]; downstream callers reach these types as
    [Masc_error.rate_limit_*] / [Types.rate_limit_*] depending on the
    re-export chain. *)

(** Rate limit categories. *)
type rate_limit_category =
  | GeneralLimit
  | BroadcastLimit
  | TaskOpsLimit
[@@deriving show { with_path = false }]

(** Rate limit configuration record. *)
type rate_limit_config = {
  per_minute : int;
  burst_allowed : int;
  priority_agents : string list;
  worker_multiplier : float;
  admin_multiplier : float;
  broadcast_per_minute : int;
  task_ops_per_minute : int;
}
[@@deriving show]

(** Returned when a rate limit is exceeded. *)
type rate_limit_error = {
  limit : int;
  current : int;
  wait_seconds : int;
  category : rate_limit_category;
}
[@@deriving show]

(** Product-facing agent quota tiers.  These are MASC-owned operator
    terms, not OAS provider vocabulary. *)
type agent_quota_tier =
  | P0
  | P1
  | P2
[@@deriving show { with_path = false }]

(** Small labels for future quota controls.  This module only names the
    contract; it does not implement lease/backpressure infrastructure. *)
type agent_quota_control =
  | LeaseExpiry
  | Backpressure
  | AdaptiveRate
[@@deriving show { with_path = false }]

(** Static operator contract for one quota tier. *)
type agent_quota_tier_contract = {
  contract_tier : agent_quota_tier;
  code : string;
  label : string;
  workload_label : string;
  share_percent : int;
  default_req_per_min : int;
}
[@@deriving show]

(** Computed request budget for one quota tier. *)
type agent_quota_allocation = {
  allocation_tier : agent_quota_tier;
  allocation_percent : int;
  allocation_req_per_min : int;
}
[@@deriving show]
