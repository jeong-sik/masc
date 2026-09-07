(** Agent task tool runtime — claim, transition, list. *)

(** Which {!Tool_result.tool_failure_class} a {!Workspace_task.add_task_error}
    routes to when [keeper_task_create] surfaces it. [Unknown_predecessor] /
    [Predecessor_not_terminal] are caller-input workflow violations
    ([Workflow_rejection]); the other four are file-IO/exception failures
    ([Runtime_failure]) so they are not demoted to WARN by
    {!Tool_result.log_level_of_failure_class}. Exposed (like
    [validation_error_json] above) so the split can be tested directly
    against all six variants: [keeper_task_create]'s live tool args never
    set [predecessor_task_id] (RFC-0323 W2 scopes that arg to
    [masc_add_task]), so [Unknown_predecessor] / [Predecessor_not_terminal]
    cannot be produced end-to-end through this tool today. *)
type task_create_failure_route =
  | Task_create_workflow_rejection
  | Task_create_runtime_failure

val task_create_failure_route : Workspace_task.add_task_error -> task_create_failure_route

val handle_keeper_task_tool :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val evidence_artifact_reader :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (worker:string ->
   relative:string ->
   Workspace_verification_store.artifact_read_result)
  option
(** The submit-boundary artifact read for a producer whose sandbox keeps its
    tree on the endpoint (microvm, remote-ssh): the guest's work volume,
    reached through the sandbox backend. [None] for a shared-mount (Docker)
    keeper -- its tree sits on the host playground the store reads directly --
    and for callers that want the store's default direct read. *)

val handle_keeper_task_tool_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

