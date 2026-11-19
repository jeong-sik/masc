type t =
  | Fd_observation
  | Fd_accountant
  | Provider_connection_cache
  | Disk_observation
  | Keeper_fleet_safety
  | Keeper_identity_drift
  | Keeper_memory_execution
  | Keeper_memory_attention
  | Publication_recovery_activation
  | Keeper_reaction_ledger
  | Keeper_owner
  | Keeper_board_event_collection
  | Keeper_hitl_gate
  | Keeper_event_queue
  | Keeper_waiting_inventory
  | Typesafeai
  | Keeper_terminal_effect_policy
  | Keeper_observability_artifacts
  | Skill_catalog
  | Tla_source_observation
  | Auxiliary_startup
  | Paused_keepers
  | Runtime_startup_degradation
  | Keeper_config_schema

let wire_name = function
  | Fd_observation -> "fd_observation"
  | Fd_accountant -> "fd_accountant"
  | Provider_connection_cache -> "provider_connection_cache"
  | Disk_observation -> "disk_observation"
  | Keeper_fleet_safety -> "keeper_fleet_safety"
  | Keeper_identity_drift -> "keeper_identity_drift"
  | Keeper_memory_execution -> "keeper_memory_execution"
  | Keeper_memory_attention -> "keeper_memory_attention"
  | Publication_recovery_activation -> "publication_recovery_activation"
  | Keeper_reaction_ledger -> "keeper_reaction_ledger"
  | Keeper_owner -> "keeper_owner"
  | Keeper_board_event_collection -> "keeper_board_event_collection"
  | Keeper_hitl_gate -> "keeper_hitl_gate"
  | Keeper_event_queue -> "keeper_event_queue"
  | Keeper_waiting_inventory -> "keeper_waiting_inventory"
  | Typesafeai -> "typesafeai"
  | Keeper_terminal_effect_policy -> "keeper_terminal_effect_policy"
  | Keeper_observability_artifacts -> "keeper_observability_artifacts"
  | Skill_catalog -> "skill_catalog"
  | Tla_source_observation -> "tla_source_observation"
  | Auxiliary_startup -> "auxiliary_startup"
  | Paused_keepers -> "paused_keepers"
  | Runtime_startup_degradation -> "runtime_startup_degradation"
  | Keeper_config_schema -> "keeper_config_schema"

(* The decoder is the one place a section name is read as a string. *)
let of_wire = function
  | "fd_observation" -> Ok Fd_observation
  | "fd_accountant" -> Ok Fd_accountant
  | "provider_connection_cache" -> Ok Provider_connection_cache
  | "disk_observation" -> Ok Disk_observation
  | "keeper_fleet_safety" -> Ok Keeper_fleet_safety
  | "keeper_identity_drift" -> Ok Keeper_identity_drift
  | "keeper_memory_execution" -> Ok Keeper_memory_execution
  | "keeper_memory_attention" -> Ok Keeper_memory_attention
  | "publication_recovery_activation" -> Ok Publication_recovery_activation
  | "keeper_reaction_ledger" -> Ok Keeper_reaction_ledger
  | "keeper_owner" -> Ok Keeper_owner
  | "keeper_board_event_collection" -> Ok Keeper_board_event_collection
  | "keeper_hitl_gate" -> Ok Keeper_hitl_gate
  | "keeper_event_queue" -> Ok Keeper_event_queue
  | "keeper_waiting_inventory" -> Ok Keeper_waiting_inventory
  | "typesafeai" -> Ok Typesafeai
  | "keeper_terminal_effect_policy" -> Ok Keeper_terminal_effect_policy
  | "keeper_observability_artifacts" -> Ok Keeper_observability_artifacts
  | "skill_catalog" -> Ok Skill_catalog
  | "tla_source_observation" -> Ok Tla_source_observation
  | "auxiliary_startup" -> Ok Auxiliary_startup
  | "paused_keepers" -> Ok Paused_keepers
  | "runtime_startup_degradation" -> Ok Runtime_startup_degradation
  | "keeper_config_schema" -> Ok Keeper_config_schema
  | received -> Error received

(* Words another screen already draws for the section, or else the words of
   its server name, the same in both languages. *)
let label ~ko section =
  let say korean english = if ko then korean else english in
  match section with
  | Keeper_memory_execution -> say "기억 처리" "Memory execution"
  | Skill_catalog -> say "스킬 목록" "Skill catalog"
  | Keeper_config_schema -> say "키퍼 설정" "Keeper configuration"
  | Keeper_event_queue -> say "이벤트 큐" "Event queue"
  | Keeper_waiting_inventory -> say "대기 목록" "Waiting inventory"
  | Fd_observation -> "FD observation"
  | Fd_accountant -> "FD accountant"
  | Provider_connection_cache -> "Provider connection cache"
  | Disk_observation -> "Disk observation"
  | Keeper_fleet_safety -> "Fleet safety"
  | Keeper_identity_drift -> "Identity drift"
  | Keeper_memory_attention -> "Memory attention"
  | Publication_recovery_activation -> "Publication recovery activation"
  | Keeper_reaction_ledger -> "Reaction ledger"
  | Keeper_owner -> "Keeper owner"
  | Keeper_board_event_collection -> "Board event collection"
  | Keeper_hitl_gate -> "HITL gate"
  | Typesafeai -> "TypeSafe AI"
  | Keeper_terminal_effect_policy -> "Terminal effect policy"
  | Keeper_observability_artifacts -> "Observability artifacts"
  | Tla_source_observation -> "TLA source observation"
  | Auxiliary_startup -> "Auxiliary startup"
  | Paused_keepers -> "Paused keepers"
  | Runtime_startup_degradation -> "Runtime startup degradation"
