(** Runtime adapter for IDE annotation agent tools.

    @since 0.6.0 — observational IDE Phase 1 *)

val handle_ide_annotate :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_ide_annotate_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Handle [keeper_ide_annotate] tool call. Creates a line-bound
    annotation in the [.masc-ide/] store and returns the created
    record's id and positions on success, or an error message.
    The [(codebase, file_path)] pair must be the server-minted catalog slug
    and repo-relative path exposed by the current IDE co-view. Unknown
    codebases, absolute paths, and malformed anchors fail closed. *)
