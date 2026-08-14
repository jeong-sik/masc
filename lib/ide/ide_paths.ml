let store_subdir = ".masc-ide"
let store_path ~base_dir = Filename.concat base_dir store_subdir
let by_url_subdir = "by-url"

(* RFC-0378 §5.2: the store holds addressed code facts only, so a store
   directory is named by the codebase slug directly — the same value the
   scope, the co-view, and the address mint carry. *)
let code_store_dir ~base_dir ~codebase =
  Filename.concat (Filename.concat (store_path ~base_dir) by_url_subdir) codebase
;;

let canonical_url_of_remote = Agent_observation.canonical_url_of_remote
