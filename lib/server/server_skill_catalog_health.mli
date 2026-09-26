(** The [skill_catalog] section of [/health?full=1].

    A Skill configuration the catalog cannot use drops every source, so every
    Keeper sees no Skills. Boot does not stop for it, and saving a corrected
    runtime.toml republishes the catalog, so the operator is told here instead
    of by a boot gate. Before this the state showed only in [/api/v1/skills]
    and [/health] stayed ok (#39269). *)

val to_yojson :
  (Server_skill_snapshot_runtime.lookup, Server_skill_snapshot_runtime.error) result ->
  Yojson.Safe.t
(** [status] is [ok] for a configured catalog, including one with no sources.

    A rejected or unreadable configuration is [degraded] with
    [operator_action_required]. Its [operator_action_reasons] hold one line
    per diagnostic, naming what is wrong and where to fix it.

    A workspace with no published snapshot is [snapshot_not_ready] and needs
    no answer here: boot publishes one whenever runtime.toml can be read, so
    the missing snapshot is the runtime setup the startup state already asks
    for.

    A workspace the catalog cannot resolve is [unavailable] with
    [operator_action_required]. *)
