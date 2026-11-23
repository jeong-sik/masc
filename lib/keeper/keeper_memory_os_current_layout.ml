let suffix = ".memory-current.json"

let merge_basis = Keeper_memory_os_support_core.merge_basis

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;
