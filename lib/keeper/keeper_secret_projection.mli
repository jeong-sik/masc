type t =
  { docker_args : string list
  ; cleanup : unit -> unit
  }

type github_app_token_minter =
  app_id:string ->
  installation_id:string ->
  pem:string ->
  now:int ->
  (string, string) result

type secret_scope =
  | Shared_secret
  | Keeper_secret

type secret_root_info =
  { root : string
  ; source : string
  ; scope : secret_scope
  }

val secret_scope_to_string : secret_scope -> string

val secret_root_info : base_path:string -> keeper_name:string -> secret_root_info

val secret_root : base_path:string -> keeper_name:string -> string

val secret_roots : base_path:string -> keeper_name:string -> secret_root_info list
(** Effective secret roots in projection order. The workspace-level
    [secrets/base] root is loaded first and [secrets/<keeper>] overlays it.
    For the literal [base] keeper, the root is returned once. Both roots are
    always resolved below the supplied BasePath; there is no environment
    override. *)

val local_env_for_keeper :
  ?mint_github_app_token:github_app_token_minter ->
  ?host_env:string array ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (string array option, string) result
(** Build the child-process environment for local keeper execution from
    [secrets/base/env] overlaid by [secrets/<keeper>/env]. The host
    environment is keeper-scrubbed and git/gh noninteractive defaults are
    injected even when both secret roots are absent; a missing root only means
    there are no env/file overlays from that scope. When present, secret files
    are validated and env entries are overlaid without writing temp files. If
    the effective env provides [GH_TOKEN] or [GITHUB_TOKEN] and does not
    provide [GIT_CONFIG_GLOBAL], local execution writes a per-keeper gitconfig
    below the BasePath-owned managed HOME that points git-over-HTTPS at
    [gh auth git-credential]. If the effective env configures GitHub App
    issuance via [MASC_GITHUB_APP_ID]/[MASC_GITHUB_APP_INSTALLATION_ID],
    missing config, unreadable PEM material, or mint failure is returned as an
    error instead of falling back to a broader static token. Local execution
    always creates a Keeper-specific managed HOME and XDG/GitHub config tree
    below BasePath with mode [0700], rejects projected overrides of those
    boundary variables, and never inherits the operator's HOME/XDG config.
    This credential boundary does not provide filesystem namespace isolation.
    [?mint_github_app_token] defaults to the production GitHub App token
    issuer and is injectable for deterministic projection tests. *)

val docker_args_for_keeper :
  ?mint_github_app_token:github_app_token_minter ->
  base_path:string ->
  keeper_name:string ->
  container_name:string ->
  unit ->
  (t, string) result
(** Build Docker secret projection arguments. GitHub App private-key PEM files
    are projection-layer-only material: they may be read to mint the
    installation token, but are not mounted into keeper containers. *)

val secret_scope_of_string : string -> secret_scope option

val set_env_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  name:string ->
  value:string ->
  (unit, string) result
(** Persist one projected env secret under [secrets/base/env] or
    [secrets/<keeper>/env]. The value is validated with the same single-line
    rules used by local and docker projection. *)

val delete_env_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  name:string ->
  (unit, string) result
(** Remove one projected env secret. Missing files are treated as a no-op;
    symlinks and non-regular entries are rejected. *)

val set_file_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  container_path:string ->
  value:string ->
  (unit, string) result
(** Persist one projected file secret under [secrets/base/files] or
    [secrets/<keeper>/files]. [container_path] must be an absolute container
    path; traversal components and symlink targets are rejected. *)

val delete_file_entry :
  base_path:string ->
  keeper_name:string ->
  scope:secret_scope ->
  container_path:string ->
  (unit, string) result
(** Remove one projected file secret. Missing files are treated as a no-op;
    symlinks and non-regular entries are rejected. *)

val dashboard_status_json :
  base_path:string -> keeper_name:string -> Yojson.Safe.t
(** Redacted effective projection with explicit provenance. [env_entries]
    reports each effective name and its [shared | keeper] scope. [file_entries]
    reports the effective source scope plus whether the file is a Docker
    read-only mount or control-plane-only material. Secret values are never
    returned. *)
