type t =
  [ `Workspace_git
  | `System_sandbox
  | `System_notify
  | `Voice_bridge
  | `Voice_bridge_core
  | `System_graphql_client_eio
  | `System_build_identity
  | `System_runtime_info
  | `System_startup_takeover
  | `System_worker_container_types
  | `System_worker_runtime_docker
  | `System_spawn
  | `Workspace_identity
  | `Tool_local_runtime
  | `Tool_local_runtime_bench
  | `Tool_execute
  | `Other_agent
  ]

let of_string = function
  | "workspace/git" -> `Workspace_git
  | "system/sandbox" -> `System_sandbox
  | "system/notify" -> `System_notify
  | "voice/bridge" -> `Voice_bridge
  | "voice/bridge_core" -> `Voice_bridge_core
  | "system/graphql_client_eio" -> `System_graphql_client_eio
  | "system/build_identity" -> `System_build_identity
  | "system/runtime_info" -> `System_runtime_info
  | "system/startup_takeover" -> `System_startup_takeover
  | "system/worker_container_types" -> `System_worker_container_types
  | "system/worker_runtime_docker" -> `System_worker_runtime_docker
  | "system/spawn" -> `System_spawn
  | "workspace/identity" -> `Workspace_identity
  | "tool/local_runtime" -> `Tool_local_runtime
  | "tool/local_runtime_bench" -> `Tool_local_runtime_bench
  | "tool/execute" -> `Tool_execute
  | _ -> `Other_agent

let to_string = function
  | `Workspace_git -> "workspace/git"
  | `System_sandbox -> "system/sandbox"
  | `System_notify -> "system/notify"
  | `Voice_bridge -> "voice/bridge"
  | `Voice_bridge_core -> "voice/bridge_core"
  | `System_graphql_client_eio -> "system/graphql_client_eio"
  | `System_build_identity -> "system/build_identity"
  | `System_runtime_info -> "system/runtime_info"
  | `System_startup_takeover -> "system/startup_takeover"
  | `System_worker_container_types -> "system/worker_container_types"
  | `System_worker_runtime_docker -> "system/worker_runtime_docker"
  | `System_spawn -> "system/spawn"
  | `Workspace_identity -> "workspace/identity"
  | `Tool_local_runtime -> "tool/local_runtime"
  | `Tool_local_runtime_bench -> "tool/local_runtime_bench"
  | `Tool_execute -> "tool/execute"
  | `Other_agent -> "other"
