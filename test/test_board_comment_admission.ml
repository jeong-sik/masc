open Masc

module Access = Masc_board_handlers.Board_access

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let loaded store =
  require (Board.initialize_store store);
  require (Board.require_posts_source_readable store);
  require (Board.require_comments_source_readable store);
  ignore (require (Board.read_sub_boards store));
  store

let fresh base = loaded (Board.create_store ~base_path:base ())

let post store ?hearth ?(visibility = Board.Public) ?(content = "shared parent") () =
  let lookup = Recipient_lookup.make (fun _ ->
    Ok (Some (require (Board.Agent_id.of_string "private-target")))) in
  match Board.create_post store ~lookup ~author:"owner" ~content
      ~post_kind:Board.Human_post ~visibility ?hearth ~ttl_hours:0 () with
  | Ok post -> post
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let append store (parent : Board.post) ?(reader = Access.Operator) ?(author = "outsider") content =
  Board.add_comment store ~reader ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~author ~content ~ttl_hours:0 ()

let bytes path = if Sys.file_exists path then Some (Fs_compat.load_file path) else None
let same_bytes label before path = Alcotest.(check (option string)) label before (bytes path)

let expect_io = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "stale admission wrote a comment"

let expect_validation = function
  | Error (Board.Validation_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "forbidden comment was accepted"

let scoped store =
  let board = require (Board.create_sub_board store ~slug:"policy-thread"
    ~name:"Policy thread" ~description:"admission" ~owner:"owner" ~access:Board.Open ()) in
  board, post store ~hearth:board.slug ()

let test_foreign_close base =
  let first = fresh base in
  let parent = post first () in
  let other = fresh base in
  require (Board.set_closed other ~post_id:(Board.Post_id.to_string parent.id)
    ~closed_by:"owner" ~successor:Board.No_successor ~summary:"finished" ());
  let path = Board.comments_path first in
  let before = bytes path in
  expect_io (append first parent "after the durable close");
  same_bytes "stale Open cannot append" before path;
  Alcotest.(check int) "no local rejected row" 0 (Hashtbl.length first.comments);
  expect_validation (append (fresh base) parent "fresh closed parent");
  same_bytes "restart does not discover a rejected row" before path

let test_foreign_policy base =
  let first = fresh base in
  let board, parent = scoped first in
  let other = fresh base in
  ignore (require (Board.update_sub_board other
    ~sub_board_id:(Board.Sub_board_id.to_string board.id) ~access:Board.Owner_only ()));
  let path = Board.comments_path first in
  let before = bytes path in
  expect_io (append first parent "old Open policy");
  same_bytes "changed policy refuses before append" before path;
  let restarted = fresh base in
  expect_validation (append restarted parent "Operator reader does not bypass author policy");
  ignore (require (append restarted parent ~author:"owner" "current owner may comment"))

let test_new_policy_for_unregistered_hearth base =
  let first = fresh base in
  let parent = post first ~hearth:"unregistered" () in
  let other = fresh base in
  ignore (require (Board.create_sub_board other ~slug:"unregistered" ~name:"New policy"
    ~description:"was absent" ~owner:"owner" ~access:Board.Owner_only ()));
  let path = Board.comments_path first in
  let before = bytes path in
  expect_io (append first parent "stale missing policy");
  same_bytes "observed absence is guarded" before path;
  expect_validation (append (fresh base) parent "fresh restricted policy")

let test_unscoped_policy_failure base =
  let first = fresh base in
  let parent = post first () in
  let path = Board.sub_boards_path first in
  Unix.mkdir path 0o700;
  Alcotest.(check bool) "actual policy reload failed" true
    (Result.is_error (Board.reload_sub_boards first));
  let comment = require (append first parent "unscoped parent needs no policy") in
  Unix.rmdir path;
  let restarted = fresh base in
  ignore (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string comment.id)))

let test_boundary_reader_is_not_author base =
  let first = fresh base in
  let parent = post first ~visibility:Board.Direct ~content:"@private-target private parent" () in
  let path = Board.comments_path first in
  let before = bytes path in
  (match append first parent ~reader:(Access.named "outsider") ~author:"owner" "spoofed reader" with
   | Error (Board.Post_not_found _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "author string granted Direct readership");
  same_bytes "denied reader writes nothing" before path;
  ignore (require (append first parent ~author:"outsider" "Operator reader may read Direct"));
  let alias = Access.Named { name = "session-label"; addressed_by = (fun id ->
    String.equal (Board.Agent_id.to_string id) "private-target") } in
  ignore (require (append first parent ~reader:alias ~author:"different-writer" "actual reader alias"));
  Alcotest.(check int) "both authorized comments remain" 2 (Hashtbl.length (fresh base).comments)

let contend path =
  match Fs_compat.append_private_jsonl_durable_stable_result path "\n" with
  | Error (Fs_compat.Stable_lock_contended _) -> exit 0
  | Error _ -> exit 2
  | Ok _ -> exit 3

let test_live_readset_locks base =
  let initial = fresh base in
  let _, parent = scoped initial in
  let comments = Board.comments_path initial in
  let targets = [Board.persist_path initial; Board.sub_boards_path initial] in
  let armed = ref false in
  let receipt = Filename.concat base "contenders.txt" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun path ->
      if !armed && String.equal path comments then (
        let results = List.map (fun target ->
          let exe = Sys.executable_name in
          let pid = Unix.create_process exe [|exe; "--contend-comment-admission"; target|]
              Unix.stdin Unix.stdout Unix.stderr in
          match snd (Unix.waitpid [] pid) with
          | Unix.WEXITED 0 -> "contended"
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> "unexpected") targets in
        let output = open_out_bin receipt in
        output_string output (String.concat "\n" results); close_out output));
    close = (fun _ fd -> Unix.close fd)
  } in
  let first = loaded (Board.create_store_with_comments_io_for_testing ~base_path:base ~io ()) in
  armed := true;
  let comment = require (append first parent "guarded append") in
  Alcotest.(check string) "both real stable locks remain held through append"
    "contended\ncontended" (Fs_compat.load_file receipt);
  ignore (require (Board.get_comment (fresh base) ~comment_id:(Board.Comment_id.to_string comment.id)))

let with_parent_cleanup base f =
  let armed = ref false in
  let path = ref "" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close = (fun closing fd -> Unix.close fd;
      if !armed && String.equal closing !path then (armed := false; raise Eio.Time.Timeout))
  } in
  let first = loaded (Board.create_store_with_source_io_for_testing ~base_path:base
      ~io:{ posts = Some io } ()) in
  path := Board.persist_path first;
  f first armed

let expect_timeout f = match f () with
  | _ -> Alcotest.fail "reserved cleanup cause was lost"
  | exception Eio.Time.Timeout -> ()

let test_known_append_parent_cleanup base = with_parent_cleanup base (fun first armed ->
  let parent = post first () in
  armed := true;
  expect_timeout (fun () -> append first parent "known append before parent cleanup");
  Alcotest.(check int) "known comment was published before propagation" 1 (Hashtbl.length first.comments);
  Alcotest.(check int) "fresh store retains known append" 1 (Hashtbl.length (fresh base).comments);
  require (Board.require_comments_source_readable first))

let test_refused_policy_parent_cleanup base = with_parent_cleanup base (fun first armed ->
  let board, parent = scoped first in
  let other = fresh base in
  ignore (require (Board.update_sub_board other
    ~sub_board_id:(Board.Sub_board_id.to_string board.id) ~access:Board.Owner_only ()));
  let path = Board.comments_path first in
  let before = bytes path in
  armed := true;
  expect_timeout (fun () -> append first parent "refused before append");
  same_bytes "inner refusal plus outer cleanup did not append" before path;
  (match first.comments_source with
   | Board.Comments_readable { diagnostics; _ } ->
     let paths = List.filter_map (function Board.Comments_guard_diagnostic failure ->
       Some failure.guard_path | _ -> None) diagnostics in
     Alcotest.(check (list string)) "actual inner then outer paths"
       [Board.sub_boards_path first; Board.persist_path first] paths
   | _ -> Alcotest.fail "guard refusal invented an unsettled comments write"))

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let base = Filename.temp_dir "masc-comment-admission-" "" in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Unix.unsetenv "MASC_BASE_PATH"
    | Some value -> Unix.putenv "MASC_BASE_PATH" value)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base; f base)

let () = match Array.to_list Sys.argv with
  | [_; "--contend-comment-admission"; path] -> contend path
  | _ ->
    Mirage_crypto_rng_unix.use_default ();
    Alcotest.run "Board comment admission" ["real sources", List.map
      (fun (name, test) -> Alcotest.test_case name `Quick (with_fixture test))
      ["foreign durable close", test_foreign_close;
       "foreign restricted policy", test_foreign_policy;
       "new policy for an unregistered hearth", test_new_policy_for_unregistered_hearth;
       "unscoped parent with unavailable policy", test_unscoped_policy_failure;
       "boundary reader is not author", test_boundary_reader_is_not_author;
       "live parent and policy locks", test_live_readset_locks;
       "known append before parent cleanup", test_known_append_parent_cleanup;
       "policy refusal plus parent cleanup", test_refused_policy_parent_cleanup]]
