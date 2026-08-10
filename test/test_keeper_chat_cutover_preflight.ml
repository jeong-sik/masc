open Alcotest
open Masc

module Cutover = Keeper_chat_cutover_preflight

let temp_dir () =
  let path = Filename.temp_file "keeper-chat-cutover-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun child -> remove_tree (Filename.concat path child)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_dir f =
  let path = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let mkdir path = Unix.mkdir path 0o755

let touch path =
  Out_channel.with_open_bin path (fun _ -> ())
;;

let sqlite_ok db operation rc =
  if not (Sqlite3.Rc.is_success rc)
  then failf "%s failed: %s" operation (Sqlite3.errmsg db)
;;

let create_queue_database path =
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () ->
      if not (Sqlite3.db_close db) then fail "fixture database did not close")
    (fun () ->
       sqlite_ok
         db
         "create receipts"
         (Sqlite3.exec db "CREATE TABLE receipts (state_kind TEXT NOT NULL)");
       List.iter
         (fun state ->
            sqlite_ok
              db
              "insert receipt"
              (Sqlite3.exec
                 db
                 (Printf.sprintf
                    "INSERT INTO receipts (state_kind) VALUES ('%s')"
                    state)))
         [ "pending"
         ; "inflight"
         ; "recovery_required"
         ; "delivered"
         ; "failed"
         ; "delivered"
         ])
;;

let inspect_ok keepers_root =
  match Cutover.inspect ~keepers_root with
  | Ok report -> report
  | Error error -> fail (Cutover.error_to_string error)
;;

let test_absent_root_is_clear () =
  with_temp_dir @@ fun root ->
  let report = inspect_ok (Filename.concat root "missing") in
  check bool "clear" true (Cutover.is_clear report);
  check int "artifacts" 0 (Cutover.artifact_count report);
  check int "stranded work" 0 (Cutover.stranded_work_count report)
;;

let test_inventory_counts_all_cutover_artifacts () =
  with_temp_dir @@ fun keepers_root ->
  let keeper_dir = Filename.concat keepers_root "sangsu" in
  mkdir keeper_dir;
  let database_path = Filename.concat keeper_dir "chat-queue.sqlite3" in
  create_queue_database database_path;
  touch (database_path ^ "-journal");
  let direct_dir = Filename.concat keeper_dir ".chat-direct-active-v1" in
  mkdir direct_dir;
  touch (Filename.concat direct_dir "first.json");
  let nested = Filename.concat direct_dir "nested" in
  mkdir nested;
  touch (Filename.concat nested "second.json");
  let report = inspect_ok keepers_root in
  check bool "not clear" false (Cutover.is_clear report);
  check int "database plus sidecar plus directory" 3 (Cutover.artifact_count report);
  check int "active queue rows" 3 (Cutover.active_queue_row_count report);
  check int "direct markers" 2 report.direct_marker_count;
  check int "stranded work" 5 (Cutover.stranded_work_count report);
  match report.queue_databases with
  | [ database ] ->
    check string "keeper" "sangsu" database.keeper_name;
    check int "all rows" 6 database.counts.total;
    check int "terminal rows" 3 database.counts.terminal
  | databases -> failf "expected one queue database, got %d" (List.length databases)
;;

let test_symlinked_database_is_rejected () =
  with_temp_dir @@ fun keepers_root ->
  let keeper_dir = Filename.concat keepers_root "sangsu" in
  mkdir keeper_dir;
  let target = Filename.concat keepers_root "outside.sqlite3" in
  create_queue_database target;
  Unix.symlink target (Filename.concat keeper_dir "chat-queue.sqlite3");
  match Cutover.inspect ~keepers_root with
  | Error (Cutover.Unexpected_file_kind { actual = "symlink"; _ }) -> ()
  | Error error -> fail ("wrong error: " ^ Cutover.error_to_string error)
  | Ok _ -> fail "symlinked queue database was accepted"
;;

let test_symlinked_keeper_directory_is_rejected () =
  with_temp_dir @@ fun keepers_root ->
  let target = Filename.concat keepers_root "target" in
  mkdir target;
  Unix.symlink target (Filename.concat keepers_root "linked-keeper");
  match Cutover.inspect ~keepers_root with
  | Error (Cutover.Unexpected_file_kind { actual = "symlink"; _ }) -> ()
  | Error error -> fail ("wrong error: " ^ Cutover.error_to_string error)
  | Ok _ -> fail "symlinked Keeper directory was accepted"
;;

let () =
  Alcotest.run
    "keeper_chat_cutover_preflight"
    [ ( "inventory"
      , [ test_case "absent root is clear" `Quick test_absent_root_is_clear
        ; test_case
            "all hard-cut artifacts are counted"
            `Quick
            test_inventory_counts_all_cutover_artifacts
        ; test_case
            "symlinked database is rejected"
            `Quick
            test_symlinked_database_is_rejected
        ; test_case
            "symlinked Keeper directory is rejected"
            `Quick
            test_symlinked_keeper_directory_is_rejected
        ] )
    ]
;;
