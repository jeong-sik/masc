open Fs_compat_internal

let replace_capability_file =
  Atomic_write.Capability_write_for_testing.replace_capability_file
;;

let create_capability_file_exclusive =
  Atomic_write.Capability_write_for_testing.create_capability_file_exclusive
;;

let sync_directory_capability =
  Atomic_write.Capability_write_for_testing.sync_directory_capability
;;
