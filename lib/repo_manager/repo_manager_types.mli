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

type keeper_repo_mapping = {
  keeper_id : string;
  repository_ids : string list;
}
[@@deriving yojson, show, eq]

(** [is_toml_table v] is [true] iff [v] is [Otoml.TomlTable] or
    [Otoml.TomlInlineTable].  Shared by the on-disk config loaders so the
    12-constructor [Otoml.t] enumeration that satisfies warning 4 lives
    in one place. *)
val is_toml_table : Otoml.t -> bool
