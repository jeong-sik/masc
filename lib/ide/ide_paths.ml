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
  | No_canonical_url
  | Unmatched
  | Base_unresolved
  | Legacy_default

let partition_kind = function
  | By_url _ -> "by_url"
  | No_canonical_url -> "no_canonical_url"
  | Unmatched -> "unmatched"
  | Base_unresolved -> "base_unresolved"
  | Legacy_default -> "legacy_default"
;;

let partition_is_orphan = function
  | By_url _ -> false
  | No_canonical_url | Unmatched | Base_unresolved | Legacy_default -> true
;;

let partition_store_dir ~base_dir = function
  | By_url slug -> by_url_path ~base_dir ~canonical_url:slug
  (* Layout invariant: all non-By_url partitions share [_orphan/] so disk layout
     is unchanged, but the typed variant carries the reason (RFC-0128 §4.2 +
     IDE Observation Plane v2 §7). The 5-arm exhaustive match forces this site
     to be revisited whenever a new variant is added (anti-pattern #4). *)
  | No_canonical_url | Unmatched | Base_unresolved | Legacy_default ->
    orphan_path ~base_dir
;;

let canonical_url_of_remote = Agent_observation.canonical_url_of_remote
