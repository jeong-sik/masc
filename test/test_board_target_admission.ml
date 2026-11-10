open Masc

module Access = Masc_board_handlers.Board_access
module Paths = Masc_board_handlers.Board_paths

let () = Mirage_crypto_rng_unix.use_default ()
let () = Printexc.record_backtrace true
let require = function Ok value -> value | Error error -> Alcotest.fail (Board.show_board_error error)
let loaded store = require (Board.initialize_store store); store
let fresh base = loaded (Board.create_store ~base_path:base ())

let post store ?hearth ?(visibility = Board.Public) () =
  let lookup = Recipient_lookup.make (fun _ ->
    Ok (Some (require (Board.Agent_id.of_string "private-target")))) in
  match Board.create_post store ~lookup ~author:"owner" ~content:"@private-target parent"
      ~post_kind:Board.Human_post ~visibility ?hearth ~ttl_hours:0 () with
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let reply store (parent : Board.post) =
  require (Board.add_comment store ~reader:Access.Operator ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~author:"owner" ~content:"original reply" ~ttl_hours:0 ())

type mutation = Post_vote | Comment_vote | Post_reaction | Comment_reaction
let all = [Post_vote; Comment_vote; Post_reaction; Comment_reaction]

let apply kind store ~reader ~actor (parent : Board.post) (comment : Board.comment) =
  let post_id = Board.Post_id.to_string parent.id in
  let comment_id = Board.Comment_id.to_string comment.id in
  let cast result = Result.map (fun _ -> ()) result in
  let toggled result = Result.map (fun (result : Board.reaction_toggle_result) ->
    Alcotest.(check string) "receipt owns the admitted parent" post_id
      (Board.Post_id.to_string result.post_id)) result in
  match kind with
  | Post_vote -> cast (Board.vote store ~reader ~voter:actor ~post_id ~direction:Board.Up)
  | Comment_vote -> cast (Board.vote_comment store ~reader ~voter:actor ~comment_id ~direction:Board.Up)
  | Post_reaction -> toggled (Board.toggle_reaction store ~reader ~target_type:Board.Reaction_post
      ~target_id:post_id ~user_id:actor ~emoji:"👍")
  | Comment_reaction -> toggled (Board.toggle_reaction store ~reader ~target_type:Board.Reaction_comment
      ~target_id:comment_id ~user_id:actor ~emoji:"👍")

let expect_io = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "stale parent admitted a new effect"

let snapshot path =
  match Fs_compat.private_jsonl_snapshot_success_receipt
      (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None) with
  | Ok receipt -> receipt.value
  | Error error -> Alcotest.fail (Fs_compat.private_jsonl_transaction_error_to_string error)

let unchanged label (before : Fs_compat.private_jsonl_snapshot) path =
  let after = snapshot path in
  Alcotest.(check string) (label ^ " bytes") before.bytes after.bytes;
  Alcotest.(check bool) (label ^ " cursor/absence") true
    (Fs_compat.Private_jsonl_cursor.equal before.cursor after.cursor)

let leaves store = [Board.vote_log_path store; Board.reactions_path store]
let capture_leaves store = List.map (fun path -> path, snapshot path) (leaves store)
let unchanged_leaves rows = List.iter (fun (path, before) -> unchanged "leaf unchanged" before path) rows
let same_inode a b = a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino
let expect_timeout f = match f () with
  | Ok _ | Error _ -> Alcotest.fail "reserved cleanup cause was swallowed"
  | exception Eio.Time.Timeout -> ()

let counted_store base kind calls =
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> incr calls);
    close_fd = (fun fd -> incr calls; Unix.close fd) } in
  loaded (match kind with
    | Post_vote | Comment_vote -> Board.create_store_with_votes_io_for_testing ~base_path:base ~io ()
    | Post_reaction | Comment_reaction -> Board.create_store_with_reactions_io_for_testing ~base_path:base ~io ())

let interrupt_after_posts base (parent : Board.post) =
  let armed = ref false and rewrite_started = ref false in
  let path = Paths.file_path ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path:base) Paths.Posts in
  let lock = Fs_compat.private_jsonl_lock_path path in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed then rewrite_started := true);
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in Unix.close fd;
      if !armed && !rewrite_started && same_inode stat (Unix.stat lock) then (
        armed := false; raise Eio.Time.Timeout)) } in
  let owner = loaded (Board.create_store_with_source_io_for_testing ~base_path:base ~io:{posts=Some io} ()) in
  fun () ->
    armed := true;
    expect_timeout (fun () -> Board.delete_post owner ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id));
    Alcotest.(check bool) "actual Posts rewrite reached the fault" true !rewrite_started;
    Alcotest.(check string) "canonical parent has been removed" "" (Fs_compat.load_file path);
    Alcotest.(check bool) "durable deletion marker remains" true
      (Sys.file_exists (Paths.store_file_path owner Paths.Deletion));
    match owner.Board.deletion_state with
    | Board.Deletion_pending work ->
      Alcotest.(check bool) "owner retains applied prefix" true (work.deletion_progress = Board.Model_applied)
    | Deletion_unobserved | Deletion_readable _ | Deletion_unsettled _
    | Deletion_refused _ | Deletion_projection_failed _ -> Alcotest.fail "partial deletion owner was lost"

let test_partial_delete duplicate base =
  let seed = fresh base in
  let parent = post seed () in
  let comment = reply seed parent in
  let kinds = if duplicate then [Post_vote; Comment_vote] else all in
  if duplicate then List.iter (fun kind ->
    require (apply kind seed ~reader:Access.Operator ~actor:"same-voter" parent comment)) kinds;
  let attempts = List.map (fun kind ->
    let calls = ref 0 in
    let store = counted_store base kind calls in
    kind, store, calls) kinds in
  (* Every stale store and the deleting owner are initialized before the marker.
     A fresh initialize after interruption would recover the pending deletion. *)
  let interrupt = interrupt_after_posts base parent in
  let before = capture_leaves seed in
  interrupt ();
  unchanged_leaves before;
  List.iter (fun (kind, store, calls) ->
    calls := 0;
    let votes = Hashtbl.length store.Board.vote_log and reactions = Hashtbl.length store.reactions in
    expect_io (apply kind store ~reader:Access.Operator
      ~actor:(if duplicate then "same-voter" else "new-actor") parent comment);
    Alcotest.(check int) "parent refusal never invokes leaf IO" 0 !calls;
    Alcotest.(check int) "no vote publication on refusal" votes (Hashtbl.length store.vote_log);
    Alcotest.(check int) "no reaction publication on refusal" reactions (Hashtbl.length store.reactions);
    unchanged_leaves before) attempts;
  let recovered = fresh base in
  Alcotest.(check int) "fresh owner finishes deletion" 0 (Hashtbl.length recovered.posts);
  Alcotest.(check int) "recovery removes original child" 0 (Hashtbl.length recovered.comments)

let test_reader_is_not_actor base =
  let store = fresh base in
  let parent = post store ~visibility:Board.Direct () in
  let comment = reply store parent in
  List.iter (fun kind -> require (apply kind store ~reader:Access.Operator ~actor:"owner" parent comment)) all;
  let before = capture_leaves store in
  List.iter (fun kind ->
    match apply kind store ~reader:(Access.named "outsider") ~actor:"owner" parent comment with
    | Error (Board.Post_not_found _ | Board.Comment_not_found _) -> ()
    | Error error -> Alcotest.fail (Board.show_board_error error)
    | Ok _ -> Alcotest.fail "actor identity granted readership") all;
  unchanged_leaves before;
  let alias = Access.Named { name = "session-label"; addressed_by = (fun id ->
    String.equal (Board.Agent_id.to_string id) "private-target") } in
  List.iter (fun kind -> require (apply kind store ~reader:alias ~actor:"independent-actor" parent comment)) all;
  let restarted = fresh base in
  Alcotest.(check int) "authorized distinct voters remain" 4 (Hashtbl.length restarted.vote_log);
  Alcotest.(check int) "authorized distinct reactors remain" 4 (Hashtbl.length restarted.reactions)

let test_existing_closed_policy_contract base =
  let store = fresh base in
  let board = require (Board.create_sub_board store ~slug:"closed-policy" ~name:"Closed policy"
    ~description:"posting policy is not vote admission" ~owner:"owner" ~access:Board.Owner_only ()) in
  let parent = post store ~hearth:board.slug () in
  let comment = reply store parent in
  require (Board.set_closed store ~post_id:(Board.Post_id.to_string parent.id)
    ~closed_by:"owner" ~successor:Board.No_successor ~summary:"closed" ());
  let path = Board.sub_boards_path store in
  let saved = path ^ ".saved" in
  Unix.rename path saved; Unix.mkdir path 0o700;
  Alcotest.(check bool) "unrelated Policy read is unavailable" true
    (Result.is_error (Board.reload_sub_boards store));
  List.iter (fun kind -> require (apply kind store ~reader:(Access.named "outsider")
    ~actor:"outsider" parent comment)) all;
  Unix.rmdir path; Unix.rename saved path;
  let restarted = fresh base in
  Alcotest.(check int) "closed parent retains both votes" 2 (Hashtbl.length restarted.vote_log);
  Alcotest.(check int) "posting policy did not block reactions" 2 (Hashtbl.length restarted.reactions)

let test_changed_comment_dependency base =
  let seed = fresh base in
  let parent = post seed () in
  let comment = reply seed parent in
  let attempts = List.map (fun kind ->
    let calls = ref 0 in kind, counted_store base kind calls, calls) [Comment_vote; Comment_reaction] in
  let other = fresh base in
  ignore (reply other parent);
  let before = capture_leaves other in
  List.iter (fun (kind, store, calls) ->
    calls := 0;
    expect_io (apply kind store ~reader:Access.Operator ~actor:"refused" parent comment);
    Alcotest.(check int) "changed comment source prevents leaf IO" 0 !calls;
    require (Board.require_posts_source_readable store);
    Alcotest.(check bool) "actual Comments owner records refusal" true
      (Result.is_error (Board.require_comments_source_readable store));
    unchanged_leaves before) attempts

let test_known_parent_cleanup kind base =
  let seed = fresh base in
  let parent = post seed () in
  let comment = reply seed parent in
  let lock = Fs_compat.private_jsonl_lock_path (Board.persist_path seed) in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in Unix.close fd;
      if !armed && same_inode stat (Unix.stat lock) then (armed := false; raise Eio.Time.Timeout)) } in
  let store = loaded (Board.create_store_with_source_io_for_testing ~base_path:base ~io:{posts=Some io} ()) in
  armed := true;
  expect_timeout (fun () -> apply kind store ~reader:Access.Operator ~actor:"accepted" parent comment);
  (match kind, store.Board.votes_source, store.reactions_source with
   | Post_vote, Board.Votes_readable _, _ ->
     Alcotest.(check int) "known vote published before cleanup" 1 (Hashtbl.length store.vote_log)
   | Post_reaction, _, Board.Reactions_readable _ ->
     Alcotest.(check int) "known reaction published before cleanup" 1 (Hashtbl.length store.reactions)
   | (Post_vote | Comment_vote | Post_reaction | Comment_reaction),
       (Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_refused _ | Votes_unsettled _),
       (Reactions_unobserved | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ | Reactions_unsettled _) ->
     Alcotest.fail "known leaf receipt was not acknowledged before cleanup");
  let restarted = fresh base in
  let count = match kind with
    | Post_vote | Comment_vote -> Hashtbl.length restarted.vote_log
    | Post_reaction | Comment_reaction -> Hashtbl.length restarted.reactions in
  Alcotest.(check int) "known effect survives restart" 1 count

let test_duplicate_checks_vote_source base =
  let seed = fresh base in
  let parent = post seed () in
  let comment = reply seed parent in
  require (apply Post_vote seed ~reader:Access.Operator ~actor:"same-voter" parent comment);
  let stale = fresh base and other = fresh base in
  ignore (require (Board.vote other ~reader:Access.Operator ~voter:"same-voter"
    ~post_id:(Board.Post_id.to_string parent.id) ~direction:Board.Down));
  let before = capture_leaves other in
  expect_io (apply Post_vote stale ~reader:Access.Operator ~actor:"same-voter" parent comment);
  unchanged_leaves before;
  match stale.Board.votes_source with
  | Board.Votes_refused _ -> ()
  | Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_unsettled _ ->
    Alcotest.fail "read-only duplicate ignored the changed vote source"

let test_unknown_reaction_retained base =
  let seed = fresh base in
  let parent = post seed () in
  let comment = reply seed parent in
  let armed = ref false and calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> incr calls; if !armed then (
      armed := false; raise (Sys_error "reaction rename parent sync")));
    close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = loaded (Board.create_store_with_reactions_io_for_testing ~base_path:base ~io ()) in
  require (apply Post_reaction store ~reader:Access.Operator ~actor:"uncertain" parent comment);
  let accepted = snapshot (Board.reactions_path store) in
  armed := true;
  expect_io (apply Post_reaction store ~reader:Access.Operator ~actor:"uncertain" parent comment);
  Alcotest.(check bool) "actual post-rename fault reached" false !armed;
  Alcotest.(check int) "uncertain removal retains display model" 1 (Hashtbl.length store.reactions);
  (match store.reactions_source with
   | Board.Reactions_unsettled { reaction_pending; _ } ->
     Alcotest.(check string) "unknown owns before bytes" accepted.bytes
       reaction_pending.reaction_before.reaction_snapshot.bytes;
     Alcotest.(check string) "unknown owns intended removal" "" reaction_pending.reaction_intended_bytes
   | Reactions_unobserved | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ ->
     Alcotest.fail "guarded rewrite lost actual unknown effect");
  let before = !calls in
  expect_io (apply Post_reaction store ~reader:Access.Operator ~actor:"new" parent comment);
  Board.flush_dirty store;
  Alcotest.(check int) "ordinary requests do not replay unknown effect" before !calls

let test_unknown_posts_refuse_leaf_mutations base =
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed then (armed := false; raise (Sys_error "ownership sync")));
    close_fd = Unix.close } in
  let store = loaded (Board.create_store_with_source_io_for_testing ~base_path:base ~io:{posts=Some io} ()) in
  let parent = post store () in
  let comment = reply store parent in
  armed := true;
  expect_io (Board.update_post_with_outcome store ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~editor:"owner" ~content:parent.body ~new_author:"next-owner" ());
  (match store.posts_source with
   | Board.Posts_unsettled _ -> ()
   | Posts_unobserved | Posts_readable _ | Posts_refused _ ->
     Alcotest.fail "real ownership sync failure lost its unknown source");
  let before = capture_leaves store in
  List.iter (fun kind -> expect_io (apply kind store ~reader:Access.Operator ~actor:"refused" parent comment)) all;
  unchanged_leaves before;
  Alcotest.(check int) "stale model published no vote" 0 (Hashtbl.length store.vote_log);
  Alcotest.(check int) "stale model published no reaction" 0 (Hashtbl.length store.reactions)

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture run () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "masc-board-target-admission-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Fs_compat.clear_fs ();
    (match before with None -> Unix.unsetenv "MASC_BASE_PATH" | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base; run base)

let () = Alcotest.run "Board canonical target admission" ["feature", [
  Alcotest.test_case "partial deletion refuses four new mutations before leaf IO" `Quick (with_fixture (test_partial_delete false));
  Alcotest.test_case "partial deletion is checked before duplicate post/comment votes" `Quick (with_fixture (test_partial_delete true));
  Alcotest.test_case "actual reader is independent of actor including aliases" `Quick (with_fixture test_reader_is_not_actor);
  Alcotest.test_case "closed and posting policy contracts remain separate" `Quick (with_fixture test_existing_closed_policy_contract);
  Alcotest.test_case "comment dependency refusal updates only its actual owner" `Quick (with_fixture test_changed_comment_dependency);
  Alcotest.test_case "known vote survives parent cleanup cause" `Quick (with_fixture (test_known_parent_cleanup Post_vote));
  Alcotest.test_case "known reaction survives parent cleanup cause" `Quick (with_fixture (test_known_parent_cleanup Post_reaction));
  Alcotest.test_case "duplicate validates the actual vote source" `Quick (with_fixture test_duplicate_checks_vote_source);
  Alcotest.test_case "guarded unknown reaction retains evidence without replay" `Quick (with_fixture test_unknown_reaction_retained);
  Alcotest.test_case "unknown posts refuse all four vote and reaction mutations" `Quick (with_fixture test_unknown_posts_refuse_leaf_mutations)
]]
