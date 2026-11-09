(** Keeper tools for the world constitution (RFC-0442).

    A keeper writes a norm its world agreed on, or takes one back. Whether the
    world agreed is settled on the board before either call; these tools carry
    the decision to the one place a conversation cannot reach — the system
    prompt every keeper in the world reads. *)

val render_byte_ceiling : int
(** Bytes the rendered articles may occupy. The articles ride every turn of
    every keeper in the world, so this is the one brake RFC-0442 keeps. A world
    at the ceiling takes no new article until someone decides what to drop;
    nothing expires on its own, because a silent deletion is worse than a
    blocked write nobody can miss. *)

val read_with_outcome : config:Workspace.config -> Keeper_tool_execution.t
(** Read the ordered durable entries, active article count, rejected-line
    diagnostics and isolated-line diagnostics. This read-only surface lets a
    later Keeper recover removal reasons without putting withdrawn norms back
    into its prompt. Lines whose subject the keeper roster does not resolve
    are reported as isolated beside the unreadable lines, because a norm that
    stopped rendering must not vanish quietly (RFC-0504 §2.4). *)

val write_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Write one norm, or merge a bundle of held norms into one (RFC-0504 §2.2).
    An absent or empty [replaces] argument writes a plain [Added] line, capped
    at 512 bytes as before. A non-empty [replaces] names held articles and
    writes a [Replaced] line retiring them: every id must be held now, each
    named once, and the replacement must render smaller than the bundle it
    retires while the projected render stays within the ceiling (RFC-0504
    §2.3). An optional [reason] argument lands in the [Replaced] line beside
    [by]/[at]; it is refused on a plain write, where there is nothing it
    could explain. *)

val remove_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Removing an article that is not held is a failure, not a quiet success. A
    keeper that mistyped an id needs to learn that here rather than believe a
    norm is gone. An optional [reason] argument lands in the ledger beside
    [by]/[at]; the success answer names the removed text and echoes the
    reason, so the removal reads as a digest both ways. A supplied reason
    must be nonblank, on one line (no CR or LF), and at most 512 bytes;
    invalid reasons fail before the ledger is changed. *)
