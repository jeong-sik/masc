(** The [skill_catalog] section of [/health?full=1].

    A Skill configuration the catalog cannot use drops every source, so every
    Keeper sees no Skills. Boot does not stop for it, and saving a corrected
    runtime.toml republishes the catalog, so the operator is told here instead
    of by a boot gate. Before this the state showed only in [/api/v1/skills]
    and [/health] stayed ok (#39269). *)

val to_yojson :
  (Server_skill_snapshot_runtime.lookup, Server_skill_snapshot_runtime.error) result ->
  Yojson.Safe.t
(** [status] is [ok] for a configured catalog, including one with no sources
    or only missing source directories. A source that cannot be read or
    resolved, or is not a directory, makes it [degraded] and names the source.

    A rejected or unreadable configuration is [degraded] with
    [operator_action_required]. Its [operator_action_reasons] hold one line
    per diagnostic, naming what is wrong and where to fix it. A rejected line
    carries the diagnostic and the runtime.toml path the snapshot was built
    from, as the boot WARN and the save-path 400 print them.

    A published snapshot also reports [config_path], [skills], [rejections]
    and its [sources] by observation. Source failures also move the grade.

    A workspace with no published snapshot is [snapshot_not_ready] and needs
    no answer here: boot publishes one whenever runtime.toml can be read, so
    the missing snapshot is the runtime setup the startup state already asks
    for.

    A workspace the catalog cannot resolve is [unavailable] with
    [operator_action_required]. *)

val placeholder :
  ?error:string -> component_timed_out:bool -> status:string -> unit -> Yojson.Safe.t
(** The section when the health snapshot has no reading of the catalog: no
    server state yet, or a refresh that timed out or raised. It keeps the
    schema and asks nothing of the operator. *)
