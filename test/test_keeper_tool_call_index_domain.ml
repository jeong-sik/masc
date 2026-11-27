(* Where [Keeper_tool_call_index] runs its file and SQLite work. A system
   thread shares its domain's runtime lock, so work in a system thread of the
   main domain holds the lock the main scheduler needs. With a pool installed
   the work runs on a pool domain; without one, and from a pool job, it stays
   where the caller is. *)

module Index = Keeper_tool_call_index.For_testing

let domain_id () = (Domain.self () :> int)

let with_pool env f =
  let previous = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some pool -> Domain_pool_ref.set pool)
    (fun () ->
      Eio.Switch.run (fun sw ->
        Domain_pool_ref.set
          (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
        f ()))

let without_pool f =
  let previous = Domain_pool_ref.get () in
  Domain_pool_ref.clear_for_tests ();
  Fun.protect
    ~finally:(fun () -> Option.iter Domain_pool_ref.set previous)
    f

let test_without_a_pool_the_work_stays_on_the_callers_domain () =
  Eio_main.run (fun _env ->
    without_pool (fun () ->
      let caller = domain_id () in
      Alcotest.(check int) "the caller's domain" caller (Index.blocking domain_id)))

let test_with_a_pool_the_work_leaves_the_callers_domain () =
  Eio_main.run (fun env ->
    with_pool env (fun () ->
      let caller = domain_id () in
      let worker = Index.blocking domain_id in
      Alcotest.(check bool) "another domain" true (worker <> caller)))

let test_a_pool_job_keeps_the_work_in_its_domain () =
  Eio_main.run (fun env ->
    with_pool env (fun () ->
      let job_domain, work_domain =
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
          domain_id (), Index.blocking domain_id)
      in
      Alcotest.(check int) "the job's domain" job_domain work_domain))

(* The index's file helpers rely on running outside Eio: Fs_compat then takes
   its synchronous path, and the store mutex is never taken on a scheduler
   thread. Moving the work to a pool domain keeps it in a system thread. *)
let test_the_work_runs_outside_eio () =
  let outside_eio () =
    match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> true
    | Fs_compat.Eio_fiber -> false
  in
  Eio_main.run (fun env ->
    without_pool (fun () ->
      Alcotest.(check bool) "without a pool" true (Index.blocking outside_eio));
    with_pool env (fun () ->
      Alcotest.(check bool) "with a pool" true (Index.blocking outside_eio)))

exception Raised_in_the_work

let test_an_exception_reaches_the_caller () =
  Eio_main.run (fun env ->
    with_pool env (fun () ->
      Alcotest.check_raises "the work's exception" Raised_in_the_work (fun () ->
        Index.blocking (fun () -> raise Raised_in_the_work))))

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_ledger f =
  let root = Unix.realpath (Filename.temp_dir "tool-call-index-sqlite-" "") in
  let location = Dated_jsonl.Store.(at (root_of_masc_dir root) Root.Tool_calls) in
  let ledger_dir = Dated_jsonl.Store.dir location in
  Fs_compat.mkdir_p ledger_dir;
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_index.forget_for_ledger ~ledger_dir;
      remove_tree root)
    (fun () -> f ~ledger_dir ~store:(Dated_jsonl.open_store location))

let write_day_file ~ledger_dir ~rel lines =
  let path = Filename.concat ledger_dir rel in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
    List.iter (fun line -> output_string oc line; output_char oc '\n') lines);
  path

let read_single_pragma ~db_path sql =
  let db = Sqlite3.db_open db_path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db : bool)) (fun () ->
    let stmt = Sqlite3.prepare db sql in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t)) (fun () ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Sqlite3.column stmt 0
      | rc -> Alcotest.fail ("pragma failed: " ^ Sqlite3.Rc.to_string rc)))

let require_ok label = function
  | Ok v -> v
  | Error e -> Alcotest.fail (label ^ ": " ^ e)

let test_tuning_pragmas_batch_indexing_and_query_parity () =
  with_temp_ledger @@ fun ~ledger_dir ~store ->
  let d1 =
    write_day_file ~ledger_dir ~rel:"2026-11/25.jsonl"
      [ "{\"keeper\":\"alpha\",\"ts\":100.0,\"execution_id\":\"e-1\",\"answer_source_ids\":[\"s-1\",\"s-2\"]}"
      ; "{\"keeper\":\"beta\",\"ts\":101.0,\"execution_id\":\"e-2\"}"
      ]
  in
  let d2 =
    write_day_file ~ledger_dir ~rel:"2026-11/26.jsonl"
      [ "{\"keeper\":\"alpha\",\"ts\":200.0,\"execution_id\":\"e-3\",\"answer_source_ids\":[\"s-1\"]}"
      ; "{\"keeper\":\"alpha\",\"ts\":201.0}"
      ]
  in
  let _d3 =
    write_day_file ~ledger_dir ~rel:"2026-11/27.jsonl"
      [ "{\"keeper\":\"alpha\",\"ts\":300.0,\"execution_id\":\"e-4\"}" ]
  in
  let recent_all =
    require_ok "recent_rows all" (Keeper_tool_call_index.recent_rows ~store ~n:10 ())
  in
  Alcotest.(check int) "all 5 rows indexed across 3 day files" 5 (List.length recent_all);
  let db_path = Keeper_tool_call_index.database_path ~ledger_dir in
  (match read_single_pragma ~db_path "PRAGMA user_version" with
   | Sqlite3.Data.INT 9L -> ()
   | _ -> Alcotest.fail "schema_version must remain 9");
  (match read_single_pragma ~db_path "PRAGMA journal_mode" with
   | Sqlite3.Data.TEXT mode ->
     Alcotest.(check string) "WAL journal mode" "wal" (String.lowercase_ascii mode)
   | _ -> Alcotest.fail "journal_mode must be WAL");
  let recent_alpha =
    require_ok "recent_rows alpha"
      (Keeper_tool_call_index.recent_rows ~store ~keeper_name:"alpha" ~n:3 ())
  in
  Alcotest.(check int) "filtered recent_rows count" 3 (List.length recent_alpha);
  let by_exec =
    require_ok "by_execution_ids"
      (Keeper_tool_call_index.by_execution_ids ~store ~keeper_name:"alpha"
         ~execution_ids:[ "e-4"; "e-1"; "missing"; "e-1" ])
  in
  Alcotest.(check int) "deduped execution ids returned" 2 (List.length by_exec);
  let src_count =
    require_ok "fold_by_answer_source"
      (Keeper_tool_call_index.fold_by_answer_source ~store ~keeper_name:"alpha"
         ~source_id:"s-1" ~init:0 ~f:(fun n _ -> Ok (n + 1)))
  in
  Alcotest.(check int) "answer_sources indexed across days" 2 src_count;
  let batch1 =
    require_ok "rows_after empty"
      (Keeper_tool_call_index.rows_after ~store ~keeper_name:"alpha"
         ~after:Keeper_tool_call_index.empty_frontier ~project:(fun _ -> Some ()))
  in
  Alcotest.(check int) "rows_after scans all 4 alpha rows across 3 days" 4 (List.length batch1.rows);
  let batch2 =
    require_ok "rows_after incremental"
      (Keeper_tool_call_index.rows_after ~store ~keeper_name:"alpha"
         ~after:batch1.frontier ~project:(fun _ -> Some ()))
  in
  Alcotest.(check int) "incremental rows_after sees 0 new rows" 0 (List.length batch2.rows);
  (* Remove 2 day files at once to exercise batch stale-path deletion with reused statements. *)
  Sys.remove d1;
  Sys.remove d2;
  let after_delete =
    require_ok "recent_rows after multi-file removal"
      (Keeper_tool_call_index.recent_rows ~store ~keeper_name:"alpha" ~n:10 ())
  in
  Alcotest.(check int) "only d3 row remains after batch stale deletion" 1 (List.length after_delete)

let test_unexpected_column_type_triggers_clean_rebuild () =
  with_temp_ledger @@ fun ~ledger_dir ~store ->
  ignore
    (write_day_file ~ledger_dir ~rel:"2026-11/27.jsonl"
       [ "{\"keeper\":\"alpha\",\"ts\":500.0,\"execution_id\":\"e-500\"}" ]);
  let initial =
    require_ok "initial index"
      (Keeper_tool_call_index.recent_rows ~store ~keeper_name:"alpha" ~n:5 ())
  in
  Alcotest.(check int) "initial row count" 1 (List.length initial);
  (* Drop open handle and corrupt a cursor column type to TEXT so direct column
     decoding hits unexpected-type error and triggers authoritative rebuild. *)
  Keeper_tool_call_index.forget_for_ledger ~ledger_dir;
  let db_path = Keeper_tool_call_index.database_path ~ledger_dir in
  let db = Sqlite3.db_open db_path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db : bool)) (fun () ->
    let rc =
      Sqlite3.exec db
        "DROP TABLE cursors; \
         CREATE TABLE cursors (ledger_path TEXT PRIMARY KEY, boundary TEXT, device INTEGER, inode INTEGER, generation TEXT); \
         INSERT INTO cursors VALUES ('bad', 'not-an-int', 1, 1, 'gen');"
    in
    Alcotest.(check bool) "injected corrupt cursor type" true (Sqlite3.Rc.is_success rc));
  let rebuilt =
    require_ok "rebuild after unexpected column type"
      (Keeper_tool_call_index.recent_rows ~store ~keeper_name:"alpha" ~n:5 ())
  in
  Alcotest.(check int) "rebuilt authoritative row survives" 1 (List.length rebuilt)

let () =
  Alcotest.run "keeper_tool_call_index_domain"
    [
      ( "domain",
        [
          Alcotest.test_case "without a pool the work stays on the caller's domain" `Quick
            test_without_a_pool_the_work_stays_on_the_callers_domain;
          Alcotest.test_case "with a pool the work leaves the caller's domain" `Quick
            test_with_a_pool_the_work_leaves_the_callers_domain;
          Alcotest.test_case "a pool job keeps the work in its domain" `Quick
            test_a_pool_job_keeps_the_work_in_its_domain;
          Alcotest.test_case "the work runs outside Eio" `Quick
            test_the_work_runs_outside_eio;
          Alcotest.test_case "an exception reaches the caller" `Quick
            test_an_exception_reaches_the_caller;
        ] );
      ( "sqlite tuning and direct decoders",
        [
          Alcotest.test_case "tuning PRAGMAs, batch indexing, multi-day rows_after, and stale deletion parity" `Quick
            test_tuning_pragmas_batch_indexing_and_query_parity;
          Alcotest.test_case "unexpected column types fail closed and rebuild cleanly" `Quick
            test_unexpected_column_type_triggers_clean_rebuild;
        ] );
    ]
