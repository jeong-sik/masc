open Alcotest
open Masc

module Recovery = Server_atomic_orphan_recovery

let make_temp_base () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-fs-atomic-24083-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> ()
  | { st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let with_temp_base f =
  let base_path = make_temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> f base_path)
;;

let config base_path = Workspace.build_default_config base_path
let masc_root base_path = Workspace.masc_dir_from_base_path ~base_path

let write_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let touch path = write_file path ""

let test_name_matcher () =
  let yes value =
    check bool value true (Fs_compat.is_atomic_orphan_name value)
  in
  let no value =
    check bool value false (Fs_compat.is_atomic_orphan_name value)
  in
  List.iter yes [ ".atomic_abc.tmp"; ".atomic_946c84.tmp"; ".atomic_.tmp" ];
  List.iter
    no
    [ "atomic_abc.tmp"
    ; ".atomic_abc"
    ; "normal.json"
    ; "prefix_.atomic_abc.tmp"
    ]
;;

let test_catalog_is_closed_and_excludes_foreign_trees () =
  with_temp_base (fun base_path ->
    let catalog = Recovery.catalog (config base_path) in
    let paths = List.map (fun (entry : Recovery.catalog_entry) -> entry.path) catalog in
    let root = masc_root base_path in
    let contains name = List.mem (Filename.concat root name) paths in
    check bool "workspace root is catalogued" true (List.mem root paths);
    check bool "nested keeper root is catalogued" true (contains "keepers");
    check bool "operator root is catalogued" true (contains "operator");
    check bool "schedule root is catalogued" true (contains "schedules");
    check bool "trace root is catalogued" true (contains "traces");
    check bool "playground is excluded" false (contains "playground");
    check bool "repository clones are excluded" false (contains "repos");
    check bool "connector state is excluded" false (contains "connectors"))
;;

let test_root_entries_delete_and_preserve () =
  with_temp_base (fun base_path ->
    let root = masc_root base_path in
    Fs_compat.mkdir_p root;
    let empty = Filename.concat root ".atomic_empty.tmp" in
    let data = Filename.concat root ".atomic_data.tmp" in
    touch empty;
    write_file data "forensic-payload";
    let outcomes = Recovery.recover_blocking ~config:(config base_path) in
    let summary = Recovery.summarize outcomes in
    check int "one empty orphan deleted" 1 summary.deleted;
    check int "one data orphan preserved" 1 summary.preserved;
    check int "no recovery failures" 0 summary.failed;
    check bool "empty source removed" false (Sys.file_exists empty);
    check bool "data source removed" false (Sys.file_exists data);
    check int
      "recovery mirror is not rescanned"
      0
      (Recovery.recover_blocking ~config:(config base_path) |> List.length);
    match
      List.find_opt
        (function Recovery.Preserved _ -> true | _ -> false)
        outcomes
    with
    | Some (Recovery.Preserved { provenance; recovered_path; _ }) ->
      check bool "root provenance" true
        (provenance.root_kind = Recovery.Workspace_root);
      check string "relative provenance" ".atomic_data.tmp" provenance.relative_path;
      check string "payload preserved" "forensic-payload" (read_file recovered_path);
      check bool "closed recovery bucket" true
        (String.starts_with
           ~prefix:
             (Filename.concat root ".recovered/atomic-orphans/workspace-root")
           recovered_path)
    | Some _ | None -> fail "missing preserved root outcome")
;;

let test_nested_keeper_store_is_recovered_with_provenance () =
  with_temp_base (fun base_path ->
    let keeper_dir =
      Filename.concat (masc_root base_path) "keepers/alpha/memory/deep"
    in
    let orphan = Filename.concat keeper_dir ".atomic_memory.tmp" in
    write_file orphan "keeper-memory";
    let outcomes = Recovery.recover_blocking ~config:(config base_path) in
    match outcomes with
    | [ Recovery.Preserved { provenance; recovered_path; _ } ] ->
      check bool "keeper root provenance" true
        (provenance.root_kind = Recovery.Keepers);
      check string
        "nested relative path"
        "alpha/memory/deep/.atomic_memory.tmp"
        provenance.relative_path;
      check string "nested payload preserved" "keeper-memory" (read_file recovered_path)
    | outcomes ->
      failf "expected one nested keeper preservation, got %d outcomes"
        (List.length outcomes))
;;

let test_foreign_trees_are_not_traversed () =
  with_temp_base (fun base_path ->
    let root = masc_root base_path in
    let foreign_paths =
      [ Filename.concat root "playground/alpha/repos/project/.atomic_user.tmp"
      ; Filename.concat root "repos/project/.atomic_repo.tmp"
      ; Filename.concat base_path "workspace/.atomic_workspace.tmp"
      ; Filename.concat base_path ".gate/runtime/slack/.atomic_connector.tmp"
      ]
    in
    List.iter (fun path -> write_file path "foreign") foreign_paths;
    let outcomes = Recovery.recover_blocking ~config:(config base_path) in
    check int "foreign trees produce no recovery outcomes" 0 (List.length outcomes);
    List.iter
      (fun path -> check bool ("untouched " ^ path) true (Sys.file_exists path))
      foreign_paths)
;;

let test_symlinks_are_pending_and_never_followed () =
  with_temp_base (fun base_path ->
    let external_dir = Filename.concat base_path "external" in
    let external_orphan = Filename.concat external_dir ".atomic_external.tmp" in
    write_file external_orphan "external";
    let keeper_root = Filename.concat (masc_root base_path) "keepers/alpha" in
    Fs_compat.mkdir_p keeper_root;
    let directory_link = Filename.concat keeper_root "linked-tree" in
    Unix.symlink external_dir directory_link;
    let orphan_link = Filename.concat keeper_root ".atomic_link.tmp" in
    Unix.symlink external_orphan orphan_link;
    let outcomes = Recovery.recover_blocking ~config:(config base_path) in
    check bool "external orphan untouched" true (Sys.file_exists external_orphan);
    check bool "directory symlink untouched" true
      ((Unix.lstat directory_link).st_kind = Unix.S_LNK);
    match outcomes with
    | [ Recovery.Pending { provenance; reason = Recovery.Symlink } ] ->
      check string "symlink provenance" "alpha/.atomic_link.tmp"
        provenance.relative_path
    | outcomes ->
      failf "expected one pending symlink, got %d outcomes" (List.length outcomes))
;;

let test_catalog_root_symlink_is_pending_and_never_followed () =
  with_temp_base (fun base_path ->
    let root = masc_root base_path in
    let external_dir = Filename.concat base_path "external-keepers" in
    let external_orphan = Filename.concat external_dir ".atomic_external.tmp" in
    write_file external_orphan "external";
    Fs_compat.mkdir_p root;
    let keepers_link = Filename.concat root "keepers" in
    Unix.symlink external_dir keepers_link;
    let outcomes = Recovery.recover_blocking ~config:(config base_path) in
    check bool "external orphan untouched" true (Sys.file_exists external_orphan);
    match outcomes with
    | [ Recovery.Pending { provenance; reason = Recovery.Symlink } ] ->
      check bool
        "catalog root provenance"
        true
        (provenance.root_kind = Recovery.Keepers);
      check string "catalog root relative provenance" "." provenance.relative_path
    | outcomes ->
      failf
        "expected one pending catalog-root symlink, got %d outcomes"
        (List.length outcomes))
;;

let test_invalid_recovery_root_is_typed_failure () =
  with_temp_base (fun base_path ->
    let root = masc_root base_path in
    let keeper_orphan = Filename.concat root "keepers/alpha/.atomic_data.tmp" in
    write_file keeper_orphan "data";
    let external_dir = Filename.concat base_path "external-recovery" in
    Fs_compat.mkdir_p external_dir;
    Fs_compat.mkdir_p root;
    Unix.symlink external_dir (Filename.concat root ".recovered");
    let outcomes = Recovery.recover_blocking ~config:(config base_path) in
    check bool "source remains after recovery-root failure" true
      (Sys.file_exists keeper_orphan);
    check int "external target remains empty" 0
      (Array.length (Sys.readdir external_dir));
    match outcomes with
    | [ Recovery.Failed { provenance; stage; mutation_effect; _ } ] ->
      check bool "failure keeps keeper provenance" true
        (provenance.root_kind = Recovery.Keepers);
      check bool "typed recovery-directory stage" true
        (stage = Recovery.Create_recovery_directory);
      check bool "source unchanged effect" true
        (mutation_effect = Recovery.Source_unchanged)
    | outcomes ->
      failf "expected one typed failure, got %d outcomes" (List.length outcomes))
;;

let test_eio_boundary () =
  with_temp_base (fun base_path ->
    let orphan = Filename.concat (masc_root base_path) ".atomic_eio.tmp" in
    touch orphan;
    Eio_main.run @@ fun _env ->
    let outcomes = Recovery.recover_eio ~config:(config base_path) in
    let summary = Recovery.summarize outcomes in
    check int "Eio recovery deletes one orphan" 1 summary.deleted)
;;

let () =
  run
    "fs-atomic-orphan-recovery"
    [ "matcher", [ test_case "writer name SSOT" `Quick test_name_matcher ]
    ; ( "catalog"
      , [ test_case
            "closed roots exclude foreign trees"
            `Quick
            test_catalog_is_closed_and_excludes_foreign_trees
        ] )
    ; ( "recovery"
      , [ test_case "root delete and preserve" `Quick test_root_entries_delete_and_preserve
        ; test_case
            "nested keeper provenance"
            `Quick
            test_nested_keeper_store_is_recovered_with_provenance
        ; test_case
            "foreign trees untouched"
            `Quick
            test_foreign_trees_are_not_traversed
        ; test_case
            "symlink non-interference"
            `Quick
            test_symlinks_are_pending_and_never_followed
        ; test_case
            "catalog-root symlink non-interference"
            `Quick
            test_catalog_root_symlink_is_pending_and_never_followed
        ; test_case
            "typed recovery failure"
            `Quick
            test_invalid_recovery_root_is_typed_failure
        ; test_case "Eio boundary" `Quick test_eio_boundary
        ] )
    ]
;;
