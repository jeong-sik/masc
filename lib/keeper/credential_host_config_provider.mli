(** Keeper GitHub credential provider.

    Resolves a keeper through [keeper_repo_mappings.toml] and the credential
    store.  Missing or unreadable mappings fail closed; keeper TOML no longer
    participates in repo credential selection.  It mounts only files from the selected
    credential bundle read-only into the dispatch container and composes
    container-local GH/Git config paths.  Operator ambient credentials
    ([GH_TOKEN], [GITHUB_TOKEN], [~/.config/gh], [~/.ssh], keychain probes) are
    outside this contract.

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
    ?ssh_key_container:string -> unit -> (string * string) list

  val mount_if_present :
    host:string -> container:string -> Credential_provider.ro_mount list

  val compose_ro_mounts_result :
    ?keeper_name:string ->
    Credential_bundle.keeper_binding ->
    (Credential_provider.ro_mount list, string) result
end
