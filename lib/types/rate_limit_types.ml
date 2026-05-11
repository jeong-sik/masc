(** Foundational rate limit types to avoid circular dependencies. *)

(** Rate limit categories *)
type rate_limit_category =
  | GeneralLimit
  | BroadcastLimit
  | TaskOpsLimit
[@@deriving show { with_path = false }]

(** Stable wire format for {!rate_limit_category}.  Returns the same
    string [show_rate_limit_category] does today (PascalCase
    constructor name) but locks the JSON wire contract against
    [@@deriving show] template drift and accidental variant renames. *)
let rate_limit_category_to_string = function
  | GeneralLimit -> "GeneralLimit"
  | BroadcastLimit -> "BroadcastLimit"
  | TaskOpsLimit -> "TaskOpsLimit"
;;

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

