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
