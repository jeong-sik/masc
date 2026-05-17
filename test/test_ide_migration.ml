(** RFC-0128 §5 Phase 3 integration tests for [Ide_migration].

    Each case builds a temp base_path with .masc/config/repositories.toml,
    seeds the Legacy flat .masc-ide/{annotations,regions}.jsonl, runs
    the migration, and asserts the partition split + idempotency. *)

open Alcotest
open Repo_manager_types

module Types = Ide_annotation_types
module Mig = Ide_migration

let () = Random.self_init ()

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base f =
  let path = Filename.temp_file "rfc-0128-mig" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let rec mkdir_p path =
  if path = "" || path = "/" || (Sys.file_exists path && Sys.is_directory path)
  then ()
  else (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let register_repo ~base_path ~id ~url ~local_path =
  mkdir_p local_path;
  let repo =
    { id
    ; name = id
    ; url
    ; local_path
    ; aliases = []
    ; default_branch = "main"
    ; credential_id = "default"
    ; keepers = []
    ; status = Active
    ; auto_sync = false
    ; sync_interval = 0
    ; created_at = Int64.zero
    ; updated_at = Int64.zero
    }
  in
  match Repo_store.load_all ~base_path with
  | Ok existing ->
    (match Repo_store.save_all ~base_path (existing @ [ repo ]) with
     | Ok () -> ()
     | Error msg -> failf "save_all: %s" msg)
  | Error msg -> failf "load_all: %s" msg
;;

let init_empty_store base_path =
  let cfg_dir = Filename.concat base_path ".masc/config" in
  mkdir_p cfg_dir;
  match Repo_store.save_all ~base_path [] with
  | Ok () -> ()
  | Error msg -> failf "init_empty_store: %s" msg
;;

let seed_legacy_annotation ~base_path ~id ~keeper_id ~file_path ~content =
  let dir = Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Legacy in
  mkdir_p dir;
  let path = Filename.concat dir "annotations.jsonl" in
  let now = 1L in
  let json =
    Types.annotation_to_json
      { id
      ; file_path
      ; line_start = 1
      ; line_end = 3
      ; keeper_id
      ; kind = Types.Comment
      ; content
      ; goal_id = None
      ; task_id = None
      ; board_post_id = None
      ; comment_id = None
      ; pr_id = None
      ; git_ref = None
      ; log_id = None
      ; session_id = None
      ; operation_id = None
      ; worker_run_id = None
      ; created_at_ms = now
      ; updated_at_ms = now
      }
  in
  Fs_compat.append_jsonl path json
;;

let seed_legacy_region ~base_path ~keeper_id ~file_path =
  let dir = Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Legacy in
  mkdir_p dir;
  let path = Filename.concat dir "regions.jsonl" in
  let json =
    Types.region_to_json
      { keeper_id
      ; file_path
      ; line_start = 1
      ; line_end = 5
      ; source = Types.Tool_call { tool_name = "write_file"; turn = 0 }
      ; timestamp_ms = 1L
      }
  in
  Fs_compat.append_jsonl path json
;;

let count_lines path =
  if not (Sys.file_exists path) then 0
  else (
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let n = ref 0 in
        try
          while true do
            ignore (input_line ic);
            incr n
          done;
          !n
        with End_of_file -> !n))
;;

let test_routes_to_by_url_when_repo_known () =
  with_temp_base (fun base_path ->
    init_empty_store base_path;
    let repo_root = Filename.concat base_path "workspace/repo" in
    register_repo
      ~base_path
      ~id:"sandbox"
      ~url:"https://github.com/owner/repo"
      ~local_path:repo_root;
    let abs_file = Filename.concat repo_root "lib/foo.ml" in
    seed_legacy_annotation
      ~base_path
      ~id:"ann-1"
      ~keeper_id:"sangsu"
      ~file_path:abs_file
      ~content:"hello";
    seed_legacy_region ~base_path ~keeper_id:"sangsu" ~file_path:abs_file;
    let report =
      Mig.migrate_flat_to_partitioned
        ~base_path
        ~delete_legacy_after:false
        ()
    in
    check int "annotations_total" 1 report.annotations_total;
    check int "annotations_to_by_url" 1 report.annotations_to_by_url;
    check int "annotations_to_orphan" 0 report.annotations_to_orphan;
    check int "regions_total" 1 report.regions_total;
    check int "regions_to_by_url" 1 report.regions_to_by_url;
    check int "regions_to_orphan" 0 report.regions_to_orphan;
    let slug = "github.com_owner_repo" in
    let by_url_ann =
      Filename.concat
        (Ide_paths.partition_store_dir
           ~base_dir:base_path
           (Ide_paths.By_url slug))
        "annotations.jsonl"
    in
    let by_url_reg =
      Filename.concat
        (Ide_paths.partition_store_dir
           ~base_dir:base_path
           (Ide_paths.By_url slug))
        "regions.jsonl"
    in
    check int "by-url annotations.jsonl has 1 line" 1 (count_lines by_url_ann);
    check int "by-url regions.jsonl has 1 line" 1 (count_lines by_url_reg))
;;

let test_routes_to_orphan_when_unregistered () =
  with_temp_base (fun base_path ->
    init_empty_store base_path;
    (* Annotation path is under no registered repo. *)
    seed_legacy_annotation
      ~base_path
      ~id:"orphan-1"
      ~keeper_id:"sangsu"
      ~file_path:"/tmp/nowhere/foo.ml"
      ~content:"adrift";
    let report = Mig.migrate_flat_to_partitioned ~base_path () in
    check int "annotations_to_orphan" 1 report.annotations_to_orphan;
    check int "annotations_to_by_url" 0 report.annotations_to_by_url;
    let orphan_ann =
      Filename.concat
        (Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Orphan)
        "annotations.jsonl"
    in
    check int "orphan annotations has 1 line" 1 (count_lines orphan_ann))
;;

let test_dry_run_writes_nothing () =
  with_temp_base (fun base_path ->
    init_empty_store base_path;
    let repo_root = Filename.concat base_path "workspace/repo" in
    register_repo
      ~base_path
      ~id:"sandbox"
      ~url:"https://github.com/owner/repo"
      ~local_path:repo_root;
    seed_legacy_annotation
      ~base_path
      ~id:"ann-dr"
      ~keeper_id:"sangsu"
      ~file_path:(Filename.concat repo_root "lib/foo.ml")
      ~content:"dry";
    let report =
      Mig.migrate_flat_to_partitioned ~base_path ~dry_run:true ()
    in
    check int "report counts records" 1 report.annotations_total;
    check int "report decides bucket" 1 report.annotations_to_by_url;
    (* Dry-run did not write to by-url. *)
    let slug = "github.com_owner_repo" in
    let by_url_ann =
      Filename.concat
        (Ide_paths.partition_store_dir
           ~base_dir:base_path
           (Ide_paths.By_url slug))
        "annotations.jsonl"
    in
    check bool "by-url file absent after dry-run" false (Sys.file_exists by_url_ann);
    (* Legacy intact. *)
    let legacy_ann =
      Filename.concat
        (Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Legacy)
        "annotations.jsonl"
    in
    check int "legacy intact" 1 (count_lines legacy_ann))
;;

let test_idempotency_second_run_is_noop () =
  with_temp_base (fun base_path ->
    init_empty_store base_path;
    let repo_root = Filename.concat base_path "workspace/repo" in
    register_repo
      ~base_path
      ~id:"sandbox"
      ~url:"https://github.com/owner/repo"
      ~local_path:repo_root;
    seed_legacy_annotation
      ~base_path
      ~id:"ann-idem"
      ~keeper_id:"sangsu"
      ~file_path:(Filename.concat repo_root "lib/foo.ml")
      ~content:"idem";
    let first =
      Mig.migrate_flat_to_partitioned
        ~base_path
        ~delete_legacy_after:true
        ()
    in
    check int "first run migrates 1" 1 first.annotations_total;
    let second =
      Mig.migrate_flat_to_partitioned
        ~base_path
        ~delete_legacy_after:true
        ()
    in
    check int "second run is no-op" 0 second.annotations_total)
;;

let test_delete_legacy_after_removes_files () =
  with_temp_base (fun base_path ->
    init_empty_store base_path;
    let repo_root = Filename.concat base_path "workspace/repo" in
    register_repo
      ~base_path
      ~id:"sandbox"
      ~url:"https://github.com/owner/repo"
      ~local_path:repo_root;
    seed_legacy_annotation
      ~base_path
      ~id:"ann-del"
      ~keeper_id:"sangsu"
      ~file_path:(Filename.concat repo_root "lib/foo.ml")
      ~content:"to be deleted from legacy";
    seed_legacy_region
      ~base_path
      ~keeper_id:"sangsu"
      ~file_path:(Filename.concat repo_root "lib/foo.ml");
    let legacy_dir =
      Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Legacy
    in
    let legacy_ann = Filename.concat legacy_dir "annotations.jsonl" in
    let legacy_reg = Filename.concat legacy_dir "regions.jsonl" in
    check bool "legacy ann exists pre" true (Sys.file_exists legacy_ann);
    check bool "legacy reg exists pre" true (Sys.file_exists legacy_reg);
    let _ =
      Mig.migrate_flat_to_partitioned
        ~base_path
        ~delete_legacy_after:true
        ()
    in
    check bool "legacy ann removed" false (Sys.file_exists legacy_ann);
    check bool "legacy reg removed" false (Sys.file_exists legacy_reg))
;;

let () =
  run
    "ide_migration"
    [ ( "RFC-0128 §5 Phase 3"
      , [ test_case
            "routes to By_url when repo known"
            `Quick
            test_routes_to_by_url_when_repo_known
        ; test_case
            "routes to Orphan when unregistered"
            `Quick
            test_routes_to_orphan_when_unregistered
        ; test_case "dry_run writes nothing" `Quick test_dry_run_writes_nothing
        ; test_case "idempotent — second run is no-op" `Quick test_idempotency_second_run_is_noop
        ; test_case
            "delete_legacy_after removes flat files"
            `Quick
            test_delete_legacy_after_removes_files
        ] )
    ]
;;
