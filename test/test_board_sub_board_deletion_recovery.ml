open Masc

module Paths = Masc_board_handlers.Board_paths
let reader = Masc_board_handlers.Board_access.Operator
let () = Mirage_crypto_rng_unix.use_default ()
let require = function Ok value -> value | Error error -> Alcotest.fail (Board.show_board_error error)
let durable = function
  | Board.Durable_deletion -> ()
  | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail
let marker store = Paths.store_file_path store Paths.Deletion
let bytes path = if Sys.file_exists path then Some (Fs_compat.load_file path) else None
let fresh base_path =
  let store = Board.create_store ~base_path () in
  require (Board.initialize_store store); store
let room store slug = require (Board.create_sub_board store ~slug ~name:slug
  ~description:"owned deletion" ~owner:"room-owner" ())
let post store hearth body =
  match Board.create_post store ~lookup:Recipient_lookup.none_declared ~author:"room-owner"
    ~content:body ~hearth ~post_kind:Board.Human_post ~ttl_hours:0 () with
  | Ok post -> post
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)
let comment store (parent : Board.post) = require (Board.add_comment store ~reader
  ~lookup:Recipient_lookup.none_declared ~post_id:(Board.Post_id.to_string parent.id)
  ~author:"room-reader" ~content:"accepted reply" ~ttl_hours:0 ())
let delete store (board : Board.sub_board) = Board.delete_sub_board store
  ~authorization:(Board.Owner_sub_board_deletion board.owner)
  ~sub_board_id:(Board.Sub_board_id.to_string board.id)
let read store (post : Board.post) = match Board.read_post_for_evidence store
  ~post_id:(Board.Post_id.to_string post.id) with
  | Ok post -> post | Error error -> Alcotest.fail (Board.show_board_read_error error)
let absent store (board : Board.sub_board) = match Board.get_sub_board store
  ~sub_board_id:(Board.Sub_board_id.to_string board.id) with
  | Error (Board.Invalid_id _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "original sub-board remains"
let pending store progress = match store.Board.deletion_state with
  | Board.Deletion_pending work ->
    Alcotest.(check bool) "actual owned progress" true (work.deletion_progress = progress)
  | Board.Deletion_unobserved | Board.Deletion_readable _ | Board.Deletion_unsettled _
  | Board.Deletion_refused _ | Board.Deletion_projection_failed _ -> Alcotest.fail "deletion owner lost"
let same_inode left right = left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
let with_fixture run () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "masc-sub-board-delete-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> run base)

let test_durable_unlink_and_unselected_work base =
  let store = fresh base in
  let board = room store "original" in
  let parent = post store board.slug "retained parent" in
  let reply = comment store parent in
  ignore (require (Board.vote store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"room-voter" ~post_id:(Board.Post_id.to_string parent.id)
    ~direction:Board.Up));
  ignore (require (Board.toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ~user_id:"room-reactor" ~emoji:"👍"));
  let untouched = List.map (fun path -> path, bytes path)
    [Board.comments_path store; Board.vote_log_path store; Board.reactions_path store] in
  Alcotest.(check bool) "actual append leaves deferred comment work" true store.dirty_comments;
  durable (require (delete store board));
  absent store board;
  Alcotest.(check bool) "unselected comment work remains owned" true store.dirty_comments;
  List.iter (fun (path, before) -> Alcotest.(check (option string)) "unselected source is not rewritten"
    before (bytes path)) untouched;
  ignore (comment store parent);
  let restarted = fresh base in
  Alcotest.(check (option string)) "hearth unlink is durable without a flush" None (read restarted parent).hearth;
  ignore (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id)));
  Alcotest.(check bool) "decision retired" false (Sys.file_exists (marker restarted))

let test_foreign_predecision_post base =
  let first = fresh base in
  let board = room first "original" in
  let parent = post first board.slug "original post" in
  let other = fresh base in
  let foreign = post other board.slug "accepted before decision" in
  let before_posts = bytes (Board.persist_path first) and before_policy = bytes (Board.sub_boards_path first) in
  (match delete first board with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "stale canonical set recorded a deletion");
  Alcotest.(check (option string)) "foreign post preserved before a decision" before_posts (bytes (Board.persist_path first));
  Alcotest.(check (option string)) "policy unchanged before a decision" before_policy (bytes (Board.sub_boards_path first));
  Alcotest.(check bool) "no decision was recorded" false (Sys.file_exists (marker first));
  let current = fresh base in
  durable (require (delete current board));
  let restarted = fresh base in
  List.iter (fun parent -> Alcotest.(check (option string)) "complete canonical set unlinked"
    None (read restarted parent).hearth) [parent; foreign]

let test_shadowed_board_does_not_unlink_winner base =
  let seed = fresh base in
  let shadowed = room seed "shared" in
  let winner = require (Board.create_sub_board seed ~slug:"other" ~name:"winner"
    ~description:"independently accepted policy" ~owner:"other-owner" ()) in
  let winner = { winner with slug = shadowed.slug } in
  let path = Board.sub_boards_path seed in
  let observed = Result.get_ok (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None) in
  let content = String.concat "" (List.map (fun board ->
    Yojson.Safe.to_string (Board.sub_board_to_yojson board) ^ "\n") [shadowed; winner]) in
  ignore (Result.get_ok (Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
    path ~expected:observed content));
  let store = fresh base in
  let parent = post store winner.slug "belongs to the canonical slug winner" in
  let before = bytes path in
  (match Board.delete_sub_board store ~authorization:(Board.Owner_sub_board_deletion shadowed.owner)
     ~sub_board_id:(Board.Sub_board_id.to_string winner.id) with
   | Error (Board.Unauthorized _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "original requester was replaced by the current owner");
  Alcotest.(check (option string)) "canonical owner refusal preserves policy" before (bytes path);
  durable (require (delete store shadowed));
  let restarted = fresh base in
  absent restarted shadowed;
  let actual = require (Board.get_sub_board restarted ~sub_board_id:winner.slug) in
  Alcotest.(check string) "slug keeps the other board's identity"
    (Board.Sub_board_id.to_string winner.id) (Board.Sub_board_id.to_string actual.id);
  Alcotest.(check (option string)) "shadowed board deletion preserves winner's post"
    (Some winner.slug) (read restarted parent).hearth

let stop_after_known_record marker_path armed = {
  Fs_compat.before_sync_parent = (fun _ -> ());
  close_fd = (fun fd ->
    let stat = Unix.fstat fd in
    let lock = Unix.lstat (Fs_compat.private_jsonl_lock_path !marker_path) in
    Unix.close fd;
    if !armed && same_inode stat lock && Sys.file_exists !marker_path then (
      armed := false; raise Eio.Time.Timeout)) }

let test_deleted_winner_restores_restricted_shadow base =
  let seed = fresh base in
  let shadowed = require (Board.create_sub_board seed ~slug:"shared" ~name:"restricted"
    ~description:"remaining policy" ~owner:"room-owner" ~access:Board.Owner_only ()) in
  let winner = require (Board.create_sub_board seed ~slug:"other" ~name:"winner"
    ~description:"active policy" ~owner:"other-owner" ()) in
  let winner = { winner with slug = shadowed.slug } in
  let path = Board.sub_boards_path seed in
  let observed = Result.get_ok (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None) in
  let content = String.concat "" (List.map (fun board ->
    Yojson.Safe.to_string (Board.sub_board_to_yojson board) ^ "\n") [shadowed; winner]) in
  ignore (Result.get_ok (Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
    path ~expected:observed content));
  let store = fresh base in
  let parent = post store winner.slug "old active board post" in
  durable (require (delete store winner));
  let restarted = fresh base in
  List.iter (fun current ->
    let actual = require (Board.get_sub_board current ~sub_board_id:shadowed.slug) in
    Alcotest.(check string) "current and fresh stores agree on the remaining policy"
      (Board.Sub_board_id.to_string shadowed.id) (Board.Sub_board_id.to_string actual.id);
    (match Board.create_post current ~lookup:Recipient_lookup.none_declared ~author:"outsider"
       ~content:"must not bypass the restored owner policy" ~hearth:shadowed.slug
       ~post_kind:Board.Human_post ~ttl_hours:0 () with
     | Ok _ -> Alcotest.fail "remaining owner-only policy was bypassed"
     | Error failure ->
       match Board.Post_publication_failure.cause failure with
       | Board.Post_publication_failure.Board_error (Board.Validation_error _) -> ()
       | Board.Post_publication_failure.Board_error error -> Alcotest.fail (Board.show_board_error error)
       | Board.Post_publication_failure.Raised error -> Alcotest.fail (Printexc.to_string error))) [store; restarted];
  Alcotest.(check (option string)) "original winner's captured post remains unlinked" None (read restarted parent).hearth

let test_fixed_ids_after_interruption base =
  let marker_path = ref "" and armed = ref false in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path:base
    ~io:(stop_after_known_record marker_path armed) () in
  marker_path := marker store;
  require (Board.initialize_store store);
  let board = room store "original" in
  let parent = post store board.slug "original post" in
  let other = fresh base in
  armed := true;
  (match delete store board with
   | exception Eio.Time.Timeout -> ()
   | Ok _ -> Alcotest.fail "known record cleanup did not interrupt"
   | Error error -> Alcotest.fail (Board.show_board_error error));
  pending store Board.Decision_recorded;
  Alcotest.(check (option string)) "known decision precedes model changes" (Some board.slug) (read store parent).hearth;
  let late = post other board.slug "accepted after fixed decision" in
  let other_board = room other "unrelated" in
  let restarted = fresh base in
  absent restarted board;
  Alcotest.(check (option string)) "original fixed post is unlinked" None (read restarted parent).hearth;
  Alcotest.(check (option string)) "later post remains outside the plan" (Some board.slug) (read restarted late).hearth;
  ignore (require (Board.get_sub_board restarted ~sub_board_id:(Board.Sub_board_id.to_string other_board.id)))

let test_unknown_decision base =
  let marker_path = ref "" and armed = ref false and calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed && Sys.file_exists !marker_path then (
      armed := false; raise (Sys_error "marker directory sync failed")));
    close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path:base ~io () in
  marker_path := marker store;
  require (Board.initialize_store store);
  let board = room store "original" in
  let parent = post store board.slug "original post" in
  let before = bytes (Board.persist_path store), bytes (Board.sub_boards_path store) in
  armed := true;
  (match require (delete store board) with
   | Board.Deletion_decision_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_persistence_pending _ -> Alcotest.fail "unknown decision reported applied");
  Alcotest.(check bool) "data sources unchanged" true
    (before = (bytes (Board.persist_path store), bytes (Board.sub_boards_path store)));
  Alcotest.(check (option string)) "model remains attached" (Some board.slug) (read store parent).hearth;
  let before_calls = !calls in
  Board.flush_dirty store;
  Alcotest.(check int) "flush never replays an unknown marker" before_calls !calls;
  let restarted = fresh base in
  absent restarted board;
  Alcotest.(check (option string)) "fresh store completes the recorded unlink" None (read restarted parent).hearth

let test_unknown_posts_require_fresh_recovery base =
  let armed = ref false and calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed then (
      armed := false; raise (Sys_error "posts directory sync failed")));
    close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = Board.create_store_with_source_io_for_testing ~base_path:base ~io:{ posts = Some io } () in
  require (Board.initialize_store store);
  let board = room store "original" in
  let parent = post store board.slug "original post" in
  armed := true;
  (match require (delete store board) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_decision_pending _ -> Alcotest.fail "unknown source progress lost");
  pending store Board.Sources_uncertain;
  let calls_before = !calls and policy_before = bytes (Board.sub_boards_path store) in
  Board.flush_dirty store;
  pending store Board.Sources_uncertain;
  Alcotest.(check int) "unknown source is not permission to replay the deletion" calls_before !calls;
  Alcotest.(check (option string)) "policy remains original until fresh recovery" policy_before (bytes (Board.sub_boards_path store));
  let restarted = fresh base in
  absent restarted board;
  Alcotest.(check (option string)) "fresh recovery completes both sources" None (read restarted parent).hearth

let test_pending_policy_refuses_reload base =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  let marker_path = ref "" and policy_lock = ref "" and armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in
      let lock = Unix.lstat (Fs_compat.private_jsonl_lock_path !marker_path) in
      Unix.close fd;
      if !armed && same_inode stat lock && Sys.file_exists !marker_path then (
        armed := false; Unix.chmod !policy_lock 0o400)) } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path:base ~io () in
  marker_path := marker store;
  policy_lock := Fs_compat.private_jsonl_lock_path (Board.sub_boards_path store);
  require (Board.initialize_store store);
  let board = room store "original" in
  let parent = post store board.slug "original post" in
  armed := true;
  (match require (delete store board) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_decision_pending _ -> Alcotest.fail "expected pending policy write");
  pending store Board.Model_applied;
  Alcotest.(check bool) "policy reload cannot restore a pending deletion" true (Result.is_error (Board.reload_sub_boards store));
  Alcotest.(check (option string)) "known posts write survives policy failure" None (read store parent).hearth;
  Unix.chmod !policy_lock 0o600;
  let restarted = fresh base in
  absent restarted board;
  Alcotest.(check (option string)) "restart finishes the original owned unlink" None (read restarted parent).hearth

let test_unknown_retirement_preserves_reused_slug base =
  let marker_path = ref "" and armed = ref false and saw_record = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ ->
      if Sys.file_exists !marker_path then saw_record := true;
      if !armed && !saw_record && not (Sys.file_exists !marker_path) then (
        armed := false; raise (Sys_error "retirement directory sync failed")));
    close_fd = Unix.close } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path:base ~io () in
  marker_path := marker store;
  require (Board.initialize_store store);
  let board = room store "original" in
  let original = post store board.slug "original post" in
  armed := true;
  (match require (delete store board) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_decision_pending _ -> Alcotest.fail "expected uncertain retirement");
  (match store.deletion_state with
   | Board.Deletion_unsettled { attempt = Board.Retiring_decision _; _ } -> ()
   | Board.Deletion_unsettled { attempt = Board.Recording_decision _; _ }
   | Board.Deletion_unobserved | Board.Deletion_readable _ | Board.Deletion_pending _
   | Board.Deletion_refused _ | Board.Deletion_projection_failed _ -> Alcotest.fail "retirement uncertainty lost");
  let other = fresh base in
  let replacement = room other board.slug in
  let later = post other replacement.slug "new board's post" in
  let policy_before = bytes (Board.sub_boards_path store) and posts_before = bytes (Board.persist_path store) in
  Board.flush_dirty store;
  Alcotest.(check (option string)) "old owner cannot remove the new board" policy_before (bytes (Board.sub_boards_path store));
  Alcotest.(check (option string)) "old owner cannot replay a stale posts payload" posts_before (bytes (Board.persist_path store));
  let restarted = fresh base in
  Alcotest.(check bool) "replacement ID differs" false (board.id = replacement.id);
  ignore (require (Board.get_sub_board restarted ~sub_board_id:(Board.Sub_board_id.to_string replacement.id)));
  Alcotest.(check (option string)) "original remains unlinked" None (read restarted original).hearth;
  Alcotest.(check (option string)) "new post keeps its new board" (Some replacement.slug) (read restarted later).hearth

let () = Alcotest.run "Sub-board owned deletion recovery" ["real sources", List.map
  (fun (name, run) -> Alcotest.test_case name `Quick (with_fixture run))
  ["durable unlink keeps comments and unselected work", test_durable_unlink_and_unselected_work;
   "foreign post before decision", test_foreign_predecision_post;
   "shadowed ID preserves canonical slug winner", test_shadowed_board_does_not_unlink_winner;
   "deleted winner restores restricted shadow policy", test_deleted_winner_restores_restricted_shadow;
   "fixed IDs after known-record interruption", test_fixed_ids_after_interruption;
   "unknown decision never replays", test_unknown_decision;
   "unknown posts require fresh deletion recovery", test_unknown_posts_require_fresh_recovery;
   "pending policy refuses model reload", test_pending_policy_refuses_reload;
   "uncertain retirement preserves reused slug", test_unknown_retirement_preserves_reused_slug]]
