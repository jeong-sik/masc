let store_subdir = ".masc-ide"

let store_path ~base_dir = Filename.concat base_dir store_subdir

let by_url_subdir = "by-url"
let orphan_subdir = "_orphan"

let by_url_path ~base_dir ~canonical_url =
  Filename.concat (Filename.concat (store_path ~base_dir) by_url_subdir) canonical_url
;;

let orphan_path ~base_dir = Filename.concat (store_path ~base_dir) orphan_subdir

type partition =
  Agent_observation.codebase_partition =
  | By_url of string
  | Orphan

let partition_store_dir ~base_dir = function
  | By_url slug -> by_url_path ~base_dir ~canonical_url:slug
  | Orphan -> orphan_path ~base_dir
;;

let canonical_url_of_remote = Agent_observation.canonical_url_of_remote
