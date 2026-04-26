(** Option A credential provider — host bundle mounted read-only
    (RFC-0008 PR-1).

    Composes the binding that {!Keeper_shell_docker} previously built
    inline (lines 271-329 pre-extraction): RO mounts of the host
    [gh] config dir + [.gitconfig] + [.ssh] dir, env vars projecting
    those mounts under {!cred_root} inside the container, and the
    canonical non-interactive git env from {!Env_git_noninteractive}.

    [finalize] and [tear_down] are noops here — the RO mount has
    nothing to relabel and its lifetime is the docker [run].  PR-3's
    [In_container_login_provider] will use the same trait surface
    with a real [finalize] (rewrite [hosts.yml:user] inside
    container) and [bootstrap] argv. *)

include Credential_provider.S

val cred_root : string
(** [/tmp/keeper-creds] — in-container path under which credentials
    are projected.  Exposed so callers that compose paths relative to
    it (currently only the [SSH_AUTH_SOCK] mount, which depends on
    the host SSH agent and is therefore composed outside this trait)
    stay in sync with the [HOME=<cred_root>] env entry that the
    binding already carries. *)

(**/**)

(** Pure helpers exposed for white-box tests.  Not part of the stable
    API; do not call from production code. *)
module For_testing : sig
  val compose_env :
    git_author_name:string -> git_author_email:string ->
    (string * string) list

  val mount_if_present :
    host:string -> container:string -> Credential_provider.ro_mount list
end
