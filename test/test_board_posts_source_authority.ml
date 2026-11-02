(** Actual posts-source admission, all-writer CAS, and effect settlement.
    Fixtures load real files and use the public Board producers. No fabricated
    load result or cursor grants write authority. *)

open Masc

module Rows = Masc_board_handlers.Board_votes_json
module Paths = Masc_board_handlers.Board_paths
module Preparation = Masc_test_deps.Board_test_preparation

let prepare base_path = Preparation.prepare ~base_path ~action:Preparation.Bootstrap

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
      test base (Common.masc_dir_from_base_path ~base_path:base))

let make_store base_path =
  Board.create_store ~base_path:base_path ()

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
  | Board.Posts_unobserved | Board.Posts_guard_observed _ | Board.Posts_refused _ | Board.Posts_unsettled _ ->
    Alcotest.fail "the source is not readable"

let check_observed_bytes store =
  let observation = readable_observation store in
  Alcotest.(check string) "retained source is the actual complete file"
    (read_bytes (Board.persist_path store)) observation.snapshot.bytes;
  Alcotest.(check string) "source owns the captured path"
    (Board.persist_path store) observation.source_path

let reloaded base_path expected =
  let store = make_store base_path in
  load_posts store expected;
  store

let test_explicit_load_before_create base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
  let path = Board.persist_path store in
  let initialized = read_bytes path in
  require_pre_effect (create store "unobserved request");
  Alcotest.(check string) "refused create preserves initialized payload" initialized
    (read_bytes path);
  Alcotest.(check int) "refused create published no row" 0
    (List.length (Board.list_posts store ()));
  load_posts store 0;
  Alcotest.(check string) "explicit load preserves actual initialized empty bytes" initialized
    (read_bytes path);
  let post = require_post (create store "admitted request") in
  check_observed_bytes store;
  let fresh = reloaded base_path 1 in
  Alcotest.(check string) "only the admitted body was persisted"
    "admitted request" (current fresh post).body

let test_failed_root_capture_stays_refused base_path _workspace =
  let missing = Filename.concat base_path "not-created" in
  let store = make_store missing in
  refuse_load store;
  require_pre_effect (create store "missing root has no publication authority");
  require_io_refusal (Board.create_sub_board store ~slug:"no-root" ~name:"No root"
    ~description:"must not create a root" ~owner:"source-writer" ());
  Alcotest.(check bool) "failed capture creates no BasePath" false (Sys.file_exists missing);
  Unix.mkdir missing 0o700;
  refuse_load store;
  Alcotest.(check bool) "later root creation cannot heal this capture" false
    (Sys.file_exists (Common.masc_dir_from_base_path ~base_path:missing));
  prepare missing;
  let fresh = reloaded missing 0 in
  ignore (require_post (create fresh "new explicit capture can use the prepared root"))

let test_directory_replacement_stays_refused ~replace_root base_path workspace =
  prepare base_path;
  let store = make_store base_path in
  load_posts store 0;
  let original_post = require_post (create store "actual Present source before replacement") in
  let original = if replace_root then base_path else workspace in
  let backup = original ^ ".captured-backup" in
  Unix.rename original backup;
  Unix.mkdir original 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree original; Unix.rename backup original)
    (fun () ->
      refuse_load store;
      require_pre_effect (create store "replacement directory cannot replace authority");
      (match Rows.load_persisted_comments store with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "auxiliary load accepted a replacement directory");
      require_io_refusal (Board.create_sub_board store ~slug:"replaced" ~name:"Replaced"
        ~description:"must stay unwritten" ~owner:"source-writer" ());
      Alcotest.(check int) "refused reads and writers leave replacement empty" 0
        (Array.length (Sys.readdir original)));
  load_posts store 1;
  Alcotest.(check string) "restored source retains the original actual post"
    original_post.body (current store original_post).body;
  ignore (require_post (create store "restored physical identity remains usable"))

let test_sub_board_only_retains_initialized_directory base_path workspace =
  prepare base_path;
  let store = make_store base_path in
  let create_topic slug = Board.create_sub_board store ~slug ~name:slug
      ~description:"actual sub-board-only publication" ~owner:"source-writer" () in
  ignore (require_board (create_topic "first"));
  (match store.Board.posts_source with
   | Board.Posts_guard_observed _ -> ()
   | Posts_unobserved | Posts_readable _ | Posts_refused _ | Posts_unsettled _ ->
     Alcotest.fail "sub-board-only fixture must not manufacture a posts observation");
  require_io_refusal (Board.with_persist_lock store
    (fun () -> Board.require_posts_source_readable store));
  require_pre_effect (create store "guard alone never authorizes posts");
  let path = Board.sub_boards_path store in
  let original_bytes = read_bytes path in
  let backup = workspace ^ ".sub-board-backup" in
  Unix.rename workspace backup;
  Unix.mkdir workspace 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree workspace; Unix.rename backup workspace)
    (fun () ->
      require_io_refusal (create_topic "second");
      Alcotest.(check int) "replacement remains empty without posts loading" 0
        (Array.length (Sys.readdir workspace));
      Alcotest.(check int) "refused sub-board was not published in memory" 1
        (List.length (Board.list_sub_boards store));
      Alcotest.(check string) "refused publication preserves the original actual rows"
        original_bytes (read_bytes (Filename.concat backup (Filename.basename path))));
  ignore (require_board (create_topic "second"));
  Alcotest.(check int) "restoring the actual directory permits a new publication" 2
    (List.length (Board.list_sub_boards store));
  let slugs = read_bytes path |> String.split_on_char '\n'
    |> List.filter (fun line -> not (String.equal line ""))
    |> List.map (fun line -> Yojson.Safe.(Util.(from_string line |> member "slug" |> to_string)))
    |> List.sort String.compare in
  Alcotest.(check (list string)) "both actual sub-board rows survive restoration"
    ["first"; "second"] slugs

let test_base_path_alias base_path _workspace =
  prepare base_path;
  let alias = Filename.concat base_path "root-alias" in
  Unix.symlink base_path alias;
  Fun.protect ~finally:(fun () -> Unix.unlink alias) (fun () ->
    let store = reloaded alias 0 in
    let post = require_post (create store "physical BasePath alias is allowed") in
    let fresh = reloaded base_path 1 in
    Alcotest.(check string) "alias and canonical BasePath share the real source"
      post.body (current fresh post).body)

let test_two_empty_present_observations base_path _workspace =
  prepare base_path;
  let first = make_store base_path and second = make_store base_path in
  load_posts first 0;
  load_posts second 0;
  let post = require_post (create first "first actual append") in
  let before = read_bytes (Board.persist_path first) in
  require_pre_effect (create second "stale empty Present request");
  Alcotest.(check string) "stale peer did not append or rewrite" before
    (read_bytes (Board.persist_path first));
  Alcotest.(check int) "stale peer did not silently adopt the other writer" 0
    (List.length (Board.list_posts second ()));
  load_posts second 1;
  Alcotest.(check string) "reload projects the actual other writer first"
    post.body (current second post).body;
  let next = require_post (create second "explicitly reloaded request") in
  let fresh = reloaded base_path 2 in
  Alcotest.(check string) "reloaded authority preserved the first post"
    post.body (current fresh post).body;
  Alcotest.(check string) "reloaded authority admitted the next post"
    next.body (current fresh next).body

let with_dangling_posts store test =
  let path = Board.persist_path store in
  let backup = path ^ ".original-source" in
  let target = Filename.concat (Filename.dirname path) "absent-posts-target.jsonl" in
  Unix.rename path backup;
  Unix.symlink target path;
  let binding = Unix.lstat path in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists backup then (
        (match Unix.lstat path with
         | _ -> Unix.unlink path
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
        Unix.rename backup path))
    (fun () -> test ~path ~target ~binding ~backup)

let check_dangling_posts ~path ~target ~binding =
  let current = Unix.lstat path in
  Alcotest.(check bool) "actual dangling source remains a symlink" true
    (current.Unix.st_kind = Unix.S_LNK);
  Alcotest.(check (pair int int)) "source link identity is preserved"
    (binding.Unix.st_dev, binding.Unix.st_ino) (current.Unix.st_dev, current.Unix.st_ino);
  Alcotest.(check string) "source link target is preserved" target (Unix.readlink path);
  (match Unix.lstat target with
   | _ -> Alcotest.fail "the absent external target gained a directory entry"
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  Alcotest.(check bool) "no rewrite stage remains" false
    (Sys.readdir (Filename.dirname path) |> Array.exists (fun name ->
       String.starts_with ~prefix:".private_jsonl_" name))

let test_present_then_dangling_source base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
  load_posts store 0;
  with_dangling_posts store (fun ~path ~target ~binding ~backup ->
    require_pre_effect (create store "must not replace an existing dangling source");
    check_dangling_posts ~path ~target ~binding;
    Alcotest.(check int) "refused source published no in-memory post" 0
      (List.length (Board.list_posts store ()));
    (* Restore the actual original Present leaf and cursor before retry. *)
    Unix.unlink path;
    Unix.rename backup path;
    let post = require_post (create store "retry after actual alias removal") in
    check_observed_bytes store;
    let fresh = reloaded base_path 1 in
    Alcotest.(check string) "only the later explicit publication survives"
      post.body (current fresh post).body)

let test_initial_dangling_source base_path workspace =
  prepare base_path;
  let store = make_store base_path in
  Fs_compat.mkdir_p workspace;
  with_dangling_posts store (fun ~path ~target ~binding ~backup:_ ->
    refuse_load store;
    (match store.Board.posts_source with
     | Board.Posts_refused {
         failure = Posts_transaction_failed
           (Fs_compat.Unexpected_transaction_file_kind Unix.S_LNK); _ } -> ()
     | _ -> Alcotest.fail "dangling source did not retain its actual typed refusal");
    require_pre_effect (create store "an existing alias is not initial absence");
    check_dangling_posts ~path ~target ~binding)

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

let test_same_cursor_changed_bytes base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
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

let test_same_cursor_append_refused base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
  load_posts store 0;
  let post = require_post (create store "body-aaaa") in
  let bytes = tamper_same_cursor store post in
  require_pre_effect (create store "cannot append to unobserved changed bytes");
  Alcotest.(check string) "append compares the full source, not just its cursor"
    bytes (read_bytes (Board.persist_path store));
  Alcotest.(check string) "refused append does not adopt external content"
    post.body (current store post).body

let test_partial_then_missing base_path _workspace =
  prepare base_path;
  let writer = make_store base_path in
  load_posts writer 0;
  let first = require_post (create writer "accepted before malformed row") in
  let second = require_post (create writer "accepted after first row") in
  let path = Board.persist_path writer in
  let bytes = read_bytes path ^ "{}\n" in
  write_bytes path bytes;
  let reader = make_store base_path in
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

let test_torn_tail_is_not_recovered base_path _workspace =
  prepare base_path;
  let writer = make_store base_path in
  load_posts writer 0;
  ignore (require_post (create writer "complete row before a torn tail"));
  let path = Board.persist_path writer in
  let bytes = read_bytes path ^ "{\"id\":\"unfinished" in
  write_bytes path bytes;
  let reader = make_store base_path in
  refuse_load reader;
  require_pre_effect (create reader "a normal request cannot recover a tail");
  Alcotest.(check string) "ordinary admission leaves every torn-tail byte" bytes
    (read_bytes path);
  refuse_load reader;
  Alcotest.(check string) "re-reading is not startup tail repair" bytes
    (read_bytes path)

let test_present_disappearance_is_retained base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
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

let test_retained_snapshot_is_stale base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
  load_posts store 0;
  let post = require_post (create store "before captured snapshot") in
  let snapshot = Board.with_persist_lock store (fun () ->
    Board.with_lock store (fun () -> Board.capture_posts_snapshot store)) in
  ignore (require_board (edit store post "newer actual edit"));
  let before = read_bytes (Board.persist_path store) in
  (match Board.with_persist_lock store (fun () ->
     Board.save_posts_snapshot store snapshot) with
   | Board.Posts_not_written { failure = Board.Posts_snapshot_stale; _ } -> ()
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

let test_cross_writer_projection base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
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
  let fresh = reloaded base_path 2 in
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
  let after_first_delete = reloaded base_path 1 in
  Alcotest.(check string) "first delete preserves the second row"
    second.body (current after_first_delete second).body;
  durable_delete store second;
  Alcotest.(check string) "last delete persists the empty snapshot" ""
    (read_bytes (Board.persist_path store));
  let empty = reloaded base_path 0 in
  ignore (require_post (create empty "write after a real empty snapshot"));
  check_observed_bytes empty

type cleanup_fault = Ordinary_close | Timeout_close | Allocation_close

let fault_store base_path =
  prepare base_path;
  let workspace = Common.masc_dir_from_base_path ~base_path in
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
  let store = Board.create_store_with_source_io_for_testing
    ~base_path ~io:{ guard = None; posts = Some io } () in
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
  | Board.Posts_readable { diagnostics; _ } when List.exists (function
      | Board.File_diagnostic { file = Posts_file;
          error = Fs_compat.Transaction_settlement_failed {
            primary = Fs_compat.Transaction_succeeded _; _ } } -> true
      | File_diagnostic _ | Workspace_diagnostic _ | Raised_diagnostic _ -> false)
      diagnostics -> ()
  | Board.Posts_readable _ | Posts_guard_observed _ | Posts_unobserved
  | Posts_refused _ | Posts_unsettled _ ->
    Alcotest.fail "known success lost its actual posts cleanup diagnostic"

let test_missing_read_preserves_reserved_cleanup base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
  load_posts store 0;
  ignore (require_post (create store "actual Present before disappearance"));
  Unix.unlink (Board.persist_path store);
  armed := Some Timeout_close;
  expect_reserved Timeout_close (fun () -> ignore (Rows.load_persisted_posts store));
  Alcotest.(check int) "Missing read settled the actual failing descriptor" 1 !fired;
  (match store.Board.posts_source with
   | Board.Posts_refused {
       last_observed = Posts_observed _; failure = Posts_missing; diagnostics } ->
     Alcotest.(check bool) "actual Missing read retains reserved posts cleanup" true
       (List.exists (function
          | Board.File_diagnostic { file = Posts_file;
              error = Fs_compat.Transaction_settlement_failed _ } -> true
          | File_diagnostic _ | Workspace_diagnostic _ | Raised_diagnostic _ -> false)
          diagnostics)
   | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ | Posts_unsettled _ ->
     Alcotest.fail "Missing refusal lost the actual read cleanup diagnostic");
  require_io_refusal (Board.with_persist_lock store
    (fun () -> Board.require_posts_source_readable store));
  Alcotest.(check bool) "reserved read refusal does not recreate payload" false
    (Sys.file_exists (Board.persist_path store))

let test_append_cleanup fault base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
  load_posts store 0;
  let before_errors = Board.persist_error_count () in
  armed := Some fault;
  (match fault with
   | Ordinary_close -> ignore (require_post (create store "committed before close failure"))
   | Timeout_close | Allocation_close ->
     expect_reserved fault (fun () -> ignore (create store "committed before close failure")));
  Alcotest.(check int) "known append counts its actual cleanup once"
    (before_errors + 1) (Board.persist_error_count ());
  Alcotest.(check int) "actual stable-lock descriptor failed once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  let post = match Board.list_posts store () with
    | [post] -> post
    | [] | _ :: _ -> Alcotest.fail "known append was not published exactly once" in
  let fresh = reloaded base_path 1 in
  Alcotest.(check string) "fresh reload sees the committed append"
    post.body (current fresh post).body;
  ignore (require_post (create store "next append without replay"));
  ignore (reloaded base_path 2);
  Alcotest.(check int) "one-shot seam is no longer armed" 1 !fired

let test_rewrite_cleanup fault base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
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
  let fresh = reloaded base_path 1 in
  Alcotest.(check string) "fresh reload sees exactly one rewritten row"
    "committed rewrite" (current fresh post).body;
  ignore (require_board (edit store post "next rewrite without replay"));
  ignore (require_post (create store "append after rewrite settlement"));
  let next = reloaded base_path 2 in
  Alcotest.(check string) "persistence mutex remains usable"
    "next rewrite without replay" (current next post).body;
  Alcotest.(check int) "cleanup injection stayed one-shot" 1 !fired

let require_unknown_parent_sync store =
  match store.Board.posts_source with
  | Board.Posts_unsettled {
      failure = Board.Posts_transaction_failed
        (Fs_compat.Rewrite_published_durability_unknown {
          failure = { operation = Fs_compat.Sync_rewrite_parent; _ }; _ }); _ } -> ()
  | Board.Posts_unobserved | Board.Posts_guard_observed _ | Board.Posts_readable _ | Board.Posts_refused _
  | Board.Posts_unsettled _ ->
    Alcotest.fail "rename followed by parent-sync failure lost its unknown outcome"

let test_unknown_rewrite_cannot_be_read_clear base_path _workspace =
  let store, _, armed, _, fired = fault_store base_path in
  load_posts store 0;
  let post = require_post (create store "before unknown rewrite") in
  armed := true;
  require_io_refusal (edit store post "published but durability unknown");
  Alcotest.(check int) "actual post-rename parent-sync hook failed once" 1 !fired;
  require_unknown_parent_sync store;
  let bytes = read_bytes (Board.persist_path store) in
  let disk_view = reloaded base_path 1 in
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

let test_flush_cleanup_preserves_later_work base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
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
  let before = reloaded base_path 1 in
  load_comments before 1;
  let old_comment = require_board (Board.get_comment before ~comment_id) in
  Alcotest.(check int) "comment counter is not yet in its on-disk snapshot"
    0 old_comment.votes_up;
  let votes_path = Paths.store_file_path store Paths.Votes in
  Alcotest.(check int) "actual flips leave six append-only vote rows" 6
    (jsonl_row_count votes_path);
  let comments_before = read_bytes (Board.comments_path store) in
  armed := Some Timeout_close;
  expect_reserved Timeout_close (fun () -> Board.flush_dirty store);
  Alcotest.(check int) "posts settlement failed exactly once" 1 !fired;
  check_known_settlement store;
  check_observed_bytes store;
  let known_posts = (readable_observation store).snapshot.bytes in
  Alcotest.(check string) "reserved posts cleanup stops before the comment snapshot"
    comments_before (read_bytes (Board.comments_path store));
  Alcotest.(check int) "reserved posts cleanup stops before votes compaction" 6
    (jsonl_row_count votes_path);
  (* Pending ledgers use the existing posts retry group. A separate retry may
     exact-CAS rewrite the known posts bytes while completing that work. *)
  Board.flush_dirty store;
  check_observed_bytes store;
  Alcotest.(check string) "separate grouped retry preserves exact known post bytes"
    known_posts (read_bytes (Board.persist_path store));
  Alcotest.(check (list string)) "retry neither duplicates nor recreates a post"
    [post_id] (List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id)
      (Board.list_posts store ()));
  let fresh = reloaded base_path 1 in
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

let test_delete_cleanup_preserves_dependents base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
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
  let dependent_bytes = List.map (fun path -> path, read_bytes path) dependents in
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
  List.iter (fun (path, bytes) ->
    Alcotest.(check string) "reserved delete settlement stops all later dependent writes"
      bytes (read_bytes path)) dependent_bytes;
  Board.flush_dirty store;
  check_observed_bytes store;
  Alcotest.(check string) "separate grouped retry preserves the exact deleted posts state" ""
    (read_bytes (Board.persist_path store));
  Alcotest.(check int) "separate retry does not resurrect the deleted model" 0
    (List.length (Board.list_posts store ()));
  List.iter (fun path ->
    Alcotest.(check string) "dependent deletion was completed or retried" ""
      (read_bytes path)) dependents;
  let fresh = reloaded base_path 0 in
  load_comments fresh 0;
  Alcotest.(check int) "fresh reload has no orphan comments" 0
    (List.length (Board.list_comments fresh ()));
  ignore (require_post (create store "next write after settled deletion"));
  ignore (reloaded base_path 1)

let test_nonwrite_cleanup_preserves_reload base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
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
   | Board.Posts_unobserved | Board.Posts_guard_observed _ | Board.Posts_readable _ | Board.Posts_unsettled _
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
  ignore (reloaded base_path 2)

let create_fusion_once store run_id =
  let origin : Board.post_origin =
    { turn_ref = Some (Ids.Turn_ref.make ~trace_id:run_id ~absolute_turn:1)
    ; source = Some "fusion"
    ; fusion_run_id = Some run_id
    ; fusion_producer = Some "source-writer" } in
  Board.create_post_once_by_fusion_run_id store ~lookup:Recipient_lookup.none_declared
    ~fusion_run_id:run_id ~author:"source-writer" ~content:("exact fusion request " ^ run_id)
    ~post_kind:Board.Human_post ~visibility:Board.Internal ~ttl_hours:0 ~origin ()

let test_fusion_cleanup_preserves_origin_mutex base_path _workspace =
  let store, armed, _, fired, _ = fault_store base_path in
  load_posts store 0;
  let create_once = create_fusion_once store in
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
  let fresh = reloaded base_path 2 in
  Alcotest.(check string) "original Fusion post survives the next run"
    post.body (current fresh post).body;
  Alcotest.(check string) "new Fusion run commits after reserved cleanup"
    next.body (current fresh next).body;
  Alcotest.(check int) "Fusion cleanup remains one-shot" 1 !fired

let guard_path store = Paths.posts_initialization_guard_file
    ~workspace_masc_dir:(Board.workspace_masc_dir store)

let retained_guard store =
  let from_history = function
    | Board.Guard_observed initialization -> initialization
    | Posts_observed observation -> observation.initialization
    | No_initialization -> Alcotest.fail "accepted initialization history was lost" in
  match store.Board.posts_source with
  | Board.Posts_guard_observed { initialization; _ } -> initialization
  | Posts_readable { observation; _ } -> observation.initialization
  | Posts_refused { last_observed; _ } | Posts_unsettled { last_observed; _ } ->
    from_history last_observed
  | Posts_unobserved -> Alcotest.fail "no guard has been observed"

let change_guard_generation bytes =
  let json = Yojson.Safe.from_string bytes in
  match json with
  | `Assoc fields ->
    let old = Yojson.Safe.Util.(json |> member "generation" |> to_string) in
    let next = if String.equal old (String.make 32 '0') then String.make 32 '1'
      else String.make 32 '0' in
    `Assoc (List.map (function
      | "generation", _ -> "generation", `String next
      | field -> field) fields)
    |> Yojson.Safe.to_string |> fun row -> row ^ "\n"
  | _ -> Alcotest.fail "offline preparation did not create an object guard"

let test_uninitialized_rows_remain_display_only base_path _workspace =
  prepare base_path;
  let writer = reloaded base_path 0 in
  let post = require_post (create writer "raw complete display row") in
  let path = Board.persist_path writer in
  let complete = read_bytes path in
  let second = require_post (create writer "next raw row before damage") in
  let third = require_post (create writer "next raw row after damage") in
  let fourth = require_post (create writer "later complete display replacement") in
  let wire post = Yojson.Safe.to_string (Board.post_to_yojson post) ^ "\n" in
  Unix.unlink (guard_path writer);
  write_bytes path complete;
  let reader = make_store base_path in
  refuse_load reader;
  Alcotest.(check string) "complete raw rows remain visible" post.body
    (current reader post).body;
  let assert_no_authority () =
    (match reader.Board.posts_source with
     | Board.Posts_refused { last_observed = No_initialization;
         failure = Posts_guard_missing; _ } -> ()
     | _ -> Alcotest.fail "display snapshot became accepted initialization history");
    require_pre_effect (create reader "raw display cannot authorize append");
    require_io_refusal (edit reader post "raw display cannot authorize replacement") in
  assert_no_authority ();
  let partial = wire second ^ "{}\n" ^ wire third in
  write_bytes path partial;
  refuse_load reader;
  Alcotest.(check string) "partial display retains a previously displayed absent row" post.body
    (current reader post).body;
  List.iter (fun (post : Board.post) ->
    Alcotest.(check string) "partial display merges rows on both sides of damage" post.body
      (current reader post).body) [second; third];
  assert_no_authority ();
  Alcotest.(check string) "display does not clean malformed rows" partial (read_bytes path);
  write_bytes path (wire fourth);
  refuse_load reader;
  Alcotest.(check string) "complete unadmitted display replaces old rows" fourth.body
    (current reader fourth).body;
  Alcotest.(check int) "complete display does not retain stale partial memory" 1
    (List.length (Board.list_posts reader ()));
  Alcotest.(check bool) "ordinary read never bootstraps a guard" false
    (Sys.file_exists (guard_path reader))

let test_generation_before_first_posts_admission base_path _workspace =
  prepare base_path;
  let store = make_store base_path in
  let path = Board.persist_path store and guard = guard_path store in
  let original = read_bytes guard in
  Unix.unlink path;
  refuse_load store;
  (match store.Board.posts_source with
   | Board.Posts_refused { last_observed = Guard_observed _;
       failure = Posts_missing; _ } -> ()
   | _ -> Alcotest.fail "valid guard was not retained before first posts Missing");
  Alcotest.(check string) "guard history uses genuine observed bytes" original
    (retained_guard store).snapshot.bytes;
  write_bytes guard (change_guard_generation original);
  write_bytes path "";
  List.iter (fun () ->
    refuse_load store;
    (match store.Board.posts_source with
     | Board.Posts_refused { failure = Posts_guard_changed; _ } -> ()
     | _ -> Alcotest.fail "changed generation was admitted through a refused reload");
    Alcotest.(check string) "repeated reload retains the original generation" original
      (retained_guard store).snapshot.bytes) [(); ()];
  require_pre_effect (create store "replacement generation cannot authorize posts");
  let before_errors = Board.persist_error_count () in
  require_io_refusal (Board.create_sub_board store ~slug:"foreign-generation"
    ~name:"Foreign generation" ~description:"must remain absent" ~owner:"source-writer" ());
  Alcotest.(check int) "auxiliary refusal is recorded once" (before_errors + 1)
    (Board.persist_error_count ());
  Alcotest.(check bool) "refused auxiliary writer creates no payload" false
    (Sys.file_exists (Board.sub_boards_path store));
  write_bytes guard original;
  load_posts store 0;
  ignore (require_post (create store "restored original initialization can be explicitly loaded"))

let test_invalid_guard_live_reads base_path _workspace =
  prepare base_path;
  let writer = reloaded base_path 0 in
  let post = require_post (create writer "display survives rejected guard") in
  let guard = guard_path writer in
  let original = read_bytes guard and posts = read_bytes (Board.persist_path writer) in
  let cases =
    [ "torn", String.sub original 0 (String.length original - 1)
    ; "two physical rows", original ^ original
    ; "extra blank physical row", original ^ "\n"
    ; "unsupported schema",
      "{\"schema\":\"masc.unknown.v1\",\"generation\":\"0123456789abcdef0123456789abcdef\"}\n" ] in
  Fun.protect ~finally:(fun () -> write_bytes guard original) (fun () ->
    List.iter (fun (label, bytes) ->
      write_bytes guard bytes;
      let reader = make_store base_path in
      refuse_load reader;
      Alcotest.(check string) (label ^ ": actual display is retained") post.body
        (current reader post).body;
      require_pre_effect (create reader "invalid guard cannot authorize posts");
      require_io_refusal (Board.create_sub_board reader ~slug:"invalid-guard"
        ~name:"Invalid guard" ~description:"must remain absent" ~owner:"source-writer" ());
      Alcotest.(check string) (label ^ ": guard is not repaired") bytes (read_bytes guard);
      Alcotest.(check string) (label ^ ": posts stay byte-identical") posts
        (read_bytes (Board.persist_path reader))) cases);
  let backup = guard ^ ".guard-target" in
  Unix.rename guard backup;
  Unix.symlink backup guard;
  Fun.protect ~finally:(fun () -> Unix.unlink guard; Unix.rename backup guard) (fun () ->
    let reader = make_store base_path in
    refuse_load reader;
    require_pre_effect (create reader "a guard alias is not a unique regular source");
    Alcotest.(check string) "live guard rejection preserves the actual alias" backup
      (Unix.readlink guard);
    Alcotest.(check string) "aliased guard target is not changed" original (read_bytes backup);
    Alcotest.(check string) "aliased guard does not change posts" posts
      (read_bytes (Board.persist_path reader)))

let test_guard_bytes_and_replacement base_path _workspace =
  prepare base_path;
  let store = reloaded base_path 0 in
  let post = require_post (create store "snapshot before guard replacement") in
  let candidate = Board.with_persist_lock store (fun () ->
    Board.with_lock store (fun () -> Board.capture_posts_snapshot store)) in
  let guard = guard_path store in
  let original = read_bytes guard in
  let old = Unix.stat guard and backup = guard ^ ".original-guard" in
  Unix.rename guard backup;
  Fun.protect ~finally:(fun () -> Unix.unlink backup) (fun () ->
    write_bytes guard original;
    let replacement = Unix.stat guard in
    Alcotest.(check bool) "equal bytes genuinely have a different inode" true
      (old.Unix.st_ino <> replacement.Unix.st_ino);
    let outcome = Board.with_persist_lock store (fun () ->
      let outcome = Board.save_posts_snapshot store candidate in
      require_board (Board.finish_posts_write outcome);
      outcome) in
    (match outcome with
     | Board.Posts_written _ -> ()
     | Posts_not_written _ | Posts_write_unknown _ ->
       Alcotest.fail "same guard bytes with a fresh real observation invalidated the posts snapshot");
    check_observed_bytes store;
    let actual_guard =
      match Fs_compat.read_private_jsonl_durable_locked_result guard ~after:None
        |> Fs_compat.private_jsonl_snapshot_success_receipt with
      | Ok receipt -> receipt.value
      | Error error -> Alcotest.fail
          (Fs_compat.private_jsonl_transaction_error_to_string error) in
    Alcotest.(check bool) "replacement guard owns a fresh actual cursor" true
      (Fs_compat.Private_jsonl_cursor.equal
         (retained_guard store).snapshot.cursor actual_guard.cursor);
    (* Reordering the same supported fields preserves generation and length,
       but cannot substitute for the accepted exact guard bytes. *)
    let reordered = match Yojson.Safe.from_string original with
      | `Assoc fields -> Yojson.Safe.to_string (`Assoc (List.rev fields)) ^ "\n"
      | _ -> Alcotest.fail "guard is not an object" in
    Alcotest.(check int) "changed guard retains length" (String.length original)
      (String.length reordered);
    let write_in_place bytes =
      Out_channel.with_open_gen [Open_wronly; Open_binary] 0o600 guard
        (fun out -> output_string out bytes) in
    write_in_place reordered;
    let changed = Unix.stat guard in
    Alcotest.(check (pair int int)) "changed bytes retain exact guard inode"
      (replacement.Unix.st_dev, replacement.Unix.st_ino)
      (changed.Unix.st_dev, changed.Unix.st_ino);
    let posts = read_bytes (Board.persist_path store) in
    require_pre_effect (create store "equal generation does not excuse different guard bytes");
    refuse_load store;
    Alcotest.(check string) "refused guard does not alter posts" posts
      (read_bytes (Board.persist_path store));
    Alcotest.(check string) "retained initialization never adopts reordered bytes" original
      (retained_guard store).snapshot.bytes;
    write_in_place original;
    load_posts store 1;
    Alcotest.(check string) "restored actual source retains the post" post.body
      (current store post).body)

let counting_io calls : Fs_compat.private_jsonl_transaction_io_for_testing =
  { before_sync_parent = (fun _ -> incr calls)
  ; close_fd = (fun fd -> incr calls; Unix.close fd) }

let test_auxiliary_guard_never_reads_posts base_path _workspace =
  prepare base_path;
  let guard_calls = ref 0 and posts_calls = ref 0 in
  let store = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some (counting_io guard_calls); posts = Some (counting_io posts_calls) } () in
  let create_topic slug = Board.create_sub_board store ~slug ~name:slug
    ~description:"guard-only auxiliary source" ~owner:"source-writer" () in
  ignore (require_board (create_topic "guard-only"));
  Alcotest.(check bool) "auxiliary write actually reads the guard" true (!guard_calls > 0);
  Alcotest.(check int) "auxiliary write never loads posts" 0 !posts_calls;
  require_io_refusal (Board.with_persist_lock store (fun () ->
    Board.require_posts_source_readable store));
  write_bytes (Board.persist_path store) "{}\n";
  refuse_load store;
  let before = !posts_calls in
  ignore (require_board (create_topic "posts-refused"));
  Alcotest.(check int) "auxiliary retry still does not load posts" before !posts_calls;
  (match store.Board.posts_source with
   | Board.Posts_refused { failure = Posts_rows_rejected [_]; _ } -> ()
   | _ -> Alcotest.fail "auxiliary success cleared the actual posts refusal");
  require_pre_effect (create store "auxiliary success grants no posts authority")

let stable_close_io path ~calls ~fault : Fs_compat.private_jsonl_transaction_io_for_testing =
  let lock_path = Fs_compat.private_jsonl_lock_path path in
  { before_sync_parent = (fun _ -> incr calls)
  ; close_fd = (fun fd ->
      incr calls;
      let actual = Unix.fstat fd and lock = Unix.stat lock_path in
      let stable = actual.Unix.st_dev = lock.Unix.st_dev
        && actual.Unix.st_ino = lock.Unix.st_ino in
      Unix.close fd;
      if stable then match !fault with
        | None -> ()
        | Some exception_ -> fault := None; raise exception_) }

let test_guard_disappears_before_writers base_path _workspace =
  prepare base_path;
  let writer = reloaded base_path 0 in
  let post = require_post (create writer "original before guard disappearance") in
  let guard = guard_path writer in
  let original_guard = read_bytes guard and original_posts = read_bytes (Board.persist_path writer) in
  let guard_calls = ref 0 and posts_calls = ref 0 in
  let admitted () =
    let store = Board.create_store_with_source_io_for_testing ~base_path
      ~io:{ guard = Some (counting_io guard_calls); posts = Some (counting_io posts_calls) } () in
    load_posts store 1;
    store in
  let appending = admitted () and replacing = admitted () and auxiliary = admitted () in
  let before_posts = !posts_calls in
  Unix.unlink guard;
  require_pre_effect (create appending "missing guard denies the real append");
  require_io_refusal (edit replacing post "missing guard denies the real replacement");
  require_io_refusal (Board.create_sub_board auxiliary ~slug:"missing-guard"
    ~name:"Missing guard" ~description:"must remain absent" ~owner:"source-writer" ());
  Alcotest.(check int) "all three preconditions stop before posts payload IO"
    before_posts !posts_calls;
  Alcotest.(check string) "refused writers preserve the exact posts bytes" original_posts
    (read_bytes (Board.persist_path writer));
  Alcotest.(check bool) "ordinary writers do not recreate the missing guard" false
    (Sys.file_exists guard);
  Alcotest.(check bool) "auxiliary refusal does not create a payload" false
    (Sys.file_exists (Board.sub_boards_path auxiliary));
  List.iter (fun store ->
    Alcotest.(check int) "refused writer adds no model row" 1
      (List.length (Board.list_posts store ()));
    Alcotest.(check string) "refused replacement keeps the original model body" post.body
      (current store post).body;
    Alcotest.(check string) "missing guard retains accepted guard history" original_guard
      (retained_guard store).snapshot.bytes;
    match store.Board.posts_source with
    | Board.Posts_refused { last_observed = Posts_observed _; failure = Posts_guard_missing; _ } -> ()
    | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ | Posts_unsettled _ ->
      Alcotest.fail "fresh writer precondition lost the guard-Missing refusal")
    [appending; replacing; auxiliary];
  Alcotest.(check int) "auxiliary refusal publishes no sub-board" 0
    (List.length (Board.list_sub_boards auxiliary));
  write_bytes guard original_guard;
  load_posts appending 1;
  ignore (require_post (create appending "append after exact guard bytes and explicit reload"));
  load_posts replacing 2;
  ignore (require_board (edit replacing post "replacement after explicit reload"));
  load_posts auxiliary 2;
  ignore (require_board (Board.create_sub_board auxiliary ~slug:"restored-guard"
    ~name:"Restored guard" ~description:"actual publication after reload" ~owner:"source-writer" ()));
  let fresh = reloaded base_path 2 in
  Alcotest.(check string) "fresh reader sees the separately admitted replacement"
    "replacement after explicit reload" (current fresh post).body

let test_guard_reserved_keeps_unattempted_batch base_path _workspace =
  prepare base_path;
  let guard_calls = ref 0 and posts_calls = ref 0 and fault = ref None in
  let workspace = Common.masc_dir_from_base_path ~base_path in
  let guard = Paths.posts_initialization_guard_file ~workspace_masc_dir:workspace in
  let stopped_at = ref None in
  let guard_io = stable_close_io guard ~calls:guard_calls ~fault in
  let io = { guard_io with close_fd = (fun fd ->
    match guard_io.close_fd fd with
    | () -> ()
    | exception (Eio.Time.Timeout as exception_) ->
      let backtrace = Printexc.get_raw_backtrace () in
      stopped_at := Some !guard_calls;
      Printexc.raise_with_backtrace exception_ backtrace) } in
  let store = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some io; posts = Some (counting_io posts_calls) } () in
  load_posts store 0;
  load_comments store 0;
  let post = require_post (create store "guard-reserved batch source") in
  let post_id = Board.Post_id.to_string post.id in
  let comment = require_board (Board.add_comment store ~lookup:Recipient_lookup.none_declared
    ~post_id ~author:"batch-reader" ~content:"actual durable comment" ~ttl_hours:0 ()) in
  let comment_id = Board.Comment_id.to_string comment.id in
  ignore (require_board (Board.vote store ~voter:"batch-voter" ~post_id ~direction:Board.Up));
  Board.flush_dirty store;
  (* Keep the baseline post's final counters on disk. The next real flips
     create dirty work without relying on reload preserving memory-only edits. *)
  List.iter (fun direction ->
    ignore (require_board (Board.vote store ~voter:"batch-voter" ~post_id ~direction)))
    [Board.Down; Board.Up];
  List.iter (fun direction ->
    ignore (require_board (Board.vote_comment store ~voter:"batch-comment-voter"
      ~comment_id ~direction))) [Board.Up; Board.Down; Board.Up];
  let votes = Paths.store_file_path store Paths.Votes in
  let paths = [Board.persist_path store; Board.comments_path store; votes; Board.reactions_path store] in
  let payloads = List.map (fun path -> path, read_bytes path) paths in
  Alcotest.(check int) "actual vote flips await compaction" 6 (jsonl_row_count votes);
  Alcotest.(check bool) "real post votes selected a posts snapshot" true store.Board.dirty_posts;
  Alcotest.(check bool) "real comment votes selected a comments snapshot" true store.Board.dirty_comments;
  let before_posts = !posts_calls and before_errors = Board.persist_error_count () in
  fault := Some Eio.Time.Timeout;
  expect_reserved Timeout_close (fun () -> Board.flush_dirty store);
  Alcotest.(check int) "reserved first batch precondition counts once"
    (before_errors + 1) (Board.persist_error_count ());
  (match !stopped_at with
   | Some calls -> Alcotest.(check int) "no later guard IO follows the first reserved cause" calls !guard_calls
   | None -> Alcotest.fail "actual guard-close fault did not run");
  Alcotest.(check int) "reserved guard precondition prevents posts IO" before_posts !posts_calls;
  List.iter (fun (path, before) ->
    Alcotest.(check string) "no selected payload was written after the reserved precondition"
      before (read_bytes path)) payloads;
  Alcotest.(check bool) "posts retry obligation remains selected" true store.Board.dirty_posts;
  Alcotest.(check bool) "unattempted comments retry obligation remains selected" true store.Board.dirty_comments;
  Alcotest.(check bool) "original posts retry contains its actual ID" true
    (Hashtbl.mem store.Board.dirty_post_ids post_id);
  Alcotest.(check bool) "unattempted comments retry contains its actual ID" true
    (Hashtbl.mem store.Board.dirty_comment_ids comment_id);
  Alcotest.(check int) "unattempted comment counter stays in the pending model" 1
    (require_board (Board.get_comment store ~comment_id)).votes_up;
  load_posts store 1;
  Board.flush_dirty store;
  Alcotest.(check bool) "explicit reload and retry settle posts work" false store.Board.dirty_posts;
  Alcotest.(check bool) "explicit retry settles comments work" false store.Board.dirty_comments;
  Alcotest.(check int) "pending votes compaction actually finished" 2 (jsonl_row_count votes);
  let fresh = reloaded base_path 1 in
  load_comments fresh 1;
  Alcotest.(check (pair int int)) "baseline post counters survive the separate retry" (1, 1)
    ((current fresh post).votes_up, (current fresh post).reply_count);
  Alcotest.(check int) "previously unattempted comment snapshot survives restart" 1
    (require_board (Board.get_comment fresh ~comment_id)).votes_up

let test_unadmitted_fusion_positive_replay base_path _workspace =
  prepare base_path;
  let writer = reloaded base_path 0 in
  let run_id = "committed-before-guard-disappearance" in
  let post = match require_post (create_fusion_once writer run_id) with
    | Board.Post_created creation -> creation.post
    | Post_already_present _ -> Alcotest.fail "fresh actual Fusion producer reused a row" in
  let bytes = read_bytes (Board.persist_path writer) in
  Unix.unlink (guard_path writer);
  let guard_calls = ref 0 and posts_calls = ref 0 in
  let reader = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some (counting_io guard_calls); posts = Some (counting_io posts_calls) } () in
  refuse_load reader;
  let before_guard = !guard_calls and before_posts = !posts_calls in
  let persistence_hooks = ref 0 in
  let noop : Board_metrics_hooks.observer =
    { observe_persist_lock_acquire_sec = (fun _ -> ())
    ; observe_persist_lock_held_sec = (fun _ -> ())
    ; inc_dispatch_flusher_start_outcome = (fun ~outcome:_ -> ()) } in
  Fun.protect ~finally:(fun () -> Board_metrics_hooks.set_observer noop) (fun () ->
    Board_metrics_hooks.set_observer
      { noop with observe_persist_lock_acquire_sec = (fun _ -> incr persistence_hooks);
        observe_persist_lock_held_sec = (fun _ -> incr persistence_hooks) };
    (match require_post (create_fusion_once reader run_id) with
     | Board.Post_already_present replay ->
       Alcotest.(check string) "positive recognition retains the actual committed ID"
         (Board.Post_id.to_string post.id) (Board.Post_id.to_string replay.id)
     | Post_created _ -> Alcotest.fail "unadmitted positive replay created another post");
    Alcotest.(check int) "matching-row replay enters no persistence hook" 0 !persistence_hooks);
  Alcotest.(check int) "matching-row replay performs no guard IO" before_guard !guard_calls;
  Alcotest.(check int) "matching-row replay performs no posts IO" before_posts !posts_calls;
  require_pre_effect (create_fusion_once reader "fresh-run-without-a-guard");
  (match reader.Board.posts_source with
   | Board.Posts_refused { last_observed = No_initialization; failure = Posts_guard_missing; _ } -> ()
   | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ | Posts_unsettled _ ->
     Alcotest.fail "positive recognition granted source authority");
  Alcotest.(check string) "positive replay and refused new run preserve disk bytes" bytes
    (read_bytes (Board.persist_path reader));
  Alcotest.(check int) "positive replay publishes no additional model row" 1
    (List.length (Board.list_posts reader ()));
  Alcotest.(check bool) "neither path recreates the guard" false
    (Sys.file_exists (guard_path reader))

let test_guard_reserved_stops_posts base_path workspace =
  prepare base_path;
  let guard_calls = ref 0 and posts_calls = ref 0 in
  let fault = ref (Some Eio.Time.Timeout) in
  let guard = Paths.posts_initialization_guard_file ~workspace_masc_dir:workspace in
  let store = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some (stable_close_io guard ~calls:guard_calls ~fault);
          posts = Some (counting_io posts_calls) } () in
  let before_errors = Board.persist_error_count () in
  expect_reserved Timeout_close (fun () -> ignore (Rows.load_persisted_posts store));
  Alcotest.(check int) "reserved first guard read counts its diagnostic once"
    (before_errors + 1) (Board.persist_error_count ());
  Alcotest.(check bool) "reserved cause came from actual guard descriptor" true
    (!guard_calls > 0 && Option.is_none !fault);
  Alcotest.(check int) "reserved guard cleanup prevents all posts IO" 0 !posts_calls;
  (match store.Board.posts_source with
   | Board.Posts_refused { last_observed = No_initialization;
       diagnostics = [File_diagnostic { file = Guard_file;
         error = Fs_compat.Transaction_settlement_failed _ }]; _ } -> ()
   | _ -> Alcotest.fail "guard cleanup minted authority or lost its exact diagnostic");
  load_posts store 0;
  ignore (require_post (create store "new explicit operation after reserved cleanup"))

let test_nested_guard_cleanup_preserves_fusion_mutex base_path workspace =
  prepare base_path;
  let guard_calls = ref 0 and posts_calls = ref 0 and fault = ref None in
  let guard = Paths.posts_initialization_guard_file ~workspace_masc_dir:workspace in
  let store = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some (stable_close_io guard ~calls:guard_calls ~fault);
          posts = Some (counting_io posts_calls) } () in
  load_posts store 0;
  let original = (retained_guard store).snapshot.bytes in
  let posts_before = !posts_calls and guard_before = !guard_calls in
  let actual_failure exception_ =
    try raise exception_ with raised -> raised, Printexc.get_raw_backtrace () in
  let nested = Eio.Exn.Multiple
      [actual_failure (Failure "ordinary cause before reserved cause");
       actual_failure Eio.Time.Timeout] in
  fault := Some nested;
  let run_id = "guard-reserved-fusion" in
  (match create_fusion_once store run_id with
   | _ -> Alcotest.fail "nested reserved guard cleanup was swallowed"
   | exception observed ->
     Alcotest.(check bool) "original combined exception is rethrown" true
       (observed == nested));
  Alcotest.(check bool) "failure followed an actual fresh guard read" true
    (!guard_calls > guard_before && Option.is_none !fault);
  Alcotest.(check int) "reserved precondition never enters posts IO" posts_before !posts_calls;
  Alcotest.(check string) "failure retains the accepted original guard" original
    (retained_guard store).snapshot.bytes;
  Alcotest.(check string) "reserved guard precondition publishes no row" ""
    (read_bytes (Board.persist_path store));
  Alcotest.(check int) "reserved guard precondition publishes no memory" 0
    (List.length (Board.list_posts store ()));
  Alcotest.(check bool) "failed Fusion run has no origin receipt" true
    (Option.is_none (Board.find_post_by_run_id store ~run_id));
  load_posts store 0;
  (match require_post (create_fusion_once store run_id) with
   | Board.Post_created _ -> ()
   | Post_already_present _ -> Alcotest.fail "refused precondition left a phantom Fusion receipt");
  ignore (reloaded base_path 1)

let test_ordered_guard_posts_cleanup base_path workspace =
  prepare base_path;
  let guard_calls = ref 0 and posts_calls = ref 0 in
  let guard_fault = ref (Some (Failure "actual guard cleanup before posts")) in
  let posts_fault = ref (Some Eio.Time.Timeout) in
  let guard = Paths.posts_initialization_guard_file ~workspace_masc_dir:workspace in
  let posts = Paths.posts_file ~workspace_masc_dir:workspace in
  let store = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some (stable_close_io guard ~calls:guard_calls ~fault:guard_fault);
          posts = Some (stable_close_io posts ~calls:posts_calls ~fault:posts_fault) } () in
  let before_errors = Board.persist_error_count () in
  expect_reserved Timeout_close (fun () -> ignore (Rows.load_persisted_posts store));
  Alcotest.(check int) "both actual ordered read cleanups are counted"
    (before_errors + 2) (Board.persist_error_count ());
  Alcotest.(check bool) "both real descriptor seams fired" true
    (!guard_calls > 0 && !posts_calls > 0
     && Option.is_none !guard_fault && Option.is_none !posts_fault);
  (match store.Board.posts_source with
   | Board.Posts_refused { last_observed = Guard_observed _;
       diagnostics = [File_diagnostic { file = Guard_file;
         error = Fs_compat.Transaction_settlement_failed _ };
         File_diagnostic { file = Posts_file;
         error = Fs_compat.Transaction_settlement_failed _ }]; _ } -> ()
   | _ -> Alcotest.fail "later reserved posts cleanup erased or reordered guard cleanup");
  load_posts store 0;
  (match store.Board.posts_source with
   | Board.Posts_readable { diagnostics = []; _ } -> ()
   | _ -> Alcotest.fail "fresh operation replayed prior cleanup diagnostics");
  ignore (require_post (create store "mutex remains usable after both actual cleanups"));
  guard_fault := Some (Failure "actual guard cleanup before committed append");
  posts_fault := Some Eio.Time.Timeout;
  let before_errors = Board.persist_error_count () in
  expect_reserved Timeout_close (fun () ->
    ignore (create store "known append after two ordered cleanup diagnostics"));
  Alcotest.(check int) "both actual ordered successful-write cleanups are counted"
    (before_errors + 2) (Board.persist_error_count ());
  check_known_settlement store;
  check_observed_bytes store;
  (match store.Board.posts_source with
   | Board.Posts_readable { diagnostics =
       [File_diagnostic { file = Guard_file; _ }; File_diagnostic { file = Posts_file; _ }]; _ } -> ()
   | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ | Posts_unsettled _ ->
     Alcotest.fail "known append lost the chronological two-file cleanup trace");
  ignore (reloaded base_path 2)

let test_unknown_stops_both_source_files base_path workspace =
  prepare base_path;
  let guard_calls = ref 0 and posts_calls = ref 0 and armed = ref false in
  let posts_io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        incr posts_calls;
        if !armed then (
          armed := false;
          raise (Failure "actual unknown rewrite-parent sync")))
    ; close_fd = (fun fd -> incr posts_calls; Unix.close fd) } in
  let store = Board.create_store_with_source_io_for_testing ~base_path
    ~io:{ guard = Some (counting_io guard_calls); posts = Some posts_io } () in
  load_posts store 0;
  let post = require_post (create store "before unknown effect") in
  armed := true;
  require_io_refusal (edit store post "actual rename with unknown durability");
  require_unknown_parent_sync store;
  let retained = store.Board.posts_source in
  let before_guard = !guard_calls and before_posts = !posts_calls in
  let backup = workspace ^ ".unknown-original" in
  Unix.rename workspace backup;
  Unix.mkdir workspace 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir workspace; Unix.rename backup workspace)
    (fun () ->
      refuse_load store;
      require_pre_effect (create store "unknown never rearms append");
      require_io_refusal (edit store post "unknown never rearms rewrite");
      require_io_refusal (Board.create_sub_board store ~slug:"unknown"
        ~name:"Unknown" ~description:"must remain absent" ~owner:"source-writer" ());
      Alcotest.(check int) "unsettled operations perform no guard IO" before_guard !guard_calls;
      Alcotest.(check int) "unsettled operations perform no posts IO" before_posts !posts_calls;
      Alcotest.(check bool) "unknown keeps the original immutable state value" true
        (store.Board.posts_source == retained);
      Alcotest.(check int) "replacement remains completely empty" 0
        (Array.length (Sys.readdir workspace)));
  refuse_load store;
  require_unknown_parent_sync store;
  Alcotest.(check int) "restoration still cannot clear unknown by guard IO" before_guard !guard_calls;
  Alcotest.(check int) "restoration still cannot clear unknown by posts IO" before_posts !posts_calls

let test_non_eio_source_inspection () =
  let base = Filename.temp_dir "board-posts-inspection-" "" in
  let workspace = Common.masc_dir_from_base_path ~base_path:base in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let path = Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
        prepare base;
        let store = make_store base in
        load_posts store 0;
        ignore (require_post (create store "actual preflight row"));
        Board.persist_path store)) in
    (* Keeper's deploy preflight can run outside an Eio main scope. Read the
       real source there through the same lower-shell entrypoint it uses. *)
    let bytes = read_bytes path in
    (match Board_core.inspect_posts_source ~workspace_masc_dir:workspace with
     | Board_core.Inspected {
         observation = Observed_present {
           accepted_rows = 1; errors = []; framing = Complete_rows };
         settlement_diagnostic = None } -> ()
     | Board_core.Inspected _ | Board_core.Inspection_failed _ ->
       Alcotest.fail "non-Eio inspection did not read the complete source");
    Alcotest.(check string) "preflight preserves the actual producer bytes"
      bytes (read_bytes path);
    let partial = bytes ^ "{}\n" in
    write_bytes path partial;
    (match Board_core.inspect_posts_source ~workspace_masc_dir:workspace with
     | Board_core.Inspected {
         observation = Observed_present {
           accepted_rows = 1; errors = [_]; framing = Complete_rows };
         settlement_diagnostic = None } -> ()
     | Board_core.Inspected _ | Board_core.Inspection_failed _ ->
       Alcotest.fail "preflight lost the actual malformed-row refusal");
    Alcotest.(check string) "partial preflight preserves rejected-source bytes"
      partial (read_bytes path);
    let torn = bytes ^ "{" in
    write_bytes path torn;
    (match Board_core.inspect_posts_source ~workspace_masc_dir:workspace with
     | Board_core.Inspected {
         observation = Observed_present {
           accepted_rows = 1; errors = []; framing = Torn_tail { rows_end; end_offset } };
         settlement_diagnostic = None } ->
       Alcotest.(check int) "only complete producer bytes were decoded"
         (String.length bytes) rows_end;
       Alcotest.(check int) "torn observation retains the actual end offset"
         (String.length torn) end_offset
     | Board_core.Inspected _ | Board_core.Inspection_failed _ ->
       Alcotest.fail "preflight lost the incomplete-tail observation");
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
        ; case "failed BasePath capture never heals" test_failed_root_capture_stays_refused
        ; case "replaced BasePath cannot rearm a store"
            (test_directory_replacement_stays_refused ~replace_root:true)
        ; case "replaced state directory cannot rearm a store"
            (test_directory_replacement_stays_refused ~replace_root:false)
        ; case "sub-board-only stores retain the initialized directory"
            test_sub_board_only_retains_initialized_directory
        ; case "BasePath aliases preserve actual source identity" test_base_path_alias
        ; case "two initialized empty observations cannot auto-adopt" test_two_empty_present_observations
        ; case "Present cannot replace a later dangling source" test_present_then_dangling_source
        ; case "initial dangling source is never Missing" test_initial_dangling_source
        ; case "same inode and length still require exact bytes" test_same_cursor_changed_bytes
        ; case "append also compares same-cursor source bytes" test_same_cursor_append_refused
        ; case "partial then Missing never grants empty authority" test_partial_then_missing
        ; case "ordinary reads never recover torn tails" test_torn_tail_is_not_recovered
        ; case "Present disappearance is retained" test_present_disappearance_is_retained
        ; case "retained typed snapshot cannot overwrite a newer edit" test_retained_snapshot_is_stale
        ; case "all actual writers preserve one posts source" test_cross_writer_projection
        ; case "uninitialized complete and partial rows are display only"
            test_uninitialized_rows_remain_display_only
        ; case "initial guard history survives first posts Missing and changed generation"
            test_generation_before_first_posts_admission
        ; case "live reads refuse malformed and aliased guards without repair"
            test_invalid_guard_live_reads
        ; case "exact guard bytes permit a freshly observed replacement"
            test_guard_bytes_and_replacement
        ; case "auxiliary guard checks neither read nor admit posts"
            test_auxiliary_guard_never_reads_posts
        ; case "admitted writers refuse a disappeared guard until explicit reload"
            test_guard_disappears_before_writers
        ; case "unadmitted Fusion replay only recognizes an existing exact row"
            test_unadmitted_fusion_positive_replay ]
    ; "descriptor settlement",
        [ case "reserved guard cleanup stops before posts IO" test_guard_reserved_stops_posts
        ; case "nested guard cleanup leaves all Fusion locks usable"
            test_nested_guard_cleanup_preserves_fusion_mutex
        ; case "guard and posts cleanup diagnostics retain order" test_ordered_guard_posts_cleanup
        ; case "first reserved guard settlement retains all unattempted batch work"
            test_guard_reserved_keeps_unattempted_batch
        ; case "unsettled source stops both files before replacement checks"
            test_unknown_stops_both_source_files
        ; case "Missing read refusal preserves reserved cleanup" test_missing_read_preserves_reserved_cleanup
        ; case "append ordinary cleanup preserves success" (test_append_cleanup Ordinary_close)
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
