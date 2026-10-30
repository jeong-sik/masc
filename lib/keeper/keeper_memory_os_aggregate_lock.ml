let suffix = ".memory-os-aggregate"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let with_lock ?clock ~keepers_dir ~keeper_id f =
  Fs_compat.mkdir_p keepers_dir;
  File_lock_eio.with_lock
    ?clock
    (path_for_keepers_dir ~keepers_dir ~keeper_id)
    f
;;
