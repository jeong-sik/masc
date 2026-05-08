type t =
  [ `Coord_git
  | `Coord_worktree
  | `System_task_sandbox
  | `System_notify
  | `Autoresearch_git
  | `Voice_bridge
  | `Voice_bridge_core
  | `System_graphql_client_eio
  | `System_build_identity
  | `System_runtime_info
  | `System_worktree_live_context
  | `System_startup_takeover
  | `System_worker_container_types
  | `System_worker_runtime_docker
  | `System_spawn
  | `System_auto_responder
  | `Swarm_goal_loop
  | `Coord_identity
  | `Tool_local_runtime
  | `Tool_local_runtime_bench
  | `Tool_autoresearch_cycle
  | `Other_agent
  ]

let of_string = function
  | "coord/git" -> `Coord_git
  | "coord/worktree" -> `Coord_worktree
  | "system/task_sandbox" -> `System_task_sandbox
  | "system/notify" -> `System_notify
  | "autoresearch/git" -> `Autoresearch_git
  | "voice/bridge" -> `Voice_bridge
  | "voice/bridge_core" -> `Voice_bridge_core
  | "system/graphql_client_eio" -> `System_graphql_client_eio
  | "system/build_identity" -> `System_build_identity
  | "system/runtime_info" -> `System_runtime_info
  | "system/worktree_live_context" -> `System_worktree_live_context
  | "system/startup_takeover" -> `System_startup_takeover
  | "system/worker_container_types" -> `System_worker_container_types
  | "system/worker_runtime_docker" -> `System_worker_runtime_docker
  | "system/spawn" -> `System_spawn
  | "system/auto_responder" -> `System_auto_responder
  | "swarm/goal_loop" -> `Swarm_goal_loop
  | "coord/identity" -> `Coord_identity
  | "tool/local_runtime" -> `Tool_local_runtime
  | "tool/local_runtime_bench" -> `Tool_local_runtime_bench
  | "tool/autoresearch_cycle" -> `Tool_autoresearch_cycle
  | _ -> `Other_agent

let to_string = function
  | `Coord_git -> "coord/git"
  | `Coord_worktree -> "coord/worktree"
  | `System_task_sandbox -> "system/task_sandbox"
  | `System_notify -> "system/notify"
  | `Autoresearch_git -> "autoresearch/git"
  | `Voice_bridge -> "voice/bridge"
  | `Voice_bridge_core -> "voice/bridge_core"
  | `System_graphql_client_eio -> "system/graphql_client_eio"
  | `System_build_identity -> "system/build_identity"
  | `System_runtime_info -> "system/runtime_info"
  | `System_worktree_live_context -> "system/worktree_live_context"
  | `System_startup_takeover -> "system/startup_takeover"
  | `System_worker_container_types -> "system/worker_container_types"
  | `System_worker_runtime_docker -> "system/worker_runtime_docker"
  | `System_spawn -> "system/spawn"
  | `System_auto_responder -> "system/auto_responder"
  | `Swarm_goal_loop -> "swarm/goal_loop"
  | `Coord_identity -> "coord/identity"
  | `Tool_local_runtime -> "tool/local_runtime"
  | `Tool_local_runtime_bench -> "tool/local_runtime_bench"
  | `Tool_autoresearch_cycle -> "tool/autoresearch_cycle"
  | `Other_agent -> "other"
