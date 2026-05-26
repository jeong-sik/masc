type t =
  | Github_clone_policy_load_failed
  | Policy_config_not_loaded

let to_label = function
  | Github_clone_policy_load_failed -> "github_clone_policy_load_failed"
  | Policy_config_not_loaded -> "policy_config_not_loaded"
;;
