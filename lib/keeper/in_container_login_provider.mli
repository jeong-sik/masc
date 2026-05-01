(** Option B credential provider: bootstraps GitHub credentials inside
    the keeper sandbox container via [gh auth login --with-token].

    This provider is the RFC-0008 PR-3 implementation.  It is gated on
    PR-2 operational proof (every active keeper identity must have its
    own fine-grained PAT before this provider may be used in production).

    Lifecycle difference from {!Host_config_provider}:

    - [resolve] reads the keeper's bundle token, runs {!provider_gate},
      writes the token to a temporary host file that is mounted RO into
      the container, and returns a [binding] with [bootstrap] set to the
      [gh auth login --with-token] argv.  [ro_mounts] is populated only
      with the token-file entry (NOT the full host gh-config bundle — the
      container writes its own config via [gh]).

    - [finalize] rewrites [hosts.yml:user] inside the running container
      to [binding.identity], undoing the real-login-owner label that
      [gh auth login --with-token] writes.  Uses [docker exec].

    - [tear_down] deletes the temporary token file that [resolve] staged
      on the host (recorded in [binding.metadata["token_host_path"]]).

    [provider_gate] is the F-1 enforcement point: it refuses [resolve]
    with [Invalid_token] when the keeper's stored token SHA-256 prefix
    matches the operator ambient [gh auth token], i.e. when identity
    separation is cosmetic.  The check is best-effort on the operator
    side; the gate stays silent when [gh] is not installed. *)

include Credential_provider.S

(** F-1 gate: compare the SHA-256 prefix of the keeper's stored
    [oauth_token] against the operator ambient [gh auth token].
    Returns [Error _] when they match (sharing detected) or when the
    keeper bundle has no token at all.  Returns [Ok ()] when the
    prefixes differ or when the operator ambient token is unavailable
    (gate is permissive in that case). *)
val provider_gate :
  identity:string -> gh_config_dir:string -> (unit, string) result

(**/**)

module For_testing : sig
  val container_hosts_yml_path : string
  (** The in-container path of [hosts.yml] that [finalize] rewrites.
      Exposed so tests can assert the exact path without duplicating the
      constant. *)

  val read_token_from_hosts_yml : gh_config_dir:string -> string option
  (** Pure helper: extract the [oauth_token] scalar from a [hosts.yml]
      file.  Returns [None] when the file is absent or the key is
      missing.  Token value is the only output; callers must not log
      it. *)
end
