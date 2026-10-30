type t =
  | Keeper_bootstrap_disabled
  | No_executable_keeper_fibers
  | Turn_configuration_error
  | Official_client_recovery_required
  | Reaction_capacity_below_target
  | Active_task_owner_without_executable_fiber
  | Durable_paused_autoboot_enabled

let all =
  [ Keeper_bootstrap_disabled
  ; No_executable_keeper_fibers
  ; Turn_configuration_error
  ; Official_client_recovery_required
  ; Reaction_capacity_below_target
  ; Active_task_owner_without_executable_fiber
  ; Durable_paused_autoboot_enabled
  ]

let wire_name = function
  | Keeper_bootstrap_disabled -> "keeper_bootstrap_disabled"
  | No_executable_keeper_fibers -> "no_executable_keeper_fibers"
  | Turn_configuration_error -> "turn_configuration_error"
  | Official_client_recovery_required -> "official_client_recovery_required"
  | Reaction_capacity_below_target -> "reaction_capacity_below_target"
  | Active_task_owner_without_executable_fiber ->
      "active_task_owner_without_executable_fiber"
  | Durable_paused_autoboot_enabled -> "durable_paused_autoboot_enabled"

let of_wire_name name =
  List.find_opt (fun blocker -> String.equal (wire_name blocker) name) all

let reading_schema = "masc.keeper_fleet_operator.v1"
