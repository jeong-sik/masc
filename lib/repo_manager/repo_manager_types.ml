type repository_id = string
[@@deriving yojson, show, eq]

type repository_status =
  | Active
  | Paused
  | Cloning
  | Error of string
[@@deriving yojson, show, eq]

type repository = {
  id : repository_id;
  name : string;
  url : string;
  local_path : string;
  default_branch : string;
  credential_id : string;
  keepers : string list;
  status : repository_status;
  auto_sync : bool;
  sync_interval : int;
  created_at : int64;
  updated_at : int64;
}
[@@deriving yojson, show, eq]

type credential_type =
  | Github
  | Gitlab
  | Local
[@@deriving yojson, show, eq]

(** Materialisation status of a credential record.  Recorded by
    [Credential_materializer.ensure] when a credential is added or
    re-verified.  RFC-0019 §4.2.

    - [Unmaterialized]: registry knows about the credential but no usable
      bundle exists on disk yet.  Keeper resolve from this credential
      surfaces a clear remediation message rather than a silent 401.
    - [Materialized { last_verified_at }]: [gh auth status] succeeded
      against [gh_config_dir] at the timestamp.
    - [Stale { reason }]: a prior verify failed; consumers should treat
      the credential as unusable until a re-verify or re-provisioning. *)
type credential_state =
  | Unmaterialized
  | Materialized of { last_verified_at : int64 }
  | Stale of { reason : string }
[@@deriving yojson, show, eq]

type credential = {
  id : string;
  cred_type : credential_type;
  username : string;
  gh_config_dir : string option [@default None];
  ssh_key_path : string option [@default None];
  gpg_key_id : string option [@default None];
  (* RFC-0019 PR-B §4.2: credential state lifecycle.  Default keeps
     existing TOML files loadable — older records that were registered
     before this field existed are treated as [Unmaterialized] until
     [Credential_materializer.ensure] runs. *)
  state : credential_state [@default Unmaterialized];
  (* RFC-0019 §4.2: SHA-256 prefix of the bundle's oauth_token, if
     present.  Used by the F-1 gate (PR-C) to detect token-sharing
     between operator ambient credentials and a keeper bundle.  Stored
     as a *prefix* (12 hex chars), never the full token or full hash. *)
  token_sha256_prefix : string option [@default None];
}
[@@deriving yojson, show, eq]

type keeper_repo_mapping = {
  keeper_id : string;
  repository_ids : string list;
  github_credential_id : string option [@default None];
}
[@@deriving yojson, show, eq]
