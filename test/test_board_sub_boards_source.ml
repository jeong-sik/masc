open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let require_unavailable = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "an incomplete policy source was accepted"

let reload store = match Board.reload_sub_boards store with
  | Ok count -> count
  | Error (path, error) -> Alcotest.failf "reload %s: %s" path (Printexc.to_string error)

let new_store base_path =
  let store = Board.create_store ~base_path () in
  ignore (reload store);
  store

let create store slug = Board.create_sub_board store ~slug ~name:slug
    ~description:"preserve independently accepted policy" ~owner:"policy-owner" ()

let get store slug = require (Board.get_sub_board store ~sub_board_id:slug)

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-policy-source-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Board.reset_global_for_test ();
    Board_dispatch.reset_for_test ();
    (match before with
     | None -> Unix.unsetenv "MASC_BASE_PATH"
     | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base_path)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_stale_update_preserves_foreign_policy base_path =
  let first = new_store base_path in
  ignore (require (create first "existing"));
  let stale = new_store base_path in
  ignore (require (create first "foreign"));
  let path = Board.sub_boards_path first in
  let bytes = Fs_compat.load_file path in
  require_unavailable (Board.update_sub_board stale ~sub_board_id:"existing" ~name:"not committed" ());
  Alcotest.(check string) "stale update preserves foreign bytes" bytes (Fs_compat.load_file path);
  Alcotest.(check int) "failed update leaves the old display model" 1
    (List.length (Board.list_sub_boards stale));
  require_unavailable (Board.read_sub_boards stale);
  List.iter (fun slug -> require_unavailable (Board.get_sub_board stale ~sub_board_id:slug))
    ["existing"; "foreign"; "absent"];
  Alcotest.(check int) "explicit complete reload installs both policies" 2 (reload stale);
  ignore (require (Board.update_sub_board stale ~sub_board_id:"existing" ~name:"committed" ()));
  let restarted = new_store base_path in
  Alcotest.(check string) "the updated policy survives restart" "committed" (get restarted "existing").name;
  Alcotest.(check string) "the foreign policy survives update and restart" "foreign"
    (get restarted "foreign").name

let test_stale_append_and_delete_preserve_foreign_policy base_path =
  let first = new_store base_path in
  ignore (require (create first "existing"));
  let stale = new_store base_path in
  ignore (require (create first "foreign"));
  let path = Board.sub_boards_path first in
  let bytes = Fs_compat.load_file path in
  require_unavailable (create stale "not-appended");
  require_unavailable (create stale "existing");
  Alcotest.(check string) "stale append preserves both policies" bytes (Fs_compat.load_file path);
  ignore (reload stale);
  ignore (require (Board.update_sub_board first ~sub_board_id:"existing" ~name:"newer policy" ()));
  let bytes = Fs_compat.load_file path in
  require_unavailable (Board.delete_sub_board stale ~sub_board_id:"existing");
  Alcotest.(check string) "stale deletion preserves the newer policy" bytes (Fs_compat.load_file path);
  ignore (reload stale);
  require (Board.delete_sub_board stale ~sub_board_id:"existing");
  let restarted = new_store base_path in
  Alcotest.(check int) "only the explicitly deleted policy is removed" 1
    (List.length (require (Board.read_sub_boards restarted)));
  Alcotest.(check string) "foreign policy remains durable" "foreign" (get restarted "foreign").slug

let test_same_size_edit_refuses_update base_path =
  let store = new_store base_path in
  ignore (require (create store "existing"));
  let path = Board.sub_boards_path store in
  let before = Unix.lstat path in
  let bytes = Fs_compat.load_file path in
  let row = get store "existing" in
  let edited = Yojson.Safe.to_string (Board.sub_board_to_yojson { row with name = "Existing" }) ^ "\n" in
  Out_channel.with_open_bin path (fun out -> output_string out edited);
  let after = Unix.lstat path in
  Alcotest.(check int) "fixture retains the source inode" before.Unix.st_ino after.Unix.st_ino;
  Alcotest.(check int) "fixture retains the source size" before.Unix.st_size after.Unix.st_size;
  Alcotest.(check bool) "fixture actually changes source bytes" false (String.equal bytes edited);
  require_unavailable (Board.update_sub_board store ~sub_board_id:"existing" ~name:"not committed" ());
  Alcotest.(check string) "equal-size foreign edit survives refusal" edited (Fs_compat.load_file path)

let test_present_source_loss_is_not_initial_empty base_path =
  let store = new_store base_path in
  ignore (require (create store "existing"));
  let path = Board.sub_boards_path store in
  Sys.remove path;
  require_unavailable (create store "not-recreated");
  Alcotest.(check bool) "lost Present policy file is not recreated" false (Sys.file_exists path);
  Alcotest.(check bool) "explicit reload cannot turn lost Present into initial empty" true
    (Result.is_error (Board.reload_sub_boards store));
  require_unavailable (Board.read_sub_boards store);
  Alcotest.(check int) "loss does not clear the retained display policy" 1
    (List.length (Board.list_sub_boards store))

type query_source = Missing | Empty | Invalid_row | Torn_tail | Non_regular

let with_started_store base_path f =
  let reset () = Board_dispatch.reset_for_test (); Board.reset_global_for_test () in
  reset ();
  Fun.protect ~finally:reset (fun () ->
    Result.get_ok (Board_dispatch.init_jsonl ~base_path
      ~recipient_lookup:Recipient_lookup.none_declared ());
    f (Board.global ()))

let tool name args =
  Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator
    ~result_boundary:Tool_output.Sent_to_client name args

let require_runtime_failure result = match result with
  | Tool_result.Failed { class_ = Tool_result.Runtime_failure; _ } -> ()
  | Tool_result.Failed _ | Tool_result.Completed _ | Tool_result.Deferred _ ->
    Alcotest.fail "policy source failure must remain a tool runtime failure"

let test_query_boundary source base_path =
  let store = new_store base_path in
  let path = Board.sub_boards_path store in
  (match source with
   | Missing -> ()
   | Empty -> Out_channel.with_open_bin path (fun _ -> ())
   | Non_regular -> Unix.mkdir path 0o700
   | Invalid_row | Torn_tail ->
     ignore (require (create store "existing"));
     let suffix = match source with
       | Invalid_row -> "!PRIVATE_POLICY_BODY\n"
       | Torn_tail -> "{unterminated-policy"
       | Missing | Empty | Non_regular -> Alcotest.fail "invalid fixture selection" in
     let bytes = Fs_compat.load_file path ^ suffix in
     Out_channel.with_open_bin path (fun out -> output_string out bytes));
  with_started_store base_path (fun restarted ->
    let reader = Masc_board_handlers.Board_access.Operator in
    let listed = tool "masc_board_sub_board_list" (`Assoc []) in
    let detail slug = Server_routes_http_runtime.board_sub_board_detail_json ~reader
        ~path:(Server_routes_http_runtime.board_sub_board_detail_prefix ^ slug) in
    match source with
    | Missing | Empty ->
      Alcotest.(check int) "complete empty policy source has no rows" 0
        (List.length (require (Board.read_sub_boards restarted)));
      Alcotest.(check bool) "complete empty tool list succeeds" true (Tool_result.is_success listed);
      Alcotest.(check bool) "complete absent policy has HTTP404" true (fst (detail "absent") = `Not_found)
    | Invalid_row | Torn_tail | Non_regular ->
      require_unavailable (Board.read_sub_boards restarted);
      require_runtime_failure listed;
      List.iter (fun slug ->
        (match Board.get_sub_board restarted ~sub_board_id:slug with
         | Error (Board.Io_error message) ->
           Alcotest.(check string) "public source error contains no parser fragments"
             "Board data is unavailable." message
         | Error error -> Alcotest.fail (Board.show_board_error error)
         | Ok _ -> Alcotest.fail "incomplete policy point query succeeded");
        require_runtime_failure (tool "masc_board_sub_board_get"
          (`Assoc ["sub_board_id", `String slug]));
        Alcotest.(check bool) "cached and absent policy targets have HTTP503" true
          (fst (detail slug) = `Service_unavailable)) ["existing"; "absent"];
      (match source with
       | Invalid_row ->
         Alcotest.(check int) "valid rows remain available for explicit display" 1
           (List.length (Board.list_sub_boards restarted))
       | Torn_tail | Non_regular | Missing | Empty -> ()))

let test_unknown_rewrite_retains_evidence base_path =
  let armed = ref false and calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        incr calls;
        if !armed then (armed := false; raise (Failure "policy parent sync")))
    ; close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = Board.create_store_with_sub_boards_io_for_testing ~base_path ~io () in
  ignore (reload store);
  ignore (require (create store "existing"));
  armed := true;
  require_unavailable (Board.update_sub_board store ~sub_board_id:"existing" ~name:"visible rewrite" ());
  let path = Board.sub_boards_path store in
  let visible_bytes = Fs_compat.load_file path in
  let before = !calls in
  require_unavailable (Board.read_sub_boards store);
  Alcotest.(check bool) "ordinary reload cannot discard an unknown rewrite" true
    (Result.is_error (Board.reload_sub_boards store));
  require_unavailable (create store "not-replayed");
  Alcotest.(check int) "unsettled operations do not replay filesystem work" before !calls;
  (match store.Board.sub_boards_source with
   | Board.Policy_unsettled { policy_pending; _ } ->
     Alcotest.(check string) "exact interrupted bytes remain retained"
       visible_bytes policy_pending.policy_intended_bytes
   | Policy_unobserved | Policy_readable _ | Policy_publishing _ | Policy_refused _ ->
     Alcotest.fail "uncertain rewrite lost its source evidence");
  let restarted = new_store base_path in
  Alcotest.(check string) "fresh store observes the current file, without settling the old attempt"
    "visible rewrite" (get restarted "existing").name

type successful_write = Append | Rewrite

let test_reserved_cleanup_publishes_known_write kind base_path =
  let armed = ref false and lock_path = ref None in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ -> ())
    ; close_fd = (fun fd ->
        let stat = Unix.fstat fd in
        let target = Option.map Unix.lstat !lock_path in
        Unix.close fd;
        match !armed, target with
        | true, Some lock when stat.Unix.st_dev = lock.Unix.st_dev
                               && stat.Unix.st_ino = lock.Unix.st_ino ->
          armed := false;
          raise Eio.Time.Timeout
        | false, (None | Some _) | true, None | true, Some _ -> ()) } in
  let store = Board.create_store_with_sub_boards_io_for_testing ~base_path ~io () in
  ignore (reload store);
  ignore (require (create store "existing"));
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.sub_boards_path store));
  armed := true;
  (match (match kind with
     | Append -> create store "new-policy"
     | Rewrite -> Board.update_sub_board store ~sub_board_id:"existing" ~name:"published rewrite" ()) with
   | _ -> Alcotest.fail "reserved cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  let rows = require (Board.read_sub_boards store) in
  (match kind with
   | Append -> Alcotest.(check int) "known append is published before reserved cleanup escapes" 2 (List.length rows)
   | Rewrite -> Alcotest.(check string) "known rewrite is published before reserved cleanup escapes"
       "published rewrite" (get store "existing").name);
  ignore (require (create store "after-cleanup"));
  let restarted = new_store base_path in
  Alcotest.(check int) "known write and later publication survive a fresh store"
    (List.length (require (Board.read_sub_boards store)))
    (List.length (require (Board.read_sub_boards restarted)))

let () =
  Alcotest.run "board_sub_boards_source"
    ["actual writers and restart",
      [Alcotest.test_case "stale update retains foreign policy" `Quick
         (with_fixture test_stale_update_preserves_foreign_policy);
       Alcotest.test_case "stale append and deletion retain foreign policy" `Quick
         (with_fixture test_stale_append_and_delete_preserve_foreign_policy)];
     "source loss and byte changes",
       [Alcotest.test_case "same-size source edit" `Quick (with_fixture test_same_size_edit_refuses_update);
        Alcotest.test_case "Present source loss" `Quick (with_fixture test_present_source_loss_is_not_initial_empty)];
     "actual query consumers",
       List.map (fun (name, source) -> Alcotest.test_case name `Quick (with_fixture (test_query_boundary source)))
         ["initial Missing", Missing; "Present empty", Empty; "invalid row", Invalid_row;
          "torn tail", Torn_tail; "nonregular", Non_regular];
     "actual transaction faults",
       [Alcotest.test_case "unknown rewrite remains fail-stop" `Quick (with_fixture test_unknown_rewrite_retains_evidence);
        Alcotest.test_case "reserved append cleanup" `Quick (with_fixture (test_reserved_cleanup_publishes_known_write Append));
        Alcotest.test_case "reserved rewrite cleanup" `Quick (with_fixture (test_reserved_cleanup_publishes_known_write Rewrite))]]
