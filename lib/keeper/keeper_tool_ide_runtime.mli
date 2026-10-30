(** The keeper's line memo tool.

    [keeper_ide_annotate] composes one comment line in the file's own
    syntax ({!Ide_memo}, {!Lsp_process_manager.memo_line}) and inserts it
    above the named line through the filesystem write path, so the sandbox
    roots, the Gate, the recovery record and the file-change evidence are
    the ones Edit already has. *)

val handle_ide_annotate_with_outcome
  :  turn_sandbox_factory:Keeper_sandbox_factory.t option
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:Keeper_publication_recovery_availability.turn_context
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t
(** [file_path], [line] (1-based) and [text] are required; [kind] is one of
    the grammar's words and defaults to [comment]. The author is the
    keeper's own name. A refusal names its reason: an author or text the
    grammar cannot carry, an extension no language here owns, a language
    with no comment syntax, or a line the file does not have. *)
