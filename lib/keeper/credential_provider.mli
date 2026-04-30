(** Credential provider trait — abstract surface for keeper GitHub
    credential lifecycle.

    The trait centralises credential composition (env + RO mounts +
    metadata) so the docker-invocation site at
    {!Keeper_shell_docker} no longer reaches into multiple SSOTs
    inline.  Concrete implementations:

    - {!Host_config_provider}: selected root/keeper host bundle
      mounted RO.

    Lifecycle (in caller order):
      [resolve] -> [finalize]  (after container start, post-bootstrap)
                -> [tear_down] (idempotent; called from
                                [Eio.Switch.on_release] so crashes
                                still hit it).

    [finalize] and [tear_down] are noops for host-mounted bundles; the
    methods keep the lifecycle explicit for future providers. *)

(** Read-only mount projected from a host path into a container path.
    Empty {!ro_mount.host} or a missing path means the mount is
    skipped (mirrors the inline [optional_ro_mount] helper at
    [keeper_shell_docker.ml:149]). *)
type ro_mount = {
  host : string;
  container : string;
}

(** Materialised credential plan for a single keeper subprocess. *)
type binding = {
  identity : string;
      (** Keeper-scoped identity, e.g. ["anyang-keepers"]. *)
  env : (string * string) list;
      (** Subprocess env pairs.  Composed inside [resolve]; merges
          path-derived entries (HOME, GH_CONFIG_DIR, GIT_CONFIG_COUNT
          + GIT_CONFIG_KEY_0/VALUE_0, plus GIT_AUTHOR_NAME/EMAIL and
          GIT_COMMITTER_NAME/EMAIL) with
          {!Env_git_noninteractive.env}. *)
  ro_mounts : ro_mount list;
      (** Host paths mounted read-only (Option A).  Empty for
          Option B. *)
  bootstrap : string list option;
      (** argv executed inside the container after start ([None] for
          host-mounted bundles). *)
  metadata : (string * string) list;
      (** Audit pairs: [source], [git_identity_mode], optional
          [github_identity], [effective_github_identity],
          [credential_scope], and [bundle_root]. *)
}

(** Provider error variants.  [Missing_bundle] covers a selected
    root/keeper bundle that cannot be materialised. [Invalid_token] is
    reserved for provider gates. [Finalize_failed] / [Tear_down_failed] surface the
    underlying reason without coercing to [string] so the caller can
    log structured fields. *)
type error =
  | Missing_bundle of { identity : string; path : string }
  | Invalid_token of { identity : string; reason : string }
  | Finalize_failed of { identity : string; reason : string }
  | Tear_down_failed of { identity : string; reason : string }

val pp_error : error -> string
(** Human-readable rendering for log lines. *)

(** Module signature implemented by each concrete provider.  RFC-0008
    §3 spelled this as [include module type of Credential_provider];
    in OCaml the idiomatic equivalent is a named [module type S] that
    callers can refer to as [Credential_provider.S]. *)
module type S = sig
  val resolve :
    config:Coord.config -> identity:string -> (binding, error) result
  (** Must be total.  Pure up to filesystem read; no network. *)

  val finalize :
    binding -> container_id:string -> (unit, error) result
  (** Called once per keeper session, after the container is up and
      (for Option B) after [bootstrap] argv has executed.
      Implementations MUST rewrite [hosts.yml:user] to
      [binding.identity] when that file exists in any writable mount. *)

  val tear_down : binding -> container_id:string option -> unit
  (** Idempotent; safe to call even if [finalize] was never called.
      Caller runs this from [Eio.Switch.on_release] or equivalent so
      crashes still hit it. *)
end
