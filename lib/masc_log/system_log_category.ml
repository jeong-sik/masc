type t =
  | Task_ownership_ambiguity_current_task_unset
  | State_store_current_task_path_corruption
  | Config_env_allowlist_drift
  | Telemetry_or_metadata_parse_drop
  | Host_fd_pressure
  | Docker_start_pressure
  | Provider_timeout
  | Provider_runtime_exhaustion
  | Task_state_probe_misuse
  | Verifier_action_guard
  | Network_error_other
  | Other_boundary_unclassified of { hint : string }

let to_string = function
  | Task_ownership_ambiguity_current_task_unset ->
      "task_ownership_ambiguity_current_task_unset"
  | State_store_current_task_path_corruption ->
      "state_store_current_task_path_corruption"
  | Config_env_allowlist_drift -> "config_env_allowlist_drift"
  | Telemetry_or_metadata_parse_drop -> "telemetry_or_metadata_parse_drop"
  | Host_fd_pressure -> "host_fd_pressure"
  | Docker_start_pressure -> "docker_start_pressure"
  | Provider_timeout -> "provider_timeout"
  | Provider_runtime_exhaustion -> "provider_runtime_exhaustion"
  | Task_state_probe_misuse -> "task_state_probe_misuse"
  | Verifier_action_guard -> "verifier_action_guard"
  | Network_error_other -> "network_error_other"
  | Other_boundary_unclassified { hint } -> Printf.sprintf "other:%s" hint

let all =
  [
    Task_ownership_ambiguity_current_task_unset;
    State_store_current_task_path_corruption;
    Config_env_allowlist_drift;
    Telemetry_or_metadata_parse_drop;
    Host_fd_pressure;
    Docker_start_pressure;
    Provider_timeout;
    Provider_runtime_exhaustion;
    Task_state_probe_misuse;
    Verifier_action_guard;
    Network_error_other;
  ]

let of_string_opt raw =
  match raw with
  | "task_ownership_ambiguity_current_task_unset" ->
      Some Task_ownership_ambiguity_current_task_unset
  | "state_store_current_task_path_corruption" ->
      Some State_store_current_task_path_corruption
  | "config_env_allowlist_drift" -> Some Config_env_allowlist_drift
  | "telemetry_or_metadata_parse_drop" -> Some Telemetry_or_metadata_parse_drop
  | "host_fd_pressure" -> Some Host_fd_pressure
  | "docker_start_pressure" -> Some Docker_start_pressure
  | "provider_timeout" -> Some Provider_timeout
  | "provider_runtime_exhaustion" -> Some Provider_runtime_exhaustion
  | "task_state_probe_misuse" -> Some Task_state_probe_misuse
  | "verifier_action_guard" -> Some Verifier_action_guard
  | "network_error_other" -> Some Network_error_other
  | _ -> None
