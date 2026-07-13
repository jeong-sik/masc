(** {1 Path resolution} *)

val resolve_tool_read_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val resolve_tool_execute_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  write_enabled:bool ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve typed Execute cwd. Uses the keeper write boundary default
    for omitted cwd only when write execution is enabled; read-only
    Execute uses the no-create playground root. Explicit cwd resolution
    never creates directories or changes repo/worktree state. *)

val resolve_tool_read_path :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve the [path] arg exactly against the selected cwd and objective
    allowed-root containment. No path correction or rewriting is applied. *)

val shell_command_available : string -> bool
(** PATH executable probe for workspace read fallback selection.
    This intentionally avoids [/bin/sh -c] and does not treat empty
    PATH entries as the current directory. *)

val in_playground :
  root:string -> cwd:string -> meta:Keeper_meta_contract.keeper_meta -> bool
(** [true] when [cwd] is inside the keeper's sandbox playground,
    or equal to it.  Normalises both paths before comparison so that
    trailing slashes do not affect the result. *)
