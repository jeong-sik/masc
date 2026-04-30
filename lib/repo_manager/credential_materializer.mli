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
