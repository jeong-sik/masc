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
  aliases : string list [@default []];
  default_branch : string;
  keepers : string list;
  status : repository_status;
  auto_sync : bool;
  sync_interval : int;
  created_at : int64;
  updated_at : int64;
}
[@@deriving yojson, show, eq]

type repository_scope =
  | All_repositories
  | Selected_repositories of repository_id list
[@@deriving yojson, show, eq]

type keeper_repo_mapping = {
  keeper_id : string;
  repository_ids : string list;
  repository_scope : repository_scope [@default Selected_repositories []];
}
[@@deriving yojson, show, eq]

val repository_scope_of_ids : repository_id list -> repository_scope
(** [repository_scope_of_ids repository_ids] parses the raw repository list
    from TOML/JSON into the closed access scope. *)

val make_keeper_repo_mapping :
  keeper_id:string -> repository_ids:repository_id list -> keeper_repo_mapping
(** [make_keeper_repo_mapping ~keeper_id ~repository_ids] preserves the raw
    IDs for serialization while storing the parsed access scope. *)

(** [is_toml_table v] is [true] iff [v] is [Otoml.TomlTable] or
    [Otoml.TomlInlineTable].  Shared by the on-disk config loaders so the
    12-constructor [Otoml.t] enumeration that satisfies warning 4 lives
    in one place. *)
val is_toml_table : Otoml.t -> bool
