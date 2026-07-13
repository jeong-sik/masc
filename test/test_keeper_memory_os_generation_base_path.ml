open Alcotest

module Io = Masc.Keeper_memory_os_io

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  path
;;

let cleanup_dir root =
  let rec remove path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | Sys_error _ | Unix.Unix_error _ -> ()
;;

let test_explicit_base_paths_isolate_generation_counters () =
  let ambient = temp_dir "memory-os-generation-ambient-" in
  let workspace_a = temp_dir "memory-os-generation-a-" in
  let workspace_b = temp_dir "memory-os-generation-b-" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir ambient;
      cleanup_dir workspace_a;
      cleanup_dir workspace_b)
    (fun () ->
       let keepers_a =
         Config_dir_resolver.keepers_dir_for_base_path ~base_path:workspace_a
       in
       let keepers_b =
         Config_dir_resolver.keepers_dir_for_base_path ~base_path:workspace_b
       in
       let keeper_id = "base-path-generation-keeper" in
       let trace_id = "base-path-generation-trace" in
       Io.For_testing.with_keepers_dir ambient (fun () ->
         check int
           "workspace A first reservation"
           0
           (Io.next_generation_for_base_path ~base_path:workspace_a ~keeper_id ~trace_id);
         check int
           "workspace A advances independently"
           1
           (Io.next_generation_for_base_path ~base_path:workspace_a ~keeper_id ~trace_id);
         check int
           "workspace B starts from its own counter"
           0
           (Io.next_generation_for_base_path ~base_path:workspace_b ~keeper_id ~trace_id));
       let episode_dir keepers_dir =
         Filename.concat keepers_dir (Filename.concat keeper_id "episodes")
       in
       check bool "workspace A owns its episode counter" true
         (Sys.is_directory (episode_dir keepers_a));
       check bool "workspace B owns its episode counter" true
         (Sys.is_directory (episode_dir keepers_b));
       check bool "ambient override remains untouched" false
         (Sys.file_exists (episode_dir ambient)))
;;

let () =
  run
    "Keeper Memory OS BasePath generation"
    [ ( "generation reservation"
      , [ test_case
            "explicit BasePaths isolate counters from ambient storage"
            `Quick
            test_explicit_base_paths_isolate_generation_counters
        ] )
    ]
;;
