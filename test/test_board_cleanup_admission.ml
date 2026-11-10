open Masc

module Access = Masc_board_handlers.Board_access
module Paths = Masc_board_handlers.Board_paths
module Vote_key = Masc_board_handlers.Board_vote_key

let () = Mirage_crypto_rng_unix.use_default ()
let () = Printexc.record_backtrace true
let require = function Ok value -> value | Error error -> Alcotest.fail (Board.show_board_error error)
let loaded store = require (Board.initialize_store store); store
let fresh base = loaded (Board.create_store ~base_path:base ())
let id (post : Board.post) = Board.Post_id.to_string post.id

let old_post store ?(visibility = Board.Public) ~age ~title () =
  let lookup = Recipient_lookup.make (fun _ ->
    Ok (Some (require (Board.Agent_id.of_string "private-target")))) in
  let post = match Board.create_post store ~lookup ~author:"cleanup-owner"
      ~content:"@private-target cleanup candidate" ~title ~visibility
      ~post_kind:Board.Human_post ~ttl_hours:0 () with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error) in
  let created_at = Time_compat.now () -. age in
  let post = { post with Board.created_at; updated_at = created_at } in
  Board.with_persist_lock store (fun () -> Board.with_lock store (fun () ->
    Board.put_post store post;
    Board.invalidate_post_caches store;
    store.Board.dirty_posts <- true));
  Board.flush_dirty store;
  post

let conditions ?(no_comments = true) ?(no_votes = true) () =
  Board.cleanup_conditions ~created_before:(Time_compat.now () -. 3600.)
    ~require_no_comments:no_comments ~require_no_votes:no_votes
    ~title_pattern:(Some "cLeAnUp") ~author_pattern:(Some "ClEaNuP-OwNeR")

let delete store ?(reader = Access.Operator) conditions post =
  Board.delete_post store ~authorization:(Board.Cleanup_deletion { reader; conditions }) ~post_id:(id post)

let snapshot path = match Fs_compat.private_jsonl_snapshot_success_receipt
    (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None) with
  | Ok receipt -> receipt.value
  | Error error -> Alcotest.fail (Fs_compat.private_jsonl_transaction_error_to_string error)

let source_paths store = List.map (Paths.store_file_path store)
  [Paths.Posts; Comments; Votes; Reactions; Deletion]
let capture store = List.map (fun path -> path, snapshot path) (source_paths store)
let unchanged rows = List.iter (fun (path, (before : Fs_compat.private_jsonl_snapshot)) ->
  let after = snapshot path in
  Alcotest.(check string) "source bytes retained" before.bytes after.bytes;
  Alcotest.(check bool) "source cursor/absence retained" true
    (Fs_compat.Private_jsonl_cursor.equal before.cursor after.cursor)) rows

let present store post = Hashtbl.mem store.Board.posts (id post)
let expect_refused = function
  | Error (Board.Validation_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "ineligible candidate reached a deletion decision"
let expect_io = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "changed source unexpectedly authorized deletion"
let durable = function
  | Ok Board.Durable_deletion -> ()
  | Ok (Board.Deletion_decision_pending _ | Board.Deletion_persistence_pending _) ->
    Alcotest.fail "deletion did not become durable"
  | Error error -> Alcotest.fail (Board.show_board_error error)
let expect_timeout f = match f () with
  | Ok _ | Error _ -> Alcotest.fail "reserved cleanup cause was swallowed"
  | exception Eio.Time.Timeout -> ()

type change = Comment | Vote | Title | Author
let apply_change ?(vote_comment = false) change store post = match change with
  | Comment ->
    let comment = require (Board.add_comment store ~reader:Access.Operator
      ~lookup:Recipient_lookup.none_declared ~post_id:(id post)
      ~author:"cleanup-owner" ~content:"new discussion" ~ttl_hours:0 ()) in
    if vote_comment then ignore (require (Board.vote_comment store ~reader:Access.Operator
      ~voter:"comment-voter" ~comment_id:(Board.Comment_id.to_string comment.id) ~direction:Board.Down))
  | Vote -> ignore (require (Board.vote store ~reader:Access.Operator
      ~voter:"late-voter" ~post_id:(id post) ~direction:Board.Up))
  | Title -> ignore (require (Board.update_post_with_outcome store
      ~lookup:Recipient_lookup.none_declared ~post_id:(id post) ~editor:"cleanup-owner"
      ~content:post.body ~title:"Keep this discussion" ()))
  | Author -> ignore (require (Board.update_post_with_outcome store
      ~lookup:Recipient_lookup.none_declared ~post_id:(id post) ~editor:"cleanup-owner"
      ~content:post.body ~new_author:"new-owner" ()))

let test_selected_change change allowed base =
  let store = Board_dispatch.backend () in
  let first = old_post store ~age:7200. ~title:"Cleanup first" () in
  let second = old_post store ~age:10800. ~title:"Cleanup second" () in
  let changed = ref false in
  Board_dispatch.set_board_sse_hook (function
    | Board_dispatch.Post_changed { post_id; change = Board_dispatch.Post_deleted }
      when String.equal post_id (id first) && not !changed ->
      apply_change ~vote_comment:(allowed && change = Comment) change store second;
      changed := true
    | Post_changed _ | Board_changed | Post_created _ | Comment_added _
    | Post_voted _ | Comment_voted _ | Reaction_changed _ -> ());
  let no_comments = not (allowed && change = Comment) in
  let no_votes = not (allowed && change = Vote) in
  let result = Board_tool.handle_tool ~reader:Access.Operator
    ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
    (`Assoc ["dry_run", `Bool false; "max_age_hours", `Int 1;
      "require_no_comments", `Bool no_comments; "require_no_votes", `Bool no_votes;
      "title_pattern", `String "cLeAnUp"; "author_pattern", `String "ClEaNuP-OwNeR"]) in
  Board_dispatch.set_board_sse_hook (fun _ -> ());
  Alcotest.(check bool) "actual mutation ran after first deletion" true !changed;
  let open Yojson.Safe.Util in
  let data = Tool_result.data result in
  Alcotest.(check int) "actual durable deletion count" (if allowed then 2 else 1)
    (data |> member "durable_deletions" |> to_int);
  Alcotest.(check int) "ineligible candidate is a pre-decision refusal" (if allowed then 0 else 1)
    (data |> member "refused_deletions" |> to_int);
  Alcotest.(check int) "no unknown effects" 0 (data |> member "outcome_unknown" |> to_int);
  Board.flush_dirty store;
  let restarted = fresh base in
  Alcotest.(check bool) "first deletion survives restart" false (present restarted first);
  Alcotest.(check bool) "second follows its original conditions" (not allowed) (present restarted second);
  if not allowed then (
    let saved = Hashtbl.find restarted.Board.posts (id second) in
    match change with
    | Comment -> Alcotest.(check int) "new comment survives restart" 1 saved.reply_count
    | Vote -> Alcotest.(check int) "new vote survives restart" 1 saved.votes_up
    | Title -> Alcotest.(check string) "new title survives restart" "Keep this discussion" saved.title
    | Author -> Alcotest.(check string) "new author survives restart" "new-owner"
        (Board.Agent_id.to_string saved.author))

let test_canonical_activity change base =
  let store = Board_dispatch.backend () in
  let post = old_post store ~age:7200. ~title:"Cleanup counter lag" () in
  apply_change change store post;
  let row = List.find (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string) = id post)
    (Fs_compat.load_jsonl (Board.persist_path store)) in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "canonical parent counter still predates child append" 0
    (row |> member (match change with Comment -> "reply_count" | Vote -> "votes_up"
      | Title | Author -> Alcotest.fail "activity fixture requires a child append") |> to_int);
  let before = capture store in
  expect_refused (delete store (conditions ()) post);
  unchanged before;
  let restarted = fresh base in
  Alcotest.(check bool) "canonical child protects its parent" true (present restarted post);
  let saved = Hashtbl.find restarted.Board.posts (id post) in
  match change with
  | Comment -> Alcotest.(check int) "actual canonical comment remains" 1 saved.reply_count
  | Vote -> Alcotest.(check int) "actual canonical post vote remains" 1 saved.votes_up
  | Title | Author -> Alcotest.fail "activity fixture requires a child append"

let same_inode a b = a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino

let test_vote_readset required base =
  let seed = Board_dispatch.backend () in
  let post = old_post seed ~age:7200. ~title:"Cleanup changed vote source" () in
  let posts_path = Board.persist_path seed and votes_path = Board.vote_log_path seed in
  let before_vote = snapshot votes_path in
  let key = Vote_key.post ~post_id:post.id ~voter:(require (Board.Agent_id.of_string "foreign-voter")) in
  let suffix = Yojson.Safe.to_string (`Assoc [
    "target", `String (Vote_key.to_string key); "voter", `String "foreign-voter";
    "direction", `String "up"; "ts", `Float (Time_compat.now ())]) ^ "\n" in
  let armed = ref false and appended = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in
      Unix.close fd;
      if !armed && same_inode stat (Unix.stat posts_path) then (
        armed := false;
        match Fs_compat.private_jsonl_cursor_success_receipt
            (Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
              votes_path ~expected:before_vote suffix) with
        | Ok _ -> appended := true
        | Error error -> failwith (Fs_compat.private_jsonl_transaction_error_to_string error))) } in
  let owner = loaded (Board.create_store_with_source_io_for_testing ~base_path:base ~io:{posts=Some io} ()) in
  let marker = Paths.store_file_path owner Paths.Deletion in
  let before_marker = snapshot marker in
  armed := true;
  let outcome = delete owner (conditions ~no_votes:required ()) post in
  Alcotest.(check bool) "actual foreign vote was written between capture and guard" true !appended;
  if required then (
    expect_io outcome;
    unchanged [marker, before_marker];
    Alcotest.(check bool) "guard refusal keeps the model" true (present owner post);
    Alcotest.(check string) "foreign vote bytes retained" suffix (snapshot votes_path).bytes;
    (match owner.Board.votes_source with
     | Board.Votes_refused _ -> ()
     | Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_unsettled _ ->
       Alcotest.fail "the actual refused vote owner was not notified");
    require (Board.require_posts_source_readable owner);
    require (Board.require_comments_source_readable owner))
  else (
    (match outcome with
     | Ok (Board.Deletion_persistence_pending _) -> ()
     | Ok Board.Durable_deletion | Ok (Board.Deletion_decision_pending _) | Error _ ->
       Alcotest.fail "override should record the decision before the later leaf CAS refusal");
    Alcotest.(check bool) "unrequested vote guard does not block the original decision" false (present owner post);
    Alcotest.(check bool) "known decision marker is retained" true (Sys.file_exists marker);
    let restarted = fresh base in
    Alcotest.(check bool) "original decision completes on fresh recovery" false (present restarted post))

let test_known_marker_cleanup base =
  let seed = Board_dispatch.backend () in
  let post = old_post seed ~age:7200. ~title:"Cleanup fixed decision" () in
  let late_writer = fresh base in
  let posts_lock = Fs_compat.private_jsonl_lock_path (Board.persist_path seed) in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in Unix.close fd;
      if !armed && same_inode stat (Unix.stat posts_lock) then (
        armed := false; raise Eio.Time.Timeout)) } in
  let owner = loaded (Board.create_store_with_source_io_for_testing ~base_path:base ~io:{posts=Some io} ()) in
  let before = capture owner |> List.filter (fun (path, _) ->
    not (String.equal path (Paths.store_file_path owner Paths.Deletion))) in
  armed := true;
  expect_timeout (fun () -> delete owner (conditions ()) post);
  (match owner.Board.deletion_state with
   | Board.Deletion_pending work ->
     Alcotest.(check bool) "known marker precedes model projection" true
       (work.deletion_progress = Board.Decision_recorded)
   | Deletion_unobserved | Deletion_readable _ | Deletion_unsettled _
   | Deletion_refused _ | Deletion_projection_failed _ -> Alcotest.fail "known marker receipt was lost");
  unchanged before;
  Alcotest.(check bool) "reserved cleanup stops model removal" true (present owner post);
  let late = require (Board.add_comment late_writer ~reader:Access.Operator
    ~lookup:Recipient_lookup.none_declared ~post_id:(id post)
    ~author:"cleanup-owner" ~content:"accepted after the fixed decision" ~ttl_hours:0 ()) in
  let marker = Paths.store_file_path owner Paths.Deletion in
  let recorded = snapshot marker in
  expect_io (delete owner (conditions ()) post);
  unchanged [marker, recorded];
  let restarted = fresh base in
  Alcotest.(check bool) "recovery follows the original decision despite new activity" false (present restarted post);
  Alcotest.(check bool) "later accepted child was not in the fixed delete set" true
    (Hashtbl.mem restarted.Board.comments (Board.Comment_id.to_string late.id))

let test_unknown_marker base =
  let seed = Board_dispatch.backend () in
  let post = old_post seed ~age:7200. ~title:"Cleanup unknown marker" () in
  let armed = ref false and syncs = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed then (
      armed := false; incr syncs; raise Eio.Time.Timeout));
    close_fd = Unix.close } in
  let owner = loaded (Board.create_store_with_deletion_io_for_testing ~base_path:base ~io ()) in
  armed := true;
  expect_timeout (fun () -> delete owner (conditions ()) post);
  (match owner.Board.deletion_state with
   | Board.Deletion_unsettled { before; intended_bytes; _ } ->
     Alcotest.(check string) "original before bytes retained" "" before.decision_snapshot.bytes;
     Alcotest.(check bool) "intended original decision retained" true (String.length intended_bytes > 0)
   | Deletion_unobserved | Deletion_readable _ | Deletion_pending _
   | Deletion_refused _ | Deletion_projection_failed _ -> Alcotest.fail "actual unknown marker was not retained");
  Alcotest.(check bool) "unknown marker leaves model unchanged" true (present owner post);
  let marker = Paths.store_file_path owner Paths.Deletion in
  let unknown = snapshot marker in
  expect_io (delete owner (conditions ()) post);
  Board.flush_dirty owner;
  unchanged [marker, unknown];
  Alcotest.(check int) "ordinary retry/flush performs no marker replay" 1 !syncs;
  let restarted = fresh base in
  Alcotest.(check bool) "fresh fenced recovery completes the actual decision" false (present restarted post)

let test_direct_reader base =
  let store = Board_dispatch.backend () in
  let post = old_post store ~visibility:Board.Direct ~age:7200. ~title:"Cleanup Direct" () in
  let before = capture store in
  (match delete store ~reader:(Access.named "outsider") (conditions ()) post with
   | Error (Board.Post_not_found _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "cleanup promoted an unreadable caller");
  unchanged before;
  durable (delete store ~reader:(Access.named "private-target") (conditions ()) post);
  Alcotest.(check bool) "stored recipient retains original cleanup readership" false (present (fresh base) post)

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture run () = Eio_main.run @@ fun env ->
  let base = Filename.temp_dir "masc-board-cleanup-admission-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:(fun () ->
    Board_dispatch.set_board_sse_hook (fun _ -> ());
    Board_dispatch.reset_for_test (); Board.reset_global_for_test ();
    Fs_compat.clear_fs ();
    (match before with None -> Unix.unsetenv "MASC_BASE_PATH" | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base)
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base;
      Board.reset_global_for_test (); Board_dispatch.reset_for_test ();
      (match Board_dispatch.init_jsonl ~base_path:base ~recipient_lookup:Recipient_lookup.none_declared () with
       | Ok () -> ()
       | Error (Board_dispatch.Workspace_mismatch _ | Workspace_binding_refused _) ->
         Alcotest.fail "isolated Dispatch initialization was refused");
      run base)

let () = Alcotest.run "Board cleanup decision admission" ["feature", [
  Alcotest.test_case "new comment after selection protects the second candidate" `Quick (with_fixture (test_selected_change Comment false));
  Alcotest.test_case "new vote after selection protects the second candidate" `Quick (with_fixture (test_selected_change Vote false));
  Alcotest.test_case "new title after selection is checked again" `Quick (with_fixture (test_selected_change Title false));
  Alcotest.test_case "new author after selection is checked again" `Quick (with_fixture (test_selected_change Author false));
  Alcotest.test_case "comment override permits the newly active candidate" `Quick (with_fixture (test_selected_change Comment true));
  Alcotest.test_case "vote override permits the newly active candidate" `Quick (with_fixture (test_selected_change Vote true));
  Alcotest.test_case "canonical comments override the stale persisted parent counter" `Quick (with_fixture (test_canonical_activity Comment));
  Alcotest.test_case "canonical post votes override the stale persisted parent counter" `Quick (with_fixture (test_canonical_activity Vote));
  Alcotest.test_case "required Votes guard refuses before marker recording" `Quick (with_fixture (test_vote_readset true));
  Alcotest.test_case "unrequested Votes eligibility does not block the decision" `Quick (with_fixture (test_vote_readset false));
  Alcotest.test_case "known marker cleanup preserves fixed decision and later child" `Quick (with_fixture test_known_marker_cleanup);
  Alcotest.test_case "actual unknown marker is retained without ordinary replay" `Quick (with_fixture test_unknown_marker);
  Alcotest.test_case "cleanup retains the actual Direct reader" `Quick (with_fixture test_direct_reader)
]]
