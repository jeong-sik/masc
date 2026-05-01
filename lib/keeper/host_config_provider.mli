(** Keeper GitHub credential provider.

    Resolves the keeper's explicit [github_identity] bundle, or the
    MASC-owned [root] bundle when the keeper has no identity.  It mounts
    only files from that selected bundle read-only into the dispatch
    container and composes container-local GH/Git environment variables.
    Operator ambient credentials ([GH_TOKEN], [GITHUB_TOKEN],
    [~/.config/gh], [~/.ssh], keychain probes) are outside this contract.

    [finalize] and [tear_down] are noops here — the RO mount lifetime is
    the docker [run]. *)

include Credential_provider.S

val cred_root : string
(** [/tmp/keeper-creds] — in-container path under which credentials
    are projected.  Exposed so callers that compose paths relative to
    it stay in sync with the [HOME=<cred_root>] env entry that the
    binding carries. *)

(**/**)

(** Pure helpers exposed for white-box tests.  Not part of the stable
    API; do not call from production code. *)
module For_testing : sig
  val compose_env :
    ?ssh_key_container:string ->
    git_author_name:string -> git_author_email:string ->
    unit -> (string * string) list

  val mount_if_present :
    host:string -> container:string -> Credential_provider.ro_mount list
end
