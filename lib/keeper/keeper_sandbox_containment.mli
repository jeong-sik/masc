(** Keeper_sandbox_containment — symmetric host-FS guard for hardened
    keepers (RFC-0006 Phase B-1).

    The keeper sandbox boundary historically followed the tool name:
    [keeper_bash] for [sandbox_profile=Docker] keepers ran in a
    container, but [keeper_fs_read] / [keeper_shell] read directly
    from the host. The result was a one-way leak — write was gated,
    read was not.

    This module enforces "whichever profile decides one tool, decides
    every tool" on the host side without spinning up a per-call
    container. When the symmetric-sandbox env flag is set
    ([MASC_KEEPER_SYMMETRIC_SANDBOX=true]) AND the keeper's profile is
    [Docker], read targets must lie within the keeper's playground
    bundle ([.masc/playground/<keeper>/]).

    Phase B-2 will route the same tools through [docker exec] so the
    container's mount restrictions become the actual primary boundary;
    this host-side guard remains as defense-in-depth. *)

(** [check_read_target ~config ~meta ~target] returns [Ok ()] when the
    resolved file path [target] is permitted under the keeper's
    effective sandbox containment policy.

    Returns [Error msg] only when ALL of the following hold:
    - [meta.sandbox_profile = Docker]
    - [Env_config_keeper.KeeperSandbox.symmetric_read_containment ()] is true
    - [target] does NOT resolve under the keeper's playground bundle root

    A no-op (always [Ok ()]) for legacy keepers and for hardened
    keepers when the env flag is off. *)
val check_read_target :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  target:string ->
  (unit, string) result
