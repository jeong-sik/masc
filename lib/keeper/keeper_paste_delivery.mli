(** Lazy delivery of TUI-spilled pastes to endpoint-owned keeper workspaces.

    The TUI writes an operator's spilled paste into the keeper's host
    bookkeeping bundle ([Keeper_sandbox.host_root_abs_of_meta]) because at
    paste time there may be no endpoint to write to: a microvm guest may be
    stopped, and only a turn's sandbox factory may start one
    ([microvm_remote_requires_turn_sandbox_factory]). The keeper-facing
    message names the bare file name as sitting in the working directory, so
    at turn setup — the first moment a turn-owned endpoint exists — every
    staged paste (the [Keeper_paste_naming] shape) is written to the
    endpoint's workspace root through the remote lane and removed from
    staging once it is there.

    Shared-mount (Docker) keepers never reach this module: the directory the
    TUI wrote is the bind-mounted workspace itself.

    Constitution [failure_keeps_evidence]: a failed delivery keeps the
    staged file, so the next turn retries and the paste is never silently
    dropped. The retained set is also returned to the caller: the pointer
    the operator's message makes ("It is in your working directory") is
    false for every one of them, so turn setup appends an
    {!inlined_correction} to the turn message — the TUI's own fallback
    contract for a paste it cannot place is to send the text itself, and
    the correction does exactly that while saying the file is not there. *)

type retain_reason =
  | Endpoint_unavailable of string
  | Staging_read_failed of string
  | Remote_write_failed of string

type retained_paste =
  { file_name : string
  ; reason : retain_reason
  ; content : string option
        (** The staged bytes, so the caller can still get the text to the
            keeper. [None] only when the staged file itself could not be
            read back. *)
  }

type outcome =
  | Delivered of { file_name : string; bytes : int }
  | Retained of retained_paste

val retain_reason_to_string : retain_reason -> string

val staged_file_names : staging_dir:string -> string list
(** Basenames of the regular files sitting directly under [staging_dir] that
    parse as spilled-paste names ([Keeper_paste_naming]), sorted. A missing
    or unreadable staging directory means nothing was ever staged, not an
    error. *)

val deliver_staged_pastes :
  write:(file_name:string -> content:string -> (unit, string) result) ->
  staging_dir:string ->
  outcome list
(** Write every staged paste through [write] and remove the staged copy of
    each one that lands. [write] is the delivery transport; the production
    wiring supplies {!write_through_endpoint}, tests supply a recorder. *)

val write_through_endpoint :
  endpoint:Keeper_sandbox_remote.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  file_name:string ->
  content:string ->
  (unit, string) result
(** The production transport:
    {!Keeper_tool_filesystem_remote_write.handle_with_endpoint} with the
    Write tool's own args shape, so the same jail, translation, and lease
    rules apply as a keeper-issued Write. Exposed so tests can drive the
    real path projection against a stub endpoint. *)

val inlined_correction : retained_paste list -> string option
(** The turn-message correction for pastes that stayed staged: names the
    file, says it is not in the workspace, and inlines the text when it
    could be read back. [None] when nothing was retained. *)

val deliver_for_turn :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  retained_paste list
(** Turn-setup entry point. Empty for [Shared_mount] keepers and for turns
    with nothing staged — the endpoint is only acquired (a stopped guest
    only started) when a staged paste actually waits. The endpoint comes
    from the turn's own sandbox factory, the only owner allowed to boot a
    guest; the write goes through {!write_through_endpoint}. Every retained
    paste is also reported as a structured [Log.Keeper] warning
    ([error_kind] [keeper_paste_delivery_retained]), the operator-surface
    convention for turn-setup warnings. *)
