(** Foundational rate limit types to avoid circular dependencies. *)

(** Rate limit categories *)
type rate_limit_category =
  | GeneralLimit
  | BroadcastLimit
  | TaskOpsLimit
[@@deriving show { with_path = false }]

(** Rate limit config *)
type rate_limit_config = {
  per_minute: int;
  burst_allowed: int;
  priority_agents: string list;
  worker_multiplier: float;
  admin_multiplier: float;
  broadcast_per_minute: int;
  task_ops_per_minute: int;
} [@@deriving show]

(** Rate limit error - returned when limit exceeded *)
type rate_limit_error = {
  limit: int;
  current: int;
  wait_seconds: int;
  category: rate_limit_category;
} [@@deriving show]

(** Product-facing agent quota tiers. *)
type agent_quota_tier =
  | P0
  | P1
  | P2
[@@deriving show { with_path = false }]

(** Contract labels for quota-control concepts; no runtime infra here. *)
type agent_quota_control =
  | LeaseExpiry
  | Backpressure
  | AdaptiveRate
[@@deriving show { with_path = false }]

(** Static operator contract for one quota tier. *)
type agent_quota_tier_contract = {
  contract_tier: agent_quota_tier;
  code: string;
  label: string;
  workload_label: string;
  share_percent: int;
  default_req_per_min: int;
} [@@deriving show]

(** Computed request budget for one quota tier. *)
type agent_quota_allocation = {
  allocation_tier: agent_quota_tier;
  allocation_percent: int;
  allocation_req_per_min: int;
} [@@deriving show]
