let dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "gate"
;;

let mode ~base_path = Filename.concat (dir ~base_path) "mode.json"
let pending ~base_path = Filename.concat (dir ~base_path) "pending.json"

let pending_v2_archive ~base_path ~source_hash =
  pending ~base_path ^ ".v2-" ^ source_hash ^ ".archive"
;;
