(** Typed refusal at the account-access / turn-authorization boundary.

    Replaces the flattened [Agent_core.Error.Config (InvalidConfig { field = "account"; ... })]
    carrier produced by [Keeper_turn_driver.account_refused]. Every arm maps to
    a stable wire tag and a fixed person-safe message containing no server
    filesystem paths or credentials. *)

type key_unusable_reason =
  | Key_missing
  | Path_not_absolute
  | Not_a_regular_file
  | Open_to_others
  | Not_a_key

type t =
  | Access_not_published
  | Operator_turn_refused
  | Authorization_zone_uncertain
  | Channel_not_allowed
  | Caller_not_authorized
  | Pat_expired
  | Pat_scope_not_explicit
  | Scope_or_grant_refused
  | Owner_inactive
  | Provider_account_unavailable
  | Runtime_reassigned
  | Unknown_keeper
  | Authorization_not_bootstrapped
  | Account_home_unresolved
  | Account_home_invalid
  | Key_unusable of key_unusable_reason
  | Host_account_refused
  | Accounts_disabled

val all : t list
val equal : t -> t -> bool
val to_wire : t -> string
val of_wire : string -> (t, string) result
val to_string : t -> string
val core_error : t -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> t option
