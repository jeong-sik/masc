open Alcotest

module Workspace = Masc.Workspace
module Boundaries = Masc.Keeper_turn_boundaries
module Progress = Masc.Keeper_librarian_progress
module Meta = Masc.Keeper_meta_store
module Turn = Masc.Keeper_agent_run_turn_helpers

let keeper_name = "scope-keeper"

let config_in_cluster config cluster_name =
  { config with
    Workspace.backend_config = { config.Workspace.backend_config with cluster_name }
  }
;;

let with_clusters f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun _env ->
  let base_path = Filename.temp_dir "librarian-cluster-stores-" "" in
  Config_dir_resolver.reset ();
  Fun.protect ~finally:(fun () ->
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    let (_ : string) = Workspace.init config ~agent_name:None in
    f (config_in_cluster config "Scope/A") (config_in_cluster config "Scope/B"))
;;

let meta trace_id =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [ "name", `String keeper_name; "trace_id", `String trace_id ]) with
  | Ok meta -> meta
  | Error detail -> failf "fixture metadata: %s" detail
;;

let write_meta config trace_id =
  match Meta.replace_snapshot config (meta trace_id) with
  | Ok () -> ()
  | Error detail -> failf "write metadata: %s" detail
;;

let restart config trace_id =
  Turn.record_history_restart ~config ~keeper_name ~trace_id Turn.At_turn_start
;;

let store_boundary config trace_id =
  match Boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
    { recorded_at = 1.0; event = Boundaries.History_restarted { trace_id } } with
  | Ok () -> ()
  | Error error -> fail (Boundaries.append_error_to_string error)
;;

let read_boundaries config =
  match Boundaries.read
    ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name with
  | Ok lines -> List.map (fun (_, decoded) -> match decoded with
      | Ok record -> record.Boundaries.event
      | Error error -> fail (Boundaries.read_error_to_string error)) lines
  | Error detail -> fail detail
;;

let value trace_id : Progress.t =
  { position = { trace_id; end_atom = 1; last_atom_digest = "fixture-atom" }
  ; boundary_lines_seen = 1
  }
;;

let write_progress config trace_id =
  match Progress.write ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name (value trace_id) with
  | Ok () -> ()
  | Error error -> fail (Progress.write_error_to_string error)
;;

let read_progress config =
  match Progress.read ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name with
  | Ok value -> value
  | Error error -> fail (Progress.read_error_to_string error)
;;

let test_same_name_clusters_do_not_share_positions () =
  with_clusters @@ fun a b ->
  check string "the clusters share operator config"
    (Config_dir_resolver.keepers_dir_for_base_path ~base_path:a.base_path)
    (Config_dir_resolver.keepers_dir_for_base_path ~base_path:b.base_path);
  restart a "trace-a";
  restart b "trace-b";
  check bool "A reads only its restart" true
    (read_boundaries a = [ Boundaries.History_restarted { trace_id = "trace-a" } ]);
  check bool "B reads only its restart" true
    (read_boundaries b = [ Boundaries.History_restarted { trace_id = "trace-b" } ]);
  write_progress a "trace-a";
  write_progress b "trace-b";
  check bool "A retains its progress after B writes" true
    (read_progress a = Some (value "trace-a"));
  check bool "B has its own progress" true
    (read_progress b = Some (value "trace-b"))
;;

let test_progress_is_not_a_metadata_record () =
  with_clusters @@ fun a _b ->
  write_meta a "trace-a";
  write_progress a "trace-a";
  let names = match Meta.persisted_keeper_names_result a with
    | Ok names -> names
    | Error detail -> fail detail in
  check (list string) "progress introduces no fake Keeper" [ keeper_name ] names
;;

let test_purge_preserves_other_cluster () =
  with_clusters @@ fun a b ->
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  store_boundary a "trace-a";
  store_boundary b "trace-b";
  write_progress a "trace-a";
  write_progress b "trace-b";
  let paths config =
    let keepers_dir = Workspace.keepers_runtime_dir config in
    [ Boundaries.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name
    ; Progress.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name ] in
  let b_before = List.map (fun path -> path, In_channel.with_open_bin path In_channel.input_all)
    (paths b) in
  (match Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
    a ~keeper_name ~remove_configuration:false
    { Masc.Keeper_shutdown_types.requested_name = keeper_name } with
   | Ok () -> ()
   | Error detail -> failf "artifact purge: %s" detail);
  List.iter (fun path -> check bool "A runtime artifact removed" false (Sys.file_exists path))
    (paths a);
  List.iter (fun (path, bytes) -> check string "B artifact bytes unchanged" bytes
    (In_channel.with_open_bin path In_channel.input_all)) b_before;
  check bool "B progress still decodes" true (read_progress b = Some (value "trace-b"));
  check bool "B boundary still decodes" true
    (read_boundaries b = [ Boundaries.History_restarted { trace_id = "trace-b" } ])
;;

let test_reads_do_not_create_runtime_directories () =
  with_clusters @@ fun a _b ->
  let root = Workspace.keepers_runtime_dir a in
  check bool "runtime root absent before read" false (Sys.file_exists root);
  check bool "no boundary yet" true (read_boundaries a = []);
  check bool "no progress yet" true (read_progress a = None);
  check bool "runtime root absent after read" false (Sys.file_exists root)
;;

let () =
  run "Librarian runtime store scope"
    [ "clusters",
        [ test_case "same base and Keeper: separate boundary and progress" `Quick
            test_same_name_clusters_do_not_share_positions
        ; test_case "progress is not Keeper metadata" `Quick
            test_progress_is_not_a_metadata_record
        ; test_case "purge A preserves B" `Quick test_purge_preserves_other_cluster
        ; test_case "reading absent stores creates no directories" `Quick
            test_reads_do_not_create_runtime_directories
        ]
    ]
