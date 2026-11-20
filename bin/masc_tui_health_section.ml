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
  | Fd_observation -> say "파일 디스크립터 관측" "FD observation"
  | Fd_accountant -> say "파일 디스크립터 집계" "FD accountant"
  | Provider_connection_cache -> say "제공자 연결 캐시" "Provider connection cache"
  | Disk_observation -> say "디스크 관측" "Disk observation"
  | Keeper_fleet_safety -> say "키퍼 플릿 안전" "Fleet safety"
  | Keeper_identity_drift -> say "키퍼 식별 불일치" "Identity drift"
  | Keeper_memory_attention -> say "기억 주의 필요" "Memory attention"
  | Publication_recovery_activation -> say "게시 복구 활성화" "Publication recovery activation"
  | Keeper_reaction_ledger -> say "반응 원장" "Reaction ledger"
  | Keeper_owner -> say "키퍼 소유자" "Keeper owner"
  | Keeper_board_event_collection -> say "보드 이벤트 수집" "Board event collection"
  | Keeper_hitl_gate -> say "HITL 게이트" "HITL gate"
  | Typesafeai -> "TypeSafe AI"
  | Keeper_terminal_effect_policy -> say "터미널 효과 정책" "Terminal effect policy"
  | Keeper_observability_artifacts -> say "관측 산출물" "Observability artifacts"
  | Tla_source_observation -> say "TLA 소스 관측" "TLA source observation"
  | Auxiliary_startup -> say "보조 시작" "Auxiliary startup"
  | Paused_keepers -> say "일시정지된 키퍼" "Paused keepers"
  | Runtime_startup_degradation -> say "런타임 시작 저하" "Runtime startup degradation"
