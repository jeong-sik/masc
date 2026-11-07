(** The Read tool of [Keeper_tool_filesystem_runtime] for a file in the keeper
    tree or under a root that a remote endpoint declares.

    [read_file_default_max_bytes], [read_file_min_max_bytes] and
    [read_file_max_max_bytes] bound the byte budget of one read, and
    [read_window_fetch_bytes] gives how many bytes a line window fetches.
    [read_line_window_of_args] parses [offset] and [limit] into a line window
    and returns the guidance text when either is out of range.
    [resolve_read_file_cwd] resolves the [cwd] argument and refuses a file or a
    missing directory; for a missing one, [available_cwd_hint] lists the
    checkouts that would have worked. [resolve_read_file_target] turns a path
    into a [read_file_target]: a name in the keeper tree, or a path under a
    declared endpoint root. [check_read_file_target] applies the host
    containment check to the first kind.
    [read_authority_for_call] captures the read authority of a remote_ssh
    keeper that has none, and [read_sandbox_raw_prefix] reads the first bytes
    of a file through the sandbox backend. [prepare_read] prepares the file of
    a shared-mount keeper, [read_prepared_window] reads a line window from it
    and [release_prepared_read] releases it.
    [handle_read_file_with_preparation] runs one Read for a read authority and
    a prepared file and returns its tool outcome.
    [handle_read_file_with_outcome], [handle_read_file_with_authority] and
    [handle_prepared_read_file_with_outcome] fix those two arguments.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_meta_contract
open Keeper_tool_read_window
open Keeper_tool_filesystem_runtime_shared

val read_file_default_max_bytes : int

val read_window_fetch_bytes :
  max_bytes:int -> read_line_window -> int

val read_line_window_of_args :
  Yojson.Safe.t -> (read_line_window, string) result

val string_opt_nonempty : string -> Yojson.Safe.t -> string option

val resolve_read_file_cwd :
  config:Workspace.config ->
  meta:keeper_meta ->
  cwd:string option ->
  (string, Keeper_alerting_path.path_refusal) result

(* A Read that did not return content says whose it is to fix: a path, limit
   or file the caller named is a [Policy_rejection]; a backend or host I/O
   failure is a [Runtime_failure]. *)
type read_file_attempt =
  | Read_succeeded of Yojson.Safe.t
  | Read_refused of
      { failure_class : Tool_result.tool_failure_class
      ; payload : string
      }

val read_sandbox_raw_prefix :
  ?read_authority:Keeper_sandbox_remote_lane.read_authority ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config -> meta:keeper_meta ->
  path:string -> ?cwd:string -> max_bytes:int -> unit ->
  (string, Keeper_sandbox_read_backend.read_error) result

val prepare_read :
  sw:Eio.Switch.t -> config:Workspace.config ->
  meta:keeper_meta -> args:Yojson.Safe.t ->
  (prepared_read option, string) result

val prepared_read_scopes : prepared_read -> Agent_core.Tool_contract.Resource_scope.t list

val release_prepared_read : prepared_read -> unit

val handle_read_file_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

val handle_read_file_with_authority :
  read_authority:Keeper_sandbox_remote_lane.read_authority ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config -> meta:keeper_meta ->
  args:Yojson.Safe.t -> Keeper_tool_execution.t

val handle_prepared_read_file_with_outcome :
  prepared_read:prepared_read -> config:Workspace.config ->
  meta:keeper_meta -> args:Yojson.Safe.t ->
  Keeper_tool_execution.t
