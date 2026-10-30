(* The environment names the settings registry marks file-owned, one per line.
   test_file_owned_env_reads.py reads the list to look for direct reads of them
   in the source files. *)
let () = List.iter print_endline Keeper_runtime_setting_registry.file_owned_env_names
