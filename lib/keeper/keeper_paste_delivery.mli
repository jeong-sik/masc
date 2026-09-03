(** Lazy delivery of TUI-spilled pastes to endpoint-owned keeper workspaces.

    The TUI writes an operator's spilled paste into the keeper's host
    bookkeeping bundle ([Keeper_sandbox.host_root_abs_of_meta]) because at
    paste time there may be no endpoint to write to: a microvm guest may be
    stopped, and only a turn's sandbox factory may start one
    ([microvm_remote_requires_turn_sandbox_factory]). The keeper-facing
    message names the bare file name as sitting in the working directory, so
    at turn setup — the first moment a turn-owned endpoint exists — every
    staged [pasted-*.txt] is written to the endpoint's workspace root
    through the remote lane and removed from staging once it is there.

    Shared-mount (Docker) keepers never reach this module: the directory the
    TUI wrote is the bind-mounted workspace itself.

    Constitution [failure_keeps_evidence]: a failed delivery keeps the
    staged file, so the next turn retries and the paste is never silently
    dropped. *)

type retain_reason =
  | Staging_read_failed of string
  | Remote_write_failed of string

type outcome =
  | Delivered of { file_name : string; bytes : int }
  | Retained of { file_name : string; reason : retain_reason }

val retain_reason_to_string : retain_reason -> string

val staged_file_names : staging_dir:string -> string list
(** Basenames of the regular [pasted-*.txt] files sitting directly under
    [staging_dir], sorted. A missing or unreadable staging directory means
    nothing was ever staged, not an error. *)

val deliver_staged_pastes :
  write:(file_name:string -> content:string -> (unit, string) result) ->
  staging_dir:string ->
  outcome list
(** Write every staged paste through [write] and remove the staged copy of
    each one that lands. [write] is the delivery transport; the production
    wiring supplies the remote-lane write, tests supply a recorder. *)

val deliver_for_turn :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  unit
(** Turn-setup entry point. No-op for [Shared_mount] keepers and for turns
    with nothing staged — the endpoint is only acquired (a stopped guest
    only started) when a staged paste actually waits. The endpoint comes
    from the turn's own sandbox factory, the only owner allowed to boot a
    guest; the write goes through
    {!Keeper_tool_filesystem_remote_write.handle_with_endpoint} so the same
    jail, translation, and lease rules apply as a keeper-issued Write. *)
