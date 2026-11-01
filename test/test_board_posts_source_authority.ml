(** Actual posts-source admission, all-writer CAS, and effect settlement.
    Fixtures load real files and use the public Board producers. No fabricated
    load result or cursor grants write authority. *)

open Masc

module Rows = Masc_board_handlers.Board_votes_json
module Paths = Masc_board_handlers.Board_paths

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_workspace test () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "board-posts-source-" "" in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.unsetenv "MASC_BASE_PATH");
      remove_tree base)
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base;
      test (Common.masc_dir_from_base_path ~base_path:base))

let make_store workspace_masc_dir =
  Board.create_store ~workspace_masc_dir ()

let read_bytes path = In_channel.with_open_bin path In_channel.input_all
let write_bytes path bytes =
  Out_channel.with_open_bin path (fun out -> output_string out bytes)

let require_board = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let require_post = function
  | Ok post -> post
  | Error error ->
    Alcotest.fail (Board.Post_publication_failure.to_string error)

let load_posts store expected =
  match Rows.load_persisted_posts store with
  | Ok count -> Alcotest.(check int) "actual rows loaded" expected count
  | Error (path, error) ->
    Alcotest.failf "load %s: %s" path (Printexc.to_string error)

let refuse_load store =
  match Rows.load_persisted_posts store with
  | Error _ -> ()
  | Ok count -> Alcotest.failf "unavailable source was admitted (%d rows)" count

let load_comments store expected =
  match Rows.load_persisted_comments store with
  | Ok count -> Alcotest.(check int) "actual comments loaded" expected count
  | Error (path, error) ->
    Alcotest.failf "load %s: %s" path (Printexc.to_string error)

let create ?hearth store body =
  Board.create_post store ~lookup:Recipient_lookup.none_declared
    ~author:"source-writer" ~content:body ~title:"source title" ~body
    ~post_kind:Board.Human_post ~ttl_hours:0 ?hearth ()

let edit store (post : Board.post) body =
  Board.update_post_with_outcome store
    ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string post.id) ~editor:"source-writer"
    ~content:body ~title:post.title ~body ()

let current store (post : Board.post) =
  match Board.read_post store ~post_id:(Board.Post_id.to_string post.id) with
  | Ok value -> value
  | Error _ -> Alcotest.fail "the expected public post is missing"

let require_pre_effect = function
  | Ok _ -> Alcotest.fail "unadmitted create succeeded"
  | Error failure ->
    (match Board.Post_publication_failure.effect_disposition failure with
     | Failure_effect.Proven_pre_effect -> ()
     | Failure_effect.Proven_post_effect | Failure_effect.Effect_outcome_unknown ->
       Alcotest.fail "refused source did not prove create was before effect");
    Alcotest.(check bool) "no committed creation receipt" true
      (Option.is_none (Board.Post_publication_failure.committed failure))

let require_io_refusal = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "unavailable source allowed a mutation"

let readable_observation store =
  match store.Board.posts_source with
  | Board.Posts_readable { observation; _ } -> observation
  | Board.Posts_unobserved | Board.Posts_refused _ | Board.Posts_unsettled _ ->
    Alcotest.fail "the source is not readable"

let check_observed_bytes store =
  let observation = readable_observation store in
  Alcotest.(check string) "retained source is the actual complete file"
    (read_bytes (Board.persist_path store)) observation.snapshot.bytes;
  Alcotest.(check string) "source owns the captured path"
    (Board.persist_path store) observation.source_path

let reloaded workspace expected =
  let store = make_store workspace in
  load_posts store expected;
  store

let test_explicit_load_before_create workspace =
  let store = make_store workspace in
  let path = Board.persist_path store in
  require_pre_effect (create store "unobserved request");
  Alcotest.(check bool) "refused create made no payload file" false
    (Sys.file_exists path);
  Alcotest.(check int) "refused create published no row" 0
    (List.length (Board.list_posts store ()));
  load_posts store 0;
  Alcotest.(check bool) "observed Missing still has no payload" false
    (Sys.file_exists path);
  let post = require_post (create store "admitted request") in
  check_observed_bytes store;
  let fresh = reloaded workspace 1 in
  Alcotest.(check string) "only the admitted body was persisted"
    "admitted request" (current fresh post).body

let test_two_missing_observations workspace =
  let first = make_store workspace and second = make_store workspace in
  load_posts first 0;
  load_posts second 0;
  let post = require_post (create first "first actual append") in
  let before = read_bytes (Board.persist_path first) in
  require_pre_effect (create second "stale missing request");
  Alcotest.(check string) "stale peer did not append or rewrite" before
    (read_bytes (Board.persist_path first));
  Alcotest.(check int) "stale peer did not silently adopt the other writer" 0
    (List.length (Board.list_posts second ()));
  load_posts second 1;
  Alcotest.(check string) "reload projects the actual other writer first"
    post.body (current second post).body;
  let next = require_post (create second "explicitly reloaded request") in
  let fresh = reloaded workspace 2 in
  Alcotest.(check string) "reloaded authority preserved the first post"
    post.body (current fresh post).body;
  Alcotest.(check string) "reloaded authority admitted the next post"
    next.body (current fresh next).body

let tamper_same_cursor store (post : Board.post) =
  let path = Board.persist_path store in
  let before = read_bytes path in
  let tampered = { post with body = "body-bbbb" } in
  let bytes = Yojson.Safe.to_string (Board.post_to_yojson tampered) ^ "\n" in
  Alcotest.(check int) "tamper keeps the source length" (String.length before)
    (String.length bytes);
  let stat_before = Unix.stat path in
  Out_channel.with_open_gen [Open_wronly; Open_binary] 0o600 path
    (fun out -> output_string out bytes);
  let stat_after = Unix.stat path in
  Alcotest.(check (pair int int)) "tamper keeps the exact inode"
    (stat_before.Unix.st_dev, stat_before.Unix.st_ino)
    (stat_after.Unix.st_dev, stat_after.Unix.st_ino);
  Alcotest.(check int) "tamper keeps the file length"
    stat_before.Unix.st_size stat_after.Unix.st_size;
  bytes

let test_same_cursor_changed_bytes workspace =
  let store = make_store workspace in
  load_posts store 0;
  let post = require_post (create store "body-aaaa") in
  let path = Board.persist_path store in
  let bytes = tamper_same_cursor store post in
  require_io_refusal (edit store post "must not replace changed bytes");
  Alcotest.(check string) "refused CAS preserves the external bytes" bytes
    (read_bytes path);
  Alcotest.(check string) "refused edit preserves prior published memory"
    post.body (current store post).body;
  load_posts store 1;
  Alcotest.(check string) "explicit reload projects the new actual bytes"
    "body-bbbb" (current store post).body;
  ignore (require_board (edit store post "authorized after explicit reload"));
  check_observed_bytes store

let test_same_cursor_append_refused workspace =
  let store = make_store workspace in
  load_posts store 0;
  let post = require_post (create store "body-aaaa") in
  let bytes = tamper_same_cursor store post in
  require_pre_effect (create store "cannot append to unobserved changed bytes");
  Alcotest.(check string) "append compares the full source, not just its cursor"
    bytes (read_bytes (Board.persist_path store));
  Alcotest.(check string) "refused append does not adopt external content"
    post.body (current store post).body

let test_partial_then_missing workspace =
  let writer = make_store workspace in
  load_posts writer 0;
  let first = require_post (create writer "accepted before malformed row") in
  let second = require_post (create writer "accepted after first row") in
  let path = Board.persist_path writer in
  let bytes = read_bytes path ^ "{}\n" in
  write_bytes path bytes;
  let reader = make_store workspace in
  refuse_load reader;
  Alcotest.(check string) "first valid display row retained"
    first.body (current reader first).body;
  Alcotest.(check string) "second valid display row retained"
    second.body (current reader second).body;
  require_pre_effect (create reader "partial load must not append");
  require_io_refusal (edit reader first "partial load must not overwrite");
  require_io_refusal
    (Board.delete_post reader ~post_id:(Board.Post_id.to_string first.id));
  Alcotest.(check string) "partial source is not cleaned or rewritten" bytes
    (read_bytes path);
  Sys.remove path;
  refuse_load reader;
  require_pre_effect (create reader "missing does not erase partial history");
  Alcotest.(check bool) "missing after refusal never recreates a payload" false
    (Sys.file_exists path)

let test_torn_tail_is_not_recovered workspace =
  let writer = make_store workspace in
  load_posts writer 0;
  ignore (require_post (create writer "complete row before a torn tail"));
  let path = Board.persist_path writer in
  let bytes = read_bytes path ^ "{\"id\":\"unfinished" in
  write_bytes path bytes;
  let reader = make_store workspace in
  refuse_load reader;
  require_pre_effect (create reader "a normal request cannot recover a tail");
  Alcotest.(check string) "ordinary admission leaves every torn-tail byte" bytes
    (read_bytes path);
  refuse_load reader;
  Alcotest.(check string) "re-reading is not startup tail repair" bytes
    (read_bytes path)

let test_present_disappearance_is_retained workspace =
  let store = make_store workspace in
  load_posts store 0;
  let post = require_post (create store "established present source") in
  load_posts store 1;
  let path = Board.persist_path store in
  Sys.remove path;
  require_io_refusal (edit store post "cannot overwrite missing source");
  refuse_load store;
  refuse_load store;
  require_pre_effect (create store "repeated Missing is not fresh authority");
  Alcotest.(check bool) "no payload was recreated" false (Sys.file_exists path)

let test_retained_snapshot_is_stale workspace =
  let store = make_store workspace in
  load_posts store 0;
  let post = require_post (create store "before captured snapshot") in
  let snapshot = Board.with_persist_lock store (fun () ->
    Board.with_lock store (fun () -> Board.capture_posts_snapshot store)) in
  ignore (require_board (edit store post "newer actual edit"));
  let before = read_bytes (Board.persist_path store) in
  (match Board.with_persist_lock store (fun () ->
     Board.save_posts_snapshot store snapshot) with
   | Board.Posts_not_written Board.Posts_snapshot_stale -> ()
   | Board.Posts_not_written _ | Board.Posts_write_unknown _ | Board.Posts_written _ ->
     Alcotest.fail "old captured rows were not refused as stale");
  Alcotest.(check string) "stale capture never replaces the current source"
    before (read_bytes (Board.persist_path store));
  Alcotest.(check string) "stale capture preserves current published memory"
    "newer actual edit" (current store post).body;
  ignore (require_post (create store "still authorized after stale capture"));
  check_observed_bytes store

let durable_delete store (post : Board.post) =
  match Board.delete_post store ~post_id:(Board.Post_id.to_string post.id) with
  | Ok Board.Durable_deletion -> ()
  | Ok (Board.Deletion_persistence_pending detail) -> Alcotest.fail detail
  | Error error -> Alcotest.fail (Board.show_board_error error)

let test_cross_writer_projection workspace =
  let store = make_store workspace in
  load_posts store 0;
  load_comments store 0;
  let topic = require_board (Board.create_sub_board store ~slug:"source-topic"
    ~name:"Source topic" ~description:"real policy source" ~owner:"source-writer" ()) in
  let first = require_post (create ~hearth:topic.slug store "first post") in
  let second = require_post (create store "second preserved post") in
  let first_id = Board.Post_id.to_string first.id in
  ignore (require_board (edit store first "edited first post"));
  require_board (Board.set_pinned store ~post_id:first_id ~pinned:true);
  require_board (Board.set_thread_id store ~post_id:first_id ~thread_id:"source-thread");
  require_board (Board.set_closed store ~post_id:first_id ~closed_by:"source-writer"
    ~successor:(Board.Successor (Board.Post_id.to_string second.id))
    ~summary:"continued by the second post" ());
  let closed = current store first in
  Alcotest.(check bool) "close was actually published" true (Option.is_some closed.closed);
  require_board (Board.reopen store ~post_id:first_id);
  let comment = require_board (Board.add_comment store
    ~lookup:Recipient_lookup.none_declared ~post_id:first_id ~author:"source-reader"
    ~content:"persisted comment" ~ttl_hours:0 ()) in
  ignore (require_board (Board.vote store ~voter:"source-voter" ~post_id:first_id
    ~direction:Board.Up));
  ignore (require_board (Board.vote_comment store ~voter:"comment-voter"
    ~comment_id:(Board.Comment_id.to_string comment.id) ~direction:Board.Up));
  Board.flush_dirty store;
  require_board (Board.delete_sub_board store
    ~sub_board_id:(Board.Sub_board_id.to_string topic.id));
  Board.flush_dirty store;
  let order store = Board.list_posts store ()
    |> List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id) in
  let expected_order = order store in
  let fresh = reloaded workspace 2 in
  load_comments fresh 1;
  let saved = current fresh first in
  Alcotest.(check string) "edit body survives every writer" "edited first post" saved.body;
  Alcotest.(check string) "post identity survives every writer" first_id
    (Board.Post_id.to_string saved.id);
  Alcotest.(check string) "author remains bound" "source-writer"
    (Board.Agent_id.to_string saved.author);
  Alcotest.(check bool) "pin persists" true saved.pinned;
  Alcotest.(check bool) "reopen persists" true (Option.is_none saved.closed);
  Alcotest.(check (option string)) "thread persists" (Some "source-thread") saved.thread_id;
  Alcotest.(check (option string)) "sub-board removal projects its posts" None saved.hearth;
  Alcotest.(check (pair int int)) "flushed counters persist" (1, 1)
    (saved.votes_up, saved.reply_count);
  Alcotest.(check (list string)) "public feed order survives reload" expected_order (order fresh);
  let saved_comment = require_board (Board.get_comment fresh
    ~comment_id:(Board.Comment_id.to_string comment.id)) in
  Alcotest.(check (pair string int)) "comment and its vote survive reload"
    (comment.content, 1) (saved_comment.content, saved_comment.votes_up);
  Alcotest.(check string) "second post remains unchanged" second.body (current fresh second).body;
  durable_delete store first;
  let after_first_delete = reloaded workspace 1 in
  Alcotest.(check string) "first delete preserves the second row"
    second.body (current after_first_delete second).body;
  durable_delete store second;
  Alcotest.(check string) "last delete persists the empty snapshot" ""
    (read_bytes (Board.persist_path store));
  let empty = reloaded workspace 0 in
  ignore (require_post (create empty "write after a real empty snapshot"));
  check_observed_bytes empty

type cleanup_fault = Ordinary_close | Timeout_close | Allocation_close

let fault_store workspace =
  let lock_path = Fs_compat.private_jsonl_lock_path
    (Paths.posts_file ~workspace_masc_dir:workspace) in
  let close_fault = ref None and sync_fault = ref false in
  let close_failures = ref 0 and sync_failures = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        if !sync_fault then (
          sync_fault := false;
          incr sync_failures;
          raise (Failure "injected actual rewrite-parent sync")))
    ; close_fd = (fun fd ->
        let actual = Unix.fstat fd and expected = Unix.stat lock_path in
        let stable_lock = actual.Unix.st_dev = expected.Unix.st_dev
          && actual.Unix.st_ino = expected.Unix.st_ino in
        Unix.close fd;
        match stable_lock, !close_fault with
        | true, Some fault ->
          close_fault := None;
          incr close_failures;
          (match fault with
           | Ordinary_close -> raise (Failure "injected post-primary lock close")
           | Timeout_close -> raise Eio.Time.Timeout
           | Allocation_close -> raise Out_of_memory)
        | false, (Some _ | None) | true, None -> ())
    } in
  let store = Board.create_store_with_posts_io_for_testing
    ~workspace_masc_dir:workspace ~io () in
  store, close_fault, sync_fault, close_failures, sync_failures

let expect_reserved fault operation =
  match operation () with
  | () -> Alcotest.fail "reserved descriptor cleanup was swallowed"
  | exception Eio.Time.Timeout ->
    (match fault with
     | Timeout_close -> ()
     | Ordinary_close | Allocation_close -> Alcotest.fail "wrong reserved exception")
  | exception Out_of_memory ->
    (match fault with
     | Allocation_close -> ()
     | Ordinary_close | Timeout_close -> Alcotest.fail "wrong reserved exception")

let check_known_settlement store =
  match store.Board.posts_source with
  | Board.Posts_readable { settlement_diagnostic = Some _; _ } -> ()
  | Board.Posts_readable { settlement_diagnostic = None; _ }
  | Board.Posts_unobserved | Board.Posts_refused _ | Board.Posts_unsettled _ ->
    Alcotest.fail "known success lost its source or cleanup diagnostic"

let test_append_cleanup fault workspace =
  let store, armed, _, fired, _ = fault_store workspace in
  load_posts store 0;
  armed := Some fault;
  (match fault with
   | Ordinary_close -> ignore (require_post (create store "committed before close failure"))
   | Timeout_close | Allocation_close ->
     expect_reserved fault (fun () -> ignore (create store "committed before close failure")));
  Alcotest.(check int) "actual stable-lock descriptor failed once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  let post = match Board.list_posts store () with
    | [post] -> post
    | [] | _ :: _ -> Alcotest.fail "known append was not published exactly once" in
  let fresh = reloaded workspace 1 in
  Alcotest.(check string) "fresh reload sees the committed append"
    post.body (current fresh post).body;
  ignore (require_post (create store "next append without replay"));
  ignore (reloaded workspace 2);
  Alcotest.(check int) "one-shot seam is no longer armed" 1 !fired

let test_rewrite_cleanup fault workspace =
  let store, armed, _, fired, _ = fault_store workspace in
  load_posts store 0;
  let post = require_post (create store "before committed rewrite") in
  armed := Some fault;
  (match fault with
   | Ordinary_close -> ignore (require_board (edit store post "committed rewrite"))
   | Timeout_close | Allocation_close ->
     expect_reserved fault (fun () -> ignore (edit store post "committed rewrite")));
  Alcotest.(check int) "actual stable-lock descriptor failed once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  Alcotest.(check string) "known rewrite published before reserved rethrow"
    "committed rewrite" (current store post).body;
  let fresh = reloaded workspace 1 in
  Alcotest.(check string) "fresh reload sees exactly one rewritten row"
    "committed rewrite" (current fresh post).body;
  ignore (require_board (edit store post "next rewrite without replay"));
  ignore (require_post (create store "append after rewrite settlement"));
  let next = reloaded workspace 2 in
  Alcotest.(check string) "persistence mutex remains usable"
    "next rewrite without replay" (current next post).body;
  Alcotest.(check int) "cleanup injection stayed one-shot" 1 !fired

let require_unknown_parent_sync store =
  match store.Board.posts_source with
  | Board.Posts_unsettled {
      failure = Board.Posts_transaction_failed
        (Fs_compat.Rewrite_published_durability_unknown {
          failure = { operation = Fs_compat.Sync_rewrite_parent; _ }; _ }); _ } -> ()
  | Board.Posts_unobserved | Board.Posts_readable _ | Board.Posts_refused _
  | Board.Posts_unsettled _ ->
    Alcotest.fail "rename followed by parent-sync failure lost its unknown outcome"

let test_unknown_rewrite_cannot_be_read_clear workspace =
  let store, _, armed, _, fired = fault_store workspace in
  load_posts store 0;
  let post = require_post (create store "before unknown rewrite") in
  armed := true;
  require_io_refusal (edit store post "published but durability unknown");
  Alcotest.(check int) "actual post-rename parent-sync hook failed once" 1 !fired;
  require_unknown_parent_sync store;
  let bytes = read_bytes (Board.persist_path store) in
  let disk_view = reloaded workspace 1 in
  Alcotest.(check string) "rename published the new bytes, not durable proof"
    "published but durability unknown" (current disk_view post).body;
  refuse_load store;
  require_unknown_parent_sync store;
  require_pre_effect (create store "ordinary reload cannot authorize another write");
  require_io_refusal (edit store post "cannot overwrite an unsettled effect");
  Board.flush_dirty store;
  Alcotest.(check string) "unknown source cannot be overwritten or cleaned" bytes
    (read_bytes (Board.persist_path store))

let jsonl_row_count path =
  read_bytes path |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal (String.trim line) ""))
  |> List.length

let posts_identity store =
  let stats = Unix.stat (Board.persist_path store) in
  stats.Unix.st_dev, stats.Unix.st_ino

let check_posts_not_replayed store cursor identity =
  Alcotest.(check bool) "next flush retains the known posts cursor" true
    (Fs_compat.Private_jsonl_cursor.equal cursor
      (readable_observation store).snapshot.cursor);
  Alcotest.(check (pair int int)) "next flush does not replace known posts again"
    identity (posts_identity store);
  check_observed_bytes store

let test_flush_cleanup_preserves_later_work workspace =
  let store, armed, _, fired, _ = fault_store workspace in
  load_posts store 0;
  load_comments store 0;
  let post = require_post (create store "flush batch source") in
  let post_id = Board.Post_id.to_string post.id in
  let comment = require_board (Board.add_comment store
    ~lookup:Recipient_lookup.none_declared ~post_id ~author:"batch-reader"
    ~content:"comment awaiting its counter snapshot" ~ttl_hours:0 ()) in
  let comment_id = Board.Comment_id.to_string comment.id in
  List.iter (fun direction ->
    ignore (require_board (Board.vote store ~voter:"batch-voter" ~post_id ~direction));
    ignore (require_board (Board.vote_comment store ~voter:"batch-comment-voter"
      ~comment_id ~direction))) [Board.Up; Board.Down; Board.Up];
  require_board (Board.set_thread_id store ~post_id ~thread_id:"flush-batch-thread");
  let before = reloaded workspace 1 in
  load_comments before 1;
  let old_comment = require_board (Board.get_comment before ~comment_id) in
  Alcotest.(check int) "comment counter is not yet in its on-disk snapshot"
    0 old_comment.votes_up;
  let votes_path = Paths.store_file_path store Paths.Votes in
  Alcotest.(check int) "actual flips leave six append-only vote rows" 6
    (jsonl_row_count votes_path);
  armed := Some Timeout_close;
  expect_reserved Timeout_close (fun () -> Board.flush_dirty store);
  Alcotest.(check int) "posts settlement failed exactly once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  let cursor = (readable_observation store).snapshot.cursor in
  let identity = posts_identity store in
  (* A batch may have completed the remaining writes or retained their retry
     obligations. An actual second flush must finish them in either case. *)
  Board.flush_dirty store;
  check_posts_not_replayed store cursor identity;
  let fresh = reloaded workspace 1 in
  load_comments fresh 1;
  let saved_post = current fresh post in
  Alcotest.(check (pair int int)) "posts counters survive interrupted batch"
    (1, 1) (saved_post.votes_up, saved_post.reply_count);
  Alcotest.(check (option string)) "dirty thread projection was written"
    (Some "flush-batch-thread") saved_post.thread_id;
  let saved_comment = require_board (Board.get_comment fresh ~comment_id) in
  Alcotest.(check (pair string int)) "later comment snapshot was not lost"
    (comment.content, 1) (saved_comment.content, saved_comment.votes_up);
  Alcotest.(check int) "later votes compaction was not lost" 2
    (jsonl_row_count votes_path);
  Alcotest.(check int) "cleanup injection stayed one-shot" 1 !fired

let test_delete_cleanup_preserves_dependents workspace =
  let store, armed, _, fired, _ = fault_store workspace in
  load_posts store 0;
  load_comments store 0;
  let post = require_post (create store "delete batch source") in
  let post_id = Board.Post_id.to_string post.id in
  let comment = require_board (Board.add_comment store
    ~lookup:Recipient_lookup.none_declared ~post_id ~author:"delete-reader"
    ~content:"dependent comment on disk" ~ttl_hours:0 ()) in
  let comment_id = Board.Comment_id.to_string comment.id in
  ignore (require_board (Board.vote store ~voter:"delete-voter" ~post_id
    ~direction:Board.Up));
  ignore (require_board (Board.vote_comment store ~voter:"delete-comment-voter"
    ~comment_id ~direction:Board.Up));
  ignore (require_board (Board.toggle_reaction store ~target_type:Board.Reaction_post
    ~target_id:post_id ~user_id:"delete-reactor" ~emoji:"👍"));
  ignore (require_board (Board.toggle_reaction store ~target_type:Board.Reaction_comment
    ~target_id:comment_id ~user_id:"delete-comment-reactor" ~emoji:"👍"));
  Board.flush_dirty store;
  let dependents =
    [ Board.comments_path store
    ; Paths.store_file_path store Paths.Votes
    ; Board.reactions_path store ] in
  List.iter (fun path ->
    Alcotest.(check bool) "actual dependent payload exists before delete" true
      (String.length (read_bytes path) > 0)) dependents;
  armed := Some Timeout_close;
  expect_reserved Timeout_close (fun () ->
    ignore (Board.delete_post store ~post_id));
  Alcotest.(check int) "delete posts settlement failed once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  Alcotest.(check string) "known posts deletion is already on disk" ""
    (read_bytes (Board.persist_path store));
  Alcotest.(check int) "known deletion is already published" 0
    (List.length (Board.list_posts store ()));
  let cursor = (readable_observation store).snapshot.cursor in
  let identity = posts_identity store in
  Board.flush_dirty store;
  check_posts_not_replayed store cursor identity;
  List.iter (fun path ->
    Alcotest.(check string) "dependent deletion was completed or retried" ""
      (read_bytes path)) dependents;
  let fresh = reloaded workspace 0 in
  load_comments fresh 0;
  Alcotest.(check int) "fresh reload has no orphan comments" 0
    (List.length (Board.list_comments fresh ()));
  ignore (require_post (create store "next write after settled deletion"));
  ignore (reloaded workspace 1)

let test_nonwrite_cleanup_preserves_reload workspace =
  let store, armed, _, fired, _ = fault_store workspace in
  load_posts store 0;
  let post = require_post (create store "body-aaaa") in
  let bytes = tamper_same_cursor store post in
  armed := Some Timeout_close;
  expect_reserved Timeout_close (fun () ->
    ignore (create store "known stale nonwrite before cleanup"));
  Alcotest.(check int) "nonwrite cleanup failed exactly once" 1 !fired;
  (match store.Board.posts_source with
   | Board.Posts_refused {
       failure = Board.Posts_transaction_failed
         (Fs_compat.Transaction_settlement_failed {
           primary = Fs_compat.Transaction_failed
             (Fs_compat.Transaction_content_changed _); _ }); _ } -> ()
   | Board.Posts_unobserved | Board.Posts_readable _ | Board.Posts_unsettled _
   | Board.Posts_refused _ ->
     Alcotest.fail "known pre-effect mismatch was not retained as a refusal");
  Alcotest.(check string) "nonwrite and cleanup preserve actual baseline" bytes
    (read_bytes (Board.persist_path store));
  Alcotest.(check int) "failed create published no phantom row" 1
    (List.length (Board.list_posts store ()));
  Alcotest.(check string) "failed create did not adopt the tampered row"
    post.body (current store post).body;
  load_posts store 1;
  Alcotest.(check string) "healthy reload projects the actual changed row"
    "body-bbbb" (current store post).body;
  ignore (require_post (create store "new write after nonwrite cleanup"));
  check_observed_bytes store;
  ignore (reloaded workspace 2)

let test_fusion_cleanup_preserves_origin_mutex workspace =
  let store, armed, _, fired, _ = fault_store workspace in
  load_posts store 0;
  let create_once run_id =
    let origin : Board.post_origin =
      { turn_ref = Some (Ids.Turn_ref.make ~trace_id:run_id ~absolute_turn:1)
      ; source = Some "fusion"
      ; fusion_run_id = Some run_id
      ; fusion_producer = Some "source-writer" } in
    Board.create_post_once_by_fusion_run_id store ~lookup:Recipient_lookup.none_declared
      ~fusion_run_id:run_id ~author:"source-writer" ~content:("exact fusion request " ^ run_id)
      ~post_kind:Board.Human_post ~visibility:Board.Internal ~ttl_hours:0 ~origin () in
  let run_id = "b1-cleanup-original" in
  armed := Some Timeout_close;
  expect_reserved Timeout_close (fun () -> ignore (create_once run_id));
  Alcotest.(check int) "Fusion cleanup failed once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  let post = match Board.find_post_by_run_id store ~run_id with
    | Some post -> post
    | None -> Alcotest.fail "committed Fusion post lost its typed origin index" in
  let bytes = read_bytes (Board.persist_path store) in
  (match require_post (create_once run_id) with
   | Board.Post_already_present replay ->
     Alcotest.(check string) "exact Fusion replay returns the original identity"
       (Board.Post_id.to_string post.id) (Board.Post_id.to_string replay.id)
   | Board.Post_created _ -> Alcotest.fail "exact Fusion replay created another post");
  Alcotest.(check string) "exact replay adds no persisted row" bytes
    (read_bytes (Board.persist_path store));
  let next = match require_post (create_once "b1-cleanup-next") with
    | Board.Post_created creation -> creation.post
    | Board.Post_already_present _ -> Alcotest.fail "new Fusion run reused the old post" in
  let fresh = reloaded workspace 2 in
  Alcotest.(check string) "original Fusion post survives the next run"
    post.body (current fresh post).body;
  Alcotest.(check string) "new Fusion run commits after reserved cleanup"
    next.body (current fresh next).body;
  Alcotest.(check int) "Fusion cleanup remains one-shot" 1 !fired

let test_non_eio_source_inspection () =
  let base = Filename.temp_dir "board-posts-inspection-" "" in
  let workspace = Common.masc_dir_from_base_path ~base_path:base in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let post, path = Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let store = make_store workspace in
      load_posts store 0;
      require_post (create store "actual preflight row"), Board.persist_path store) in
    (* Keeper's deploy preflight can run outside an Eio main scope. Read the
       real source there through the same lower-shell entrypoint it uses. *)
    let bytes = read_bytes path in
    (match Board_core.inspect_posts_source ~workspace_masc_dir:workspace with
     | Board.Posts_complete { observation; posts = [saved]; _ } ->
       Alcotest.(check string) "preflight retains the exact stable bytes"
         bytes observation.snapshot.bytes;
       Alcotest.(check string) "preflight uses the captured canonical path"
         path observation.source_path;
       Alcotest.(check string) "preflight decodes the actual producer row"
         post.body saved.body
     | Board.Posts_complete _ | Board.Posts_partial _ | Board.Posts_unavailable _ ->
       Alcotest.fail "non-Eio inspection did not read the complete source");
    let partial = bytes ^ "{}\n" in
    write_bytes path partial;
    (match Board_core.inspect_posts_source ~workspace_masc_dir:workspace with
     | Board.Posts_partial { observation; posts = [_]; errors = [_]; _ } ->
       Alcotest.(check string) "partial preflight retains rejected-source bytes"
         partial observation.snapshot.bytes
     | Board.Posts_complete _ | Board.Posts_partial _ | Board.Posts_unavailable _ ->
       Alcotest.fail "preflight lost the actual malformed-row refusal");
    let torn = bytes ^ "{" in
    write_bytes path torn;
    (match Board_core.inspect_posts_source ~workspace_masc_dir:workspace with
     | Board.Posts_unavailable _ -> ()
     | Board.Posts_complete _ | Board.Posts_partial _ ->
       Alcotest.fail "preflight admitted a torn source");
    Alcotest.(check string) "preflight never repairs the torn source"
      torn (read_bytes path))

let () =
  let case name test = Alcotest.test_case name `Quick (with_workspace test) in
  Alcotest.run "board_posts_source_authority"
    [ "standalone inspection",
        [ Alcotest.test_case "durable preflight reads outside Eio" `Quick
            test_non_eio_source_inspection ]
    ; "source admission",
        [ case "explicit posts load precedes publication" test_explicit_load_before_create
        ; case "two Missing observations cannot auto-adopt" test_two_missing_observations
        ; case "same inode and length still require exact bytes" test_same_cursor_changed_bytes
        ; case "append also compares same-cursor source bytes" test_same_cursor_append_refused
        ; case "partial then Missing never grants empty authority" test_partial_then_missing
        ; case "ordinary reads never recover torn tails" test_torn_tail_is_not_recovered
        ; case "Present disappearance is retained" test_present_disappearance_is_retained
        ; case "retained typed snapshot cannot overwrite a newer edit" test_retained_snapshot_is_stale
        ; case "all actual writers preserve one posts source" test_cross_writer_projection ]
    ; "descriptor settlement",
        [ case "append ordinary cleanup preserves success" (test_append_cleanup Ordinary_close)
        ; case "append timeout publishes before rethrow" (test_append_cleanup Timeout_close)
        ; case "append allocation failure publishes before rethrow" (test_append_cleanup Allocation_close)
        ; case "rewrite ordinary cleanup preserves success" (test_rewrite_cleanup Ordinary_close)
        ; case "rewrite timeout publishes before rethrow" (test_rewrite_cleanup Timeout_close)
        ; case "rewrite allocation failure publishes before rethrow" (test_rewrite_cleanup Allocation_close)
        ; case "parent-sync unknown cannot be cleared by reading" test_unknown_rewrite_cannot_be_read_clear
        ; case "flush cleanup preserves all later batch work" test_flush_cleanup_preserves_later_work
        ; case "delete cleanup preserves dependent deletion" test_delete_cleanup_preserves_dependents
        ; case "known nonwrite cleanup leaves reload usable" test_nonwrite_cleanup_preserves_reload
        ; case "Fusion cleanup leaves the origin mutex usable" test_fusion_cleanup_preserves_origin_mutex ] ]
