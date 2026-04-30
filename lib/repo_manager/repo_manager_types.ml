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

type credential = {
  id : string;
  cred_type : credential_type;
  username : string;
  gh_config_dir : string option; [@default None]
  ssh_key_path : string option; [@default None]
  gpg_key_id : string option; [@default None]
}
[@@deriving yojson, show, eq]

type keeper_repo_mapping = {
  keeper_id : string;
  repository_ids : string list;
}
[@@deriving yojson, show, eq]
