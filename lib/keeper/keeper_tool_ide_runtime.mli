(** Runtime adapter for IDE annotation agent tools.

    @since 0.6.0 — observational IDE Phase 1 *)

val handle_ide_annotate :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  string
(** Handle [keeper_ide_annotate] tool call. Creates a line-bound
    annotation in the [.masc-ide/] store and returns the created
    record's id and positions on success, or an error message.
    Relative [file_path] inputs are anchored at the keeper's playground
    sandbox root before partition resolution (#23469), so annotations on
    playground repo clones land in the repo's [By_url] bucket with a
    repo-relative [file_path]. *)
