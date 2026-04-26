(** Keeper_sandbox_containment — symmetric host-FS guard for hardened
    keepers (RFC-0006 Phase B-1).

    The keeper sandbox boundary historically followed the tool name:
    [keeper_bash] for [sandbox_profile=Docker] keepers ran in a
    container, but [keeper_fs_read] / [keeper_fs_edit] / [keeper_shell]
    could touch the host directly. The result was a cross-tool leak:
    different tools enforced different boundaries for the same keeper.

    This module enforces "whichever profile decides one tool, decides
    every tool" on the host side without spinning up a per-call
    container. When the keeper's profile is [Docker], read and write
    targets must lie within the keeper's playground bundle
    ([.masc/playground/<keeper>/]).

    Phase B-2 will route the same tools through [docker exec] so the
    container's mount restrictions become the actual primary boundary;
    this host-side guard remains as defense-in-depth. *)

(** [check_read_target ~config ~meta ~target] returns [Ok ()] when the
    resolved file path [target] is permitted under the keeper's
    effective sandbox containment policy.

    Returns [Error msg] only when ALL of the following hold:
    - [meta.sandbox_profile = Docker]
    - [target] does NOT resolve under the keeper's playground bundle root

    A no-op (always [Ok ()]) for local keepers. *)
val check_read_target
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> target:string
  -> (unit, string) result

(** [check_write_target] is the write-side counterpart to
    [check_read_target]. A no-op for local keepers; for Docker keepers,
    host writes are limited to the keeper playground bundle. *)
val check_write_target
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> target:string
  -> (unit, string) result
