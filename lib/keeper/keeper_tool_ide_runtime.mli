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
    RFC-0378 §5.3: the caller hands back the [(codebase slug,
    repo-root-relative path)] pair the co-view context names, verbatim;
    the pair is minted into a [Code_address] and a failed mint is a
    typed reject — nothing is re-derived from sandbox roots. *)
