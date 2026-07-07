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

type secret_root_info =
  { root : string
  ; source : string
  }

type secret_scope =
  | Shared_secret
  | Keeper_secret

val secret_root_info : base_path:string -> keeper_name:string -> secret_root_info

val secret_root : base_path:string -> keeper_name:string -> string

val secret_roots : base_path:string -> keeper_name:string -> secret_root_info list
(** Effective secret roots in projection order. The workspace-level
    [secrets/base] root is loaded first and [secrets/<keeper>] overlays it.
    For the literal [base] keeper, the root is returned once. *)

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
    under the keeper playground that points git-over-HTTPS at
    [gh auth git-credential]. If the effective env configures GitHub App
    issuance via [MASC_GITHUB_APP_ID]/[MASC_GITHUB_APP_INSTALLATION_ID],
    missing config, unreadable PEM material, or mint failure is returned as an
    error instead of falling back to a broader static token. If the keeper does
    not supply [GH_CONFIG_DIR], local execution points [gh] at an empty system
    config directory when available to avoid ambient host config fallback.
    [?mint_github_app_token] defaults to the production GitHub App token
    issuer and is injectable for deterministic projection tests. *)

val docker_args_for_keeper :
  ?mint_github_app_token:github_app_token_minter ->
  base_path:string ->
  keeper_name:string ->
  container_name:string ->
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
