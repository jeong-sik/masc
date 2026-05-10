(** Agent_id — typed agent identity for approval-config dispatch.

    The only way to construct a [t] from a string is {!of_string},
    which maps known agent names to a closed poly-variant.  Unknown
    names fall back to [`Other_agent] so the approval policy stays
    fail-closed (defaults apply). *)

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
  | `Keeper_shell
  | `Other_agent
  ]

val of_string : string -> t
(** Map a runtime agent name to its typed identity.  Unknown names
    become [`Other_agent] so the approval policy falls back to
    [defaults]. *)

val to_string : t -> string
(** Round-trip string for the exec gate's telemetry and error
    messages.  Policy code must stay on the typed value. *)
