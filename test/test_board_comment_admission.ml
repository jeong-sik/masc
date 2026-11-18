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

let same_inode left right =
  left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino

let test_live_readset_locks base =
  let initial = fresh base in
  let _, parent = scoped initial in
  (* The append seam closes an injected data FD for an existing source. The
     first Missing-file publication uses the replacement writer instead. *)
  ignore (require (append initial parent ~author:"owner" "existing comments source"));
  let comments = Board.comments_path initial in
  let targets = [Board.persist_path initial; Board.sub_boards_path initial] in
  let armed = ref false in
  let receipt = Filename.concat base "contenders.txt" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in
      Unix.close fd;
      (* The data descriptor closes after the actual append. Both source
         guards and the append's stable sibling lock are still owned here. *)
      if !armed && Sys.file_exists comments && same_inode stat (Unix.stat comments) then (
        let results = List.map (fun target ->
          let exe = Sys.executable_name in
          let pid = Unix.create_process exe [|exe; "--contend-comment-admission"; target|]
              Unix.stdin Unix.stdout Unix.stderr in
          match snd (Unix.waitpid [] pid) with
          | Unix.WEXITED 0 -> "contended"
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> "unexpected") targets in
        let output = open_out_bin receipt in
        output_string output (String.concat "\n" results); close_out output))
  } in
  let first = loaded (Board.create_store_with_comments_io_for_testing ~base_path:base ~io ()) in
  armed := true;
  let comment = require (append first parent "guarded append") in
  Alcotest.(check string) "both real stable locks remain held through append"
    "contended\ncontended" (Fs_compat.load_file receipt);
  ignore (require (Board.get_comment (fresh base) ~comment_id:(Board.Comment_id.to_string comment.id)))

let test_scoped_policy_refusal_revokes_queries base =
  let first = fresh base in
  let board, parent = scoped first in
  let path = Board.sub_boards_path first in
  let retained = path ^ ".retained" in
  Unix.rename path retained;
  Unix.mkdir path 0o700;
  let before = bytes (Board.comments_path first) in
  expect_io (append first parent "failed canonical policy guard");
  same_bytes "refused policy never appends" before (Board.comments_path first);
  expect_io (Board.read_sub_boards first);
  expect_io (Board.get_sub_board first ~sub_board_id:board.slug);
  Unix.rmdir path;
  Unix.rename retained path;
  expect_io (Board.read_sub_boards first);
  (match Board.reload_sub_boards first with
   | Ok _ -> ()
   | Error (path, error) -> Alcotest.failf "%s: %s" path (Printexc.to_string error));
  ignore (require (append first parent "explicit healthy policy reload restores admission"))

let with_parent_cleanup base f =
  let armed = ref false in
  let lock_path = ref None in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in
      Unix.close fd;
      match !lock_path with
      | Some path when !armed && same_inode stat (Unix.stat path) ->
        armed := false; raise Eio.Time.Timeout
      | Some _ | None -> ())
  } in
  let first = loaded (Board.create_store_with_source_io_for_testing ~base_path:base
      ~io:{ posts = Some io } ()) in
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.persist_path first));
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

(* A completed policy deletion also owns durable hearth unlinking. *)
let test_deleted_sub_board_keeps_comment_available base =
  let first = fresh base in
  let board, parent = scoped first in
  (match require (Board.delete_sub_board first ~authorization:Board.Operator_sub_board_deletion
     ~sub_board_id:(Board.Sub_board_id.to_string board.id)) with
   | Board.Durable_deletion -> ()
   | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail);
  let comment = require (append first parent "comment immediately after accepted sub-board deletion") in
  let restarted = fresh base in
  let restored = match Board.read_post restarted ~post_id:(Board.Post_id.to_string parent.id) with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.show_board_read_error error) in
  Alcotest.(check (option string)) "accepted hearth unlink survives restart" None restored.hearth;
  ignore (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string comment.id)))

let append_under store (parent : Board.post) ~parent_id ?(author = "outsider") content =
  Board.add_comment store ~reader:Access.Operator ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~author ~content ~parent_id ~ttl_hours:0 ()

let repeat_message (parent : Board.post) ~author (existing : Board.comment) =
  Printf.sprintf
    "Post %s already has this exact comment from %s as %s; it was not posted again. \
     Change the text or reply under a different comment"
    (Board.Post_id.to_string parent.id) author (Board.Comment_id.to_string existing.id)

let expect_repeat label expected = function
  | Error (Board.Validation_error message) -> Alcotest.(check string) label expected message
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail (label ^ ": the repeat was posted")

(* One Keeper turn once wrote 390 comments of 39 distinct bodies. A repeat is
   the same author, the same parent and the same bytes; any one of the three
   differing is a new comment, and the refusal stores nothing. *)
let test_exact_repeat_is_refused base =
  let store = fresh base in
  let parent = post store () in
  let first = require (append store parent "same words") in
  expect_repeat "top-level repeat names the first comment"
    (repeat_message parent ~author:"outsider" first) (append store parent "same words");
  Alcotest.(check int) "refusal stored nothing" 1 (Hashtbl.length store.comments);
  ignore (require (append store parent "same words."));
  ignore (require (append store parent ~author:"someone-else" "same words"));
  let first_id = Board.Comment_id.to_string first.id in
  let reply = require (append_under store parent ~parent_id:first_id "same words") in
  Alcotest.(check int) "different body, author and parent each post" 4 (Hashtbl.length store.comments);
  expect_repeat "reply repeat names the first reply"
    (repeat_message parent ~author:"outsider" reply)
    (append_under store parent ~parent_id:first_id "same words");
  Alcotest.(check int) "second refusal stored nothing" 4 (Hashtbl.length store.comments);
  let restarted = fresh base in
  expect_repeat "durable comment still blocks the repeat after a restart"
    (repeat_message parent ~author:"outsider" first) (append restarted parent "same words")

(* The refusal a reply gets when its parent is not a comment of its post. *)
let parent_refusal label = function
  | Error (Board.Validation_error message) -> message
  | Error error -> Alcotest.fail (label ^ ": " ^ Board.show_board_error error)
  | Ok _ -> Alcotest.fail (label ^ ": the reply was stored")

(* A reply hangs under a comment of the post it is written on. A client that
   had two threads open sent post B with a comment of post A as the parent
   (#52951), and callers of masc_board_comment did the same with an id read on
   another thread. Stored, that reply has no parent row in the thread it
   belongs to, and the Keeper event for it names a comment the thread does not
   hold. *)
let test_reply_parent_belongs_to_post base =
  let store = fresh base in
  let first = post store ~content:"first thread" () in
  let second = post store ~content:"second thread" () in
  let on_first = require (append store first "comment on the first thread") in
  let on_first_id = Board.Comment_id.to_string on_first.id in
  let nowhere_id = Board.Comment_id.to_string (Board.Comment_id.generate ()) in
  let path = Board.comments_path store in
  let before = bytes path in
  let on_another_post =
    parent_refusal "parent on another post"
      (append_under store second ~parent_id:on_first_id "reply sent with the other thread's parent")
  in
  let on_no_post =
    parent_refusal "parent that names no comment"
      (append_under store second ~parent_id:nowhere_id "reply under a comment nobody wrote")
  in
  (* A writer of the second post may not be a reader of the first: the answer
     must not say whether the id is a comment somewhere. *)
  Alcotest.(check string) "one refusal for a comment elsewhere and for no comment"
    on_another_post on_no_post;
  same_bytes "refused replies write nothing" before path;
  Alcotest.(check int) "refused replies are not in the model" 1 (Hashtbl.length store.comments);
  let reply = require (append_under store first ~parent_id:on_first_id "reply on its own thread") in
  Alcotest.(check (option string)) "a reply on its own thread keeps its parent" (Some on_first_id)
    (Option.map Board.Comment_id.to_string reply.parent_id)

(* The parent is listed when the reply stages and gone when the reply is
   admitted to persistence: a sweep that queued first removes it for its TTL.
   The reply is refused before its row is appended. A refusal after the append
   would have rewritten the comments file to take the row out again. *)
let test_parent_swept_while_reply_waits_for_persistence base =
  let store = fresh base in
  let thread = post store () in
  let parent = require (append store thread "comment whose time runs out") in
  let parent_id = Board.Comment_id.to_string parent.id in
  Hashtbl.replace store.comments parent_id { parent with expires_at = 1.0 };
  let path = Board.comments_path store in
  let before = bytes path in
  let swept, reply =
    Eio.Switch.run (fun sw ->
      let swept_done, resolve_swept = Eio.Promise.create () in
      let reply_done, resolve_reply = Eio.Promise.create () in
      Board.with_persist_lock store (fun () ->
        (* Each fiber runs until it waits for this lock, and the mutex admits
           waiters in arrival order: the sweep, then the reply, which has
           already staged against the listed parent. *)
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Promise.resolve resolve_swept (Board.sweep store));
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Promise.resolve resolve_reply
            (append_under store thread ~parent_id "reply written as its parent expires"));
        Alcotest.(check bool) "the sweep waits for persistence" false
          (Eio.Promise.is_resolved swept_done);
        Alcotest.(check bool) "the reply waits behind the sweep" false
          (Eio.Promise.is_resolved reply_done));
      Eio.Promise.await swept_done, Eio.Promise.await reply_done)
  in
  Alcotest.(check int) "the sweep removed the parent" 1 (snd swept);
  ignore (parent_refusal "parent swept before the reply was admitted" reply);
  same_bytes "the refused reply was never written" before path;
  Alcotest.(check int) "neither the parent nor the reply is in the model" 0
    (Hashtbl.length store.comments)

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
       "scoped policy refusal revokes strict queries", test_scoped_policy_refusal_revokes_queries;
       "boundary reader is not author", test_boundary_reader_is_not_author;
       "live parent and policy locks", test_live_readset_locks;
       "known append before parent cleanup", test_known_append_parent_cleanup;
       "policy refusal plus parent cleanup", test_refused_policy_parent_cleanup;
       "accepted sub-board deletion keeps comments available", test_deleted_sub_board_keeps_comment_available;
       "exact repeat of a comment is refused", test_exact_repeat_is_refused;
       "reply parent belongs to the post", test_reply_parent_belongs_to_post;
       "parent swept while the reply waits for persistence",
       test_parent_swept_while_reply_waits_for_persistence]]
