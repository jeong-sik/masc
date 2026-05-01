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

val sha256_prefix : string -> string
(** [sha256_prefix s] returns the first 12 hex characters of the SHA-256
    digest of [s].  Used as a fingerprint for F-1 token-boundary
    comparison; the prefix is short enough to surface in logs/audit
    without redaction concerns yet long enough (48 bits) to make
    accidental collisions astronomically unlikely.  RFC-0019 §3.2 P1. *)

val compute_token_sha256_prefix : gh_config_dir:string -> string option
(** [compute_token_sha256_prefix ~gh_config_dir] reads the
    [oauth_token:] line from [<gh_config_dir>/hosts.yml] and returns
    its [sha256_prefix].  Returns [None] when the file or token line
    is absent.  The token value never escapes this function. *)

type f1_gate_outcome =
  | F1_skipped of string
  | F1_distinct
  | F1_shared_with_operator

val f1_gate_check :
  credential_id:string ->
  gh_config_dir:string ->
  f1_gate_outcome
(** [f1_gate_check ~credential_id ~gh_config_dir] compares the bundle's
    [oauth_token] fingerprint against the operator ambient
    [gh auth token].  Emits
    [keeper_credential_provider_gate_warned_total\{credential_id,scope=shared_with_operator\}]
    Prometheus counter when they match.  RFC-0019 PR-C, permissive
    mode: the function never refuses materialisation; it only counts
    and surfaces the outcome. *)

val relabel_hosts_yml :
  gh_config_dir:string -> identity_label:string -> unit
(** [relabel_hosts_yml ~gh_config_dir ~identity_label] rewrites the
    [user:] line in [<gh_config_dir>/hosts.yml] to [identity_label]
    after [gh auth login --with-token] overwrites it with the real
    GitHub login.  Best-effort, idempotent, no error surfaces — the
    relabel is cosmetic per RFC-0019 P1.  RFC-0008 F-2. *)

val provision_via_with_token :
  ?credential_id:string ->
  ?identity_label:string ->
  gh_config_dir:string ->
  token:string ->
  unit ->
  (credential_state, string) result
(** [provision_via_with_token ?credential_id ?identity_label
    ~gh_config_dir ~token ()] runs [gh auth login --with-token] against
    [gh_config_dir], piping [token] via stdin.  RFC-0019 §4.4 + Risk #2
    (token leakage):

    - [token] is never logged, returned, captured, or echoed.
    - [stdout]/[stderr] of the subprocess are redirected to [/dev/null]
      so [gh] cannot leak a malformed-token diagnostic.
    - [gh_config_dir] is rejected if it contains a [..] segment.
    - [gh] receives a bundle-local environment that scrubs ambient
      GH_TOKEN/GITHUB_TOKEN values and forces [--insecure-storage], so
      the resulting [hosts.yml] is mounted with the keeper bundle
      instead of being hidden in the operator's host keyring.
    - On success the function: (1) calls {!relabel_hosts_yml} when
      [identity_label] is supplied (RFC-0008 F-2 close), (2) calls
      {!f1_gate_check} when [credential_id] is supplied (RFC-0019 PR-C
      F-1 gate, permissive), (3) returns [Ok (verify_state ...)]; the
      caller persists the credential record with that state via
      {!Credential_store.add} or [Credential_store.update_state]. *)
