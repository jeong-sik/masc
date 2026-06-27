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

let repository_scope_of_ids repository_ids =
  if List.exists (String.equal "*") repository_ids then
    All_repositories
  else
    Selected_repositories repository_ids

let make_keeper_repo_mapping ~keeper_id ~repository_ids =
  {
    keeper_id;
    repository_ids;
    repository_scope = repository_scope_of_ids repository_ids;
  }

(* [Otoml.t] is a 3rd-party closed variant with 12 value constructors;
   the on-disk config loaders in this library only ever distinguish
   "table-shaped" (TomlTable / TomlInlineTable) from everything else.
   Enumerating the other 10 once here satisfies warning 4 and means an
   [otoml] version bump that adds a value constructor breaks exactly this
   site instead of several config loaders. *)
let is_toml_table : Otoml.t -> bool = function
  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> true
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ -> false
