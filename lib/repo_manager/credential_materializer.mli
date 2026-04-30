(** Decide on-disk materialisation status for a credential record.
    See {!Credential_materializer} module documentation for the full
    state-derivation table.  RFC-0019 §4.4. *)

open Repo_manager_types

val verify_state : gh_config_dir:string -> credential_state
(** [verify_state ~gh_config_dir] inspects [gh_config_dir] without
    mutating any credential record and returns the appropriate
    [credential_state].  Empty / missing path collapses to
    [Unmaterialized]; existing-but-invalid bundles surface as [Stale]. *)

val ensure : credential -> credential
(** [ensure cred] returns a new credential record whose [state] field
    reflects the current on-disk verify outcome.  All other fields are
    preserved.  Idempotent. *)

val path_safe : string -> (unit, string) result
(** [path_safe path] returns [Ok ()] if [path] contains no [..] segment,
    [Error _] otherwise.  Guards [gh_config_dir] supplied via untrusted
    inputs (e.g. HTTP POST bodies) from escaping into arbitrary host
    directories.  RFC-0019 §8 R3. *)

val provision_via_with_token :
  gh_config_dir:string ->
  token:string ->
  (credential_state, string) result
(** [provision_via_with_token ~gh_config_dir ~token] runs
    [gh auth login --with-token] against [gh_config_dir], piping [token]
    via stdin.  RFC-0019 §4.4 + Risk #2 (token leakage):

    - [token] is never logged, returned, captured, or echoed.
    - [stdout]/[stderr] of the subprocess are redirected to [/dev/null]
      so [gh] cannot leak a malformed-token diagnostic.
    - [gh_config_dir] is rejected if it contains a [..] segment.
    - On success, the function returns [Ok (verify_state ...)]; the
      caller persists the credential record with that state via
      {!Credential_store.add} or [Credential_store.update_state]. *)
