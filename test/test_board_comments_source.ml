open Masc

module Rows = Masc_board_handlers.Board_votes_json

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let load_sources store =
  List.iter (fun load -> match load store with
    | Ok _ -> ()
    | Error (path, error) -> Alcotest.failf "load %s: %s" path (Printexc.to_string error))
    [Rows.load_persisted_posts; Rows.load_persisted_comments];
  ignore (require (Board.reload_votes store));
  ignore (require (Board.reload_reactions store))

let new_store base_path =
  let store = Board.create_store ~base_path () in
  load_sources store;
  store

let seed base_path =
  let store = new_store base_path in
  let post = match Board.create_post store ~lookup:Recipient_lookup.none_declared
      ~author:"comments-source-writer" ~content:"shared parent"
      ~post_kind:Board.Human_post ~ttl_hours:0 () with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error) in
  store, post

let append store (post : Board.post) content =
  Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator store ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string post.id) ~author:"comments-source-reader"
    ~content ~ttl_hours:0 ()

let has_comment store (comment : Board.comment) =
  Result.is_ok (Board.get_comment store ~comment_id:(Board.Comment_id.to_string comment.id))

let observe_comments store (post : Board.post) =
  match Board.observe_comments store ~post_id:(Board.Post_id.to_string post.id) with
  | Ok observation -> observation
  | Error error -> Alcotest.fail (Board.show_board_read_error error)

let observation_has_comment (observation : Board.comments_observation) (comment : Board.comment) =
  List.exists (fun (row : Board.comment) -> row.id = comment.id) observation.comments

let require_io_error = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "unadmitted source change succeeded"

let readable store = Board.with_persist_lock store (fun () ->
  Board.require_comments_source_readable store)

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  let base_path = Filename.temp_dir "masc-board-comments-source-" "" in
  Fun.protect ~finally:(fun () -> match before with
    | None -> Unix.unsetenv "MASC_BASE_PATH"
    | Some value -> Unix.putenv "MASC_BASE_PATH" value)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_stale_append_requires_full_reload base_path =
  let first, post = seed base_path in
  let stale = new_store base_path in
  let retained = require (append first post "first store's durable comment") in
  let path = Board.comments_path first in
  let bytes = Fs_compat.load_file path in
  require_io_error (append stale post "not admitted against an old source");
  Alcotest.(check string) "stale append does not change the source" bytes (Fs_compat.load_file path);
  Alcotest.(check int) "failed append is absent from memory" 0 (Hashtbl.length stale.comments);
  load_sources stale;
  Alcotest.(check bool) "reload installs the foreign comment" true (has_comment stale retained);
  let next = require (append stale post "after a complete reload") in
  let restarted = new_store base_path in
  Alcotest.(check bool) "first comment survives restart" true (has_comment restarted retained);
  Alcotest.(check bool) "reloaded writer's comment survives restart" true (has_comment restarted next)

(* #55449: the refusal above lasted until a restart or an explicit reload.
   [Board.reobserve] is that reload, and a Board operation runs it when it
   takes the store. A stale cursor is a cause it reads again for at every
   call. When it reads again for the other causes is in
   test_board_persistence_load_contract (#55465). *)
let test_stale_append_is_reobserved base_path =
  let stale, post = seed base_path in
  let own = require (append stale post "this store's durable comment") in
  let other = new_store base_path in
  let foreign = require (append other post "another writer's durable comment") in
  require_io_error (append stale post "refused against the stale cursor");
  require_io_error (append stale post "still refused without a fresh read");
  (match Board.reobserve stale with
   | [] -> ()
   | (_, error) :: _ -> Alcotest.fail (Board.show_board_error error));
  Alcotest.(check bool) "the fresh read installs the other writer's comment" true
    (has_comment stale foreign);
  Alcotest.(check bool) "the fresh read keeps this store's comment" true (has_comment stale own);
  let reply_count store =
    match Board.read_post store ~post_id:(Board.Post_id.to_string post.id) with
    | Ok (current : Board.post) -> current.reply_count
    | Error error -> Alcotest.fail (Board.show_board_read_error error) in
  Alcotest.(check int) "the post counts both writers' comments" 2 (reply_count stale);
  let next = require (append stale post "accepted after the fresh read") in
  Alcotest.(check int) "the next comment is counted once" 3 (reply_count stale);
  let restarted = new_store base_path in
  List.iter (fun comment ->
    Alcotest.(check bool) "every writer's comment survives restart" true
      (has_comment restarted comment)) [own; foreign; next]

(* #55449: a read again that met the other writer's lock leaves this refusal
   in place of the stale one. The source must still be due, or one unlucky
   read would freeze it until a restart. One process cannot contend with its
   own lock, so the test writes the state that read would leave. *)
let test_contended_read_is_tried_again base_path =
  let stale, post = seed base_path in
  ignore (require (append stale post "this store's durable comment"));
  let other = new_store base_path in
  ignore (require (append other post "another writer's durable comment"));
  require_io_error (append stale post "refused against the stale cursor");
  (match stale.Board.comments_source with
   | Board.Comments_refused refused ->
     stale.Board.comments_source <- Board.Comments_refused { refused with
       failure = Board.Comments_transaction_failed
           (Fs_compat.Stable_lock_contended { lock_path = Board.comments_path stale ^ ".lock" }) }
   | Board.Comments_unobserved | Board.Comments_readable _ | Board.Comments_publishing _
   | Board.Comments_recovered _ | Board.Comments_unsettled _ ->
     Alcotest.fail "the stale append did not refuse the comments source");
  (match Board.reobserve stale with
   | [] -> ()
   | (_, error) :: _ -> Alcotest.fail (Board.show_board_error error));
  ignore (require (append stale post "accepted once the lock was free"))

(* #55449: the source is asked again once persistence is held. A call that
   waited behind a read that cleared the source reads nothing; without the
   second question it would read the file again, and a failure of that read
   would refuse a source that had just been cleared. *)
let test_waiting_call_reads_nothing_after_a_clearing_read base_path =
  let stale, post = seed base_path in
  ignore (require (append stale post "this store's durable comment"));
  let other = new_store base_path in
  ignore (require (append other post "another writer's durable comment"));
  require_io_error (append stale post "refused against the stale cursor");
  let waited, cleared =
    Eio.Switch.run (fun sw ->
      let waiting, resolve = Eio.Promise.create () in
      let cleared =
        Board.with_persist_lock stale (fun () ->
          Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve (Board.reobserve stale));
          let queued = not (Eio.Promise.is_resolved waiting) in
          let loaded = Rows.load_comments_under_persistence stale ~derive:ignore in
          queued, Result.is_ok loaded, stale.Board.comments_source)
      in
      Eio.Promise.await waiting, cleared)
  in
  let queued, loaded, source = cleared in
  Alcotest.(check bool) "the second call waits for persistence" true queued;
  Alcotest.(check bool) "the first read cleared the source" true loaded;
  (match waited with
   | [] -> ()
   | (_, error) :: _ -> Alcotest.fail (Board.show_board_error error));
  Alcotest.(check bool) "the waiting call did not read the source again" true
    (stale.Board.comments_source == source);
  ignore (require (append stale post "accepted after the single read"))

let test_stale_snapshot_keeps_foreign_append base_path =
  let first, post = seed base_path in
  let first_comment = require (append first post "first store snapshot") in
  let second = new_store base_path in
  let foreign_comment = require (append second post "second store append") in
  let path = Board.comments_path first in
  let bytes = Fs_compat.load_file path in
  Board.flush_dirty first;
  Alcotest.(check string) "stale flush preserves both rows" bytes (Fs_compat.load_file path);
  Alcotest.(check bool) "refused comments work remains scheduled" true first.dirty_comments;
  require_io_error (readable first);
  let restarted = new_store base_path in
  Alcotest.(check bool) "own comment is retained" true (has_comment restarted first_comment);
  Alcotest.(check bool) "foreign comment is retained" true (has_comment restarted foreign_comment)

let test_same_inode_same_length_edit_is_not_overwritten base_path =
  let store, post = seed base_path in
  let comment = require (append store post "aaaa") in
  let path = Board.comments_path store in
  Board.with_persist_lock store (fun () ->
    let snapshot = Board.with_lock store (fun () -> Board.capture_comments_snapshot store) in
    let before = Unix.stat path in
    let changed = { comment with content = "bbbb" } in
    let bytes = Yojson.Safe.to_string (Board.comment_to_yojson changed) ^ "\n" in
    Out_channel.with_open_bin path (fun output -> output_string output bytes);
    let after = Unix.stat path in
    Alcotest.(check (pair int int)) "fixture retains inode and length"
      (before.Unix.st_ino, before.Unix.st_size) (after.Unix.st_ino, after.Unix.st_size);
    require_io_error (Board.save_comments_snapshot store snapshot);
    Alcotest.(check string) "exact bytes fence the stale snapshot" bytes (Fs_compat.load_file path));
  load_sources store;
  let reloaded = require (Board.get_comment store ~comment_id:(Board.Comment_id.to_string comment.id)) in
  Alcotest.(check string) "healthy reload replaces the model" "bbbb" reloaded.content

let test_present_loss_and_transient_obstruction base_path =
  let store, post = seed base_path in
  let first = require (append store post "retained original") in
  let path = Board.comments_path store in
  let saved = path ^ ".fixture-original" in
  Unix.rename path saved;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir path; Unix.rename saved path) (fun () ->
    require_io_error (append store post "blocked by a nonregular path"));
  let next = require (append store post "retry against the restored exact source") in
  Unix.rename path saved;
  Fun.protect ~finally:(fun () -> Unix.rename saved path) (fun () ->
    Alcotest.(check bool) "loss after Present is refused" true
      (Result.is_error (Rows.load_persisted_comments store));
    require_io_error (readable store);
    Alcotest.(check bool) "refusal never recreates missing data" false (Sys.file_exists path));
  load_sources store;
  Alcotest.(check bool) "reload retains first row" true (has_comment store first);
  Alcotest.(check bool) "reload retains successful retry" true (has_comment store next)

let test_restart_keeps_complete_prefix_before_torn_tail base_path =
  let store, post = seed base_path in
  let comment = require (append store post "complete comment before a crash fragment") in
  let path = Board.comments_path store in
  let bytes = Fs_compat.load_file path ^ "{unterminated-crash-fragment" in
  Out_channel.with_open_bin path (fun output -> output_string output bytes);
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl ~base_path ~recipient_lookup:Recipient_lookup.none_declared ());
  let restarted = Board.global () in
  let observed = observe_comments restarted post in
  Alcotest.(check bool) "complete prefix comment remains a display row after startup" true
    (observation_has_comment observed comment);
  Alcotest.(check bool) "display prefix cannot establish a complete thread" true
    (match observed.completeness with
     | Board.Source_incomplete (Board.Io_error _) -> true
     | Board.Source_incomplete _ | Board.Source_complete -> false);
  let parent = require (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator
    ~post_id:(Board.Post_id.to_string post.id)) in
  Alcotest.(check int) "startup rebuilds reply count from retained display rows" 1 parent.reply_count;
  require_io_error (readable restarted);
  (* #55449: reading again would meet the same torn tail, so no operation does. *)
  let refused = restarted.Board.comments_source in
  ignore (Board_dispatch.backend ());
  Alcotest.(check bool) "a torn tail is not read again at each operation" true
    (restarted.Board.comments_source == refused);
  require_io_error (append restarted post "display prefix grants no append authority");
  Board.rewrite_comments restarted;
  Alcotest.(check string) "display reads and refused writes preserve the entire torn source"
    bytes (Fs_compat.load_file path);
  let saved = path ^ ".fixture-original" in
  Unix.rename path saved;
  Fun.protect ~finally:(fun () -> Unix.rename saved path) (fun () ->
    Alcotest.(check bool) "observed Present prefix cannot become initialized Missing" true
      (Result.is_error (Rows.load_persisted_comments restarted));
    Alcotest.(check bool) "a missing torn source is not recreated" false (Sys.file_exists path));
  Board_dispatch.reset_for_test ();
  Board.reset_global_for_test ()

let test_unknown_rewrite_requires_explicit_recovery_and_reload base_path =
  let _, post = seed base_path in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        if !armed then (armed := false; raise (Failure "injected comments parent sync")))
    ; close_fd = Unix.close } in
  let store = Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  load_sources store;
  let comment = require (append store post "real row before an uncertain rewrite") in
  ignore (require (Board.vote_comment store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"comments-source-voter"
    ~comment_id:(Board.Comment_id.to_string comment.id) ~direction:Board.Up));
  Board.with_persist_lock store (fun () ->
    let snapshot = Board.with_lock store (fun () -> Board.capture_comments_snapshot store) in
    armed := true;
    require_io_error (Board.save_comments_snapshot store snapshot));
  let pending = match store.comments_source with
    | Board.Comments_unsettled { pending; _ } -> pending
    | _ -> Alcotest.fail "actual published rewrite must retain uncertainty" in
  Alcotest.(check bool) "ordinary reload cannot settle" true
    (Result.is_error (Rows.load_persisted_comments store));
  require_io_error (readable store);
  let receipt = Board.with_persist_lock store (fun () -> require (Board.settle_comments_source store)) in
  (match receipt with
   | Some receipt ->
     Alcotest.(check string) "recovery returns the interrupted intended bytes"
       pending.intended_bytes receipt.interrupted.intended_bytes;
     Alcotest.(check bool) "reload cannot acknowledge a completed recovery" true
       (Result.is_error (Rows.load_persisted_comments store));
     Board.with_persist_lock store (fun () -> require (Board.acknowledge_comments_recovery store receipt))
   | None -> Alcotest.fail "an unsettled write requires an actual recovery receipt");
  require_io_error (readable store);
  load_sources store;
  require (readable store);
  Alcotest.(check bool) "full reload retains the durable row" true (has_comment store comment)

let test_reserved_cleanup_finishes_known_append_publication base_path =
  let _, post = seed base_path in
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
  let store = Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  load_sources store;
  (* The stable sibling name is the actual Fs JSONL lock protocol. Only that
     descriptor's post-close cleanup is failed; data writes already succeeded. *)
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.comments_path store));
  armed := true;
  (match append store post "known append before reserved cleanup" with
   | _ -> Alcotest.fail "reserved descriptor cleanup was swallowed"
   | exception Eio.Time.Timeout -> ());
  require (readable store);
  let comment = match List.of_seq (Hashtbl.to_seq_values store.comments) with
    | [comment] -> comment
    | _ -> Alcotest.fail "known append must finish its one model publication" in
  let restarted = new_store base_path in
  Alcotest.(check bool) "the same published row survives restart" true (has_comment restarted comment)

let test_completed_recovery_survives_reserved_close base_path =
  let _, post = seed base_path in
  let fail_parent = ref false and fail_recovery = ref false and fail_close = ref false in
  let lock_path = ref None and io_calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        incr io_calls;
        if !fail_parent then (fail_parent := false; raise (Failure "initial unknown comments rewrite"));
        if !fail_recovery then (fail_recovery := false; fail_close := true))
    ; close_fd = (fun fd ->
        incr io_calls;
        let stat = Unix.fstat fd in
        let target = Option.map Unix.lstat !lock_path in
        Unix.close fd;
        match !fail_close, target with
        | true, Some lock when stat.Unix.st_dev = lock.Unix.st_dev
                               && stat.Unix.st_ino = lock.Unix.st_ino ->
          fail_close := false; raise Eio.Time.Timeout
        | false, (None | Some _) | true, None | true, Some _ -> ()) } in
  let store = Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  load_sources store;
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.comments_path store));
  let comment = require (append store post "row whose recovery receipt must survive") in
  ignore (require (Board.vote_comment store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"recovery-receipt-voter"
    ~comment_id:(Board.Comment_id.to_string comment.id) ~direction:Board.Up));
  Board.with_persist_lock store (fun () ->
    let snapshot = Board.with_lock store (fun () -> Board.capture_comments_snapshot store) in
    fail_parent := true;
    require_io_error (Board.save_comments_snapshot store snapshot));
  fail_recovery := true;
  (match Board.with_persist_lock store (fun () -> Board.settle_comments_source store) with
   | _ -> Alcotest.fail "the recovery's reserved close must escape unchanged"
   | exception Eio.Time.Timeout -> ());
  let retained = match store.comments_source with
    | Board.Comments_recovered receipt -> receipt
    | _ -> Alcotest.fail "completed body must retain its whole recovery receipt" in
  require_io_error (readable store);
  Alcotest.(check bool) "ordinary reload cannot discard an unreceived receipt" true
    (Result.is_error (Rows.load_persisted_comments store));
  let before = !io_calls in
  let recovered = Board.with_persist_lock store (fun () -> require (Board.settle_comments_source store)) in
  Alcotest.(check int) "retrieving the same completed receipt performs no IO" before !io_calls;
  (match recovered with
   | Some receipt ->
     Alcotest.(check bool) "the exact original receipt remains owned" true (receipt == retained);
     Alcotest.(check bool) "actual cleanup diagnostics remain attached" true (receipt.diagnostics <> []);
     Board.with_persist_lock store (fun () -> require (Board.acknowledge_comments_recovery store receipt))
   | None -> Alcotest.fail "completed recovery receipt was lost");
  require_io_error (readable store);
  load_sources store;
  require (readable store);
  Alcotest.(check bool) "explicit reload retains the durable comment" true (has_comment store comment)

let test_unfinished_publication_cannot_adopt_foreign_rows base_path =
  let store, post = seed base_path in
  let original = require (append store post "existing published row") in
  let uncommitted = { original with id = Board.Comment_id.generate (); content = "unpublished append" } in
  let receipt = Board.with_persist_lock store (fun () -> require (Board.append_comment ~reader:Masc_board_handlers.Board_access.Operator store uncommitted)) in
  require_io_error (readable store);
  Alcotest.(check bool) "reload cannot erase unfinished model publication" true
    (Result.is_error (Rows.load_persisted_comments store));
  let other = new_store base_path in
  let foreign = require (append other post "foreign row after the actual receipt") in
  let path = Board.comments_path store in
  let bytes = Fs_compat.load_file path in
  Board.with_persist_lock store (fun () ->
    Board.with_lock store (fun () ->
      Board.mark_dirty_comment store (Board.Comment_id.to_string uncommitted.id));
    require (Board.publish_comment_append store receipt));
  Board.rewrite_comments store;
  Alcotest.(check string) "owned cleanup cannot erase an intervening foreign row"
    bytes (Fs_compat.load_file path);
  let restarted = new_store base_path in
  Alcotest.(check bool) "foreign row remains available" true (has_comment restarted foreign);
  (* Cleanup was refused and its intent is volatile. This test does not claim
     durable rollback of the rejected/unpublished row across restart. *)
  Alcotest.(check bool) "unsettled cleanup is not silently reported durable" true
    (has_comment restarted uncommitted)

let with_started_store base_path f =
  let reset () = Board_dispatch.reset_for_test (); Board.reset_global_for_test () in
  reset ();
  Fun.protect ~finally:reset (fun () ->
    Result.get_ok (Board_dispatch.init_jsonl ~base_path
      ~recipient_lookup:Recipient_lookup.none_declared ());
    f (Board.global ()))

let query_thread ~reader post_id =
  Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client
    "masc_board_post_get" (`Assoc ["post_id", `String post_id])

let detail ~reader post_id =
  Server_routes_http_runtime.board_post_detail_json ~reader ~config:None
    ~voter:None ~reaction_actor:None
    ~response_format:Server_board_post_response_format.Nested ~post_id ()

let detail_status ~reader post_id = fst (detail ~reader post_id)

let check_runtime_failure label result =
  Alcotest.(check bool) label true
    (match result with
     | Tool_result.Failed { Tool_result.class_ = Tool_result.Runtime_failure; _ } -> true
     | Tool_result.Failed _ | Tool_result.Completed _ | Tool_result.Deferred _ -> false)

type query_source = Initial_missing | Present_empty | Non_regular | Invalid_row | Torn_tail

let test_query_boundary source base_path =
  let store, post = seed base_path in
  let path = Board.comments_path store in
  let retained = match source with
    | Invalid_row | Torn_tail -> Some (require (append store post "accepted display row"))
    | Initial_missing | Present_empty | Non_regular -> None in
  let damage suffix =
    let bytes = Fs_compat.load_file path ^ suffix in
    Out_channel.with_open_bin path (fun output -> output_string output bytes);
    Some bytes in
  let damaged_bytes = match source with
    | Initial_missing ->
      (match Unix.lstat path with
       | _ -> Alcotest.fail "Missing fixture already has a comments entry"
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      None
    | Present_empty -> Out_channel.with_open_bin path (fun _ -> ()); None
    | Non_regular -> Unix.mkdir path 0o700; None
    | Invalid_row -> damage "{malformed-row}\n"
    | Torn_tail -> damage "{unterminated-tail" in
  with_started_store base_path (fun restarted ->
    let post_id = Board.Post_id.to_string post.id in
    let reader = Masc_board_handlers.Board_access.Operator in
    let result = query_thread ~reader post_id in
    let observed = observe_comments restarted post in
    let missing_comment_id = Board.Comment_id.to_string (Board.Comment_id.generate ()) in
    let module Signal = Keeper_world_observation_board_signal in
    let self_ids = [Option.get (Keeper_identity.Keeper_id.of_string "comments-source-reader")] in
    let self_status = Signal.check_self_comment_status ~self_ids ~post_id in
    (match source with
     | Initial_missing | Present_empty ->
       Alcotest.(check bool) "legitimate empty source is complete" true
         (observed.completeness = Board.Source_complete);
       let page = match Board.Comment_page.Position.of_metadata (Tool_result.metadata result) with
         | Some page when Tool_result.is_success result -> page
         | Some _ | None -> Alcotest.fail "complete empty thread must return a successful page" in
       Alcotest.(check int) "complete empty tool page has zero comments" 0 page.total;
       (match Board.get_comment restarted ~comment_id:missing_comment_id with
        | Error (Board.Comment_not_found id) when String.equal id missing_comment_id -> ()
        | Error error -> Alcotest.fail (Board.show_board_error error)
        | Ok _ -> Alcotest.fail "empty source returned an unknown comment");
       Alcotest.(check bool) "complete HTTP detail succeeds" true (detail_status ~reader post_id = `OK);
       Alcotest.(check bool) "complete empty source can establish no self comment" true
         (match self_status with Signal.Available `Never -> true
          | Signal.Available (`No_new_external | `New_external _) | Signal.Unavailable _ -> false)
     | Non_regular | Invalid_row | Torn_tail ->
       check_runtime_failure "MCP query refuses an incomplete source" result;
       Alcotest.(check bool) "failed tool read carries no complete page" true
         (Option.is_none (Board.Comment_page.Position.of_metadata (Tool_result.metadata result)));
       Alcotest.(check bool) "HTTP source failure is 503" true
         (detail_status ~reader post_id = `Service_unavailable);
       Alcotest.(check bool) "Keeper refuses to infer self-comment absence" true
         (match self_status with
          | Signal.Unavailable { error = Board.Read_source_unavailable (Board.Io_error _); _ } -> true
          | Signal.Unavailable _ | Signal.Available _ -> false);
       (match Board.read_comments restarted ~post_id with
        | Error (Board.Read_source_unavailable (Board.Io_error _)) -> ()
        | Error error -> Alcotest.fail (Board.show_board_read_error error)
        | Ok _ -> Alcotest.fail "complete-list query accepted an incomplete source");
       require_io_error (Board.get_comment restarted ~comment_id:missing_comment_id));
    (match retained with
     | None -> ()
     | Some comment ->
       Alcotest.(check bool) "accepted row and incompleteness remain observable together" true
         (observation_has_comment observed comment
          && match observed.completeness with
             | Board.Source_incomplete (Board.Io_error _) -> true
             | Board.Source_incomplete _ | Board.Source_complete -> false);
       require_io_error (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string comment.id)));
    match damaged_bytes with
    | None -> ()
    | Some bytes -> Alcotest.(check string) "queries preserve damaged source bytes"
        bytes (Fs_compat.load_file path))

let test_incomplete_queries_preserve_hidden_target_boundary base_path =
  let store, public_post = seed base_path in
  (* A Direct post is refused unless it addresses a declared recipient. The
     reader below is neither the author nor that recipient. *)
  let lookup = Recipient_lookup.make (fun _ ->
    Ok (Some (require (Board.Agent_id.of_string "private-target")))) in
  let post = match Board.create_post store ~lookup
      ~author:"private-owner" ~content:"@private-target private thread" ~visibility:Board.Direct
      ~post_kind:Board.Human_post ~ttl_hours:0 () with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error) in
  let comment = require (append store post "private reply") in
  let path = Board.comments_path store in
  let private_marker = "PRIVATE_COMMENT_BODY" in
  let bytes = Fs_compat.load_file path ^ "!" ^ private_marker ^ "\n" in
  Out_channel.with_open_bin path (fun output -> output_string output bytes);
  with_started_store base_path (fun restarted ->
    let reader = Masc_board_handlers.Board_access.named "stranger" in
    let post_id = Board.Post_id.to_string post.id in
    let public_id = Board.Post_id.to_string public_post.id in
    let absent_post = Board.Post_id.to_string (Board.Post_id.generate ()) in
    let observed = observe_comments restarted post in
    Alcotest.(check bool) "fixture parser diagnosis contains the private row fragment" true
      (match observed.completeness with
       | Board.Source_incomplete (Board.Io_error diagnostic) ->
         String_util.contains_substring diagnostic private_marker
       | Board.Source_incomplete _ | Board.Source_complete -> false);
    let no_private_fragment label text =
      Alcotest.(check bool) label false (String_util.contains_substring text private_marker);
      Alcotest.(check bool) (label ^ ": no source path") false
        (String_util.contains_substring text path) in
    (match Board_dispatch.require_persisted_sources_readable () with
     | Error (Board.Io_error message) ->
       no_private_fragment "shared evidence gate hides private parser content" message
     | Error error -> Alcotest.fail (Board.show_board_error error)
     | Ok () -> Alcotest.fail "shared evidence gate accepted an incomplete comments source");
    let public_result = query_thread ~reader public_id in
    check_runtime_failure "unrelated readable public thread reports source failure" public_result;
    no_private_fragment "MCP response hides private parser content" (Tool_result.message public_result);
    let public_status, public_body = detail ~reader public_id in
    Alcotest.(check bool) "readable public thread HTTP reports 503" true
      (public_status = `Service_unavailable);
    no_private_fragment "HTTP response hides private parser content" public_body;
    List.iter (fun id -> Alcotest.(check bool) "hidden and absent posts both answer 404" true
      (detail_status ~reader id = `Not_found)) [post_id; absent_post];
    Alcotest.(check bool) "operator sees source failure on the same thread" true
      (detail_status ~reader:Masc_board_handlers.Board_access.Operator post_id = `Service_unavailable);
    let reaction_query id = Board_tool.handle_tool ~reader
      ~result_boundary:Tool_output.Sent_to_client "masc_board_reaction"
      (`Assoc ["target_type", `String "comment"; "target_id", `String id; "emoji", `String "👍"]) in
    List.iter (fun id ->
      let result = reaction_query id in
      check_runtime_failure "hidden and absent comment targets share source failure" result;
      no_private_fragment "reaction gate hides private parser content" (Tool_result.message result))
      [Board.Comment_id.to_string comment.id; Board.Comment_id.to_string (Board.Comment_id.generate ())];
    let posts_path = Board.persist_path restarted in
    let posts_bytes = Fs_compat.load_file posts_path ^ "{invalid-post}\n" in
    Out_channel.with_open_bin posts_path (fun output -> output_string output posts_bytes);
    Alcotest.(check bool) "posts reload reports corruption" true
      (Result.is_error (Rows.load_persisted_posts restarted));
    List.iter (fun id ->
      Alcotest.(check bool) "unavailable posts source treats every HTTP ID alike" true
        (detail_status ~reader id = `Service_unavailable);
      let result = query_thread ~reader id in
      check_runtime_failure "MCP source failure cannot become a permanent lookup miss" result;
      no_private_fragment "MCP posts-source failure retains public redaction" (Tool_result.message result))
      [post_id; absent_post])

let test_snapshot_reuse_keeps_row_caches_empty_and_preserves_top_k_order base_path =
  let store, post = seed base_path in
  let comments =
    List.init 30 (fun i ->
      require (append store post (Printf.sprintf "comment #%02d" i)))
  in
  let first_comment = List.hd comments in
  ignore
    (require
       (Board.vote_comment store ~reader:Masc_board_handlers.Board_access.Operator
          ~voter:"voter-1"
          ~comment_id:(Board.Comment_id.to_string first_comment.id)
          ~direction:Board.Up));
  Board.flush_dirty store;
  Alcotest.(check int) "post_rows duplicate cache remains empty" 0
    (Hashtbl.length store.post_rows);
  Alcotest.(check int) "comment_rows duplicate cache remains empty" 0
    (Hashtbl.length store.comment_rows);
  let top_5 = Board.list_comments store ~limit:5 () in
  let all_sorted = Board.list_comments store ~limit:100 () in
  let expected_5 = List.filteri (fun i _ -> i < 5) all_sorted in
  Alcotest.(check (list string)) "bounded top-K comment heap matches full sort order"
    (List.map (fun (c : Board.comment) -> Board.Comment_id.to_string c.id) expected_5)
    (List.map (fun (c : Board.comment) -> Board.Comment_id.to_string c.id) top_5);
  let restarted = new_store base_path in
  Alcotest.(check int) "reloaded comments match persisted count" 30
    (Hashtbl.length restarted.comments);
  let reloaded_first =
    require (Board.get_comment restarted
      ~comment_id:(Board.Comment_id.to_string first_comment.id))
  in
  Alcotest.(check int) "mutated comment vote survives slice-reused flush" 1
    reloaded_first.votes_up;
  Alcotest.(check int) "reloaded post_rows stays empty" 0
    (Hashtbl.length restarted.post_rows);
  Alcotest.(check int) "reloaded comment_rows stays empty" 0
    (Hashtbl.length restarted.comment_rows)

let () = Alcotest.run "board comments source"
  ["persistence",
    [Alcotest.test_case "stale append requires model reload" `Quick (with_fixture test_stale_append_requires_full_reload);
     Alcotest.test_case "stale append is read again once" `Quick (with_fixture test_stale_append_is_reobserved);
     Alcotest.test_case "a read that met a lock is tried again" `Quick (with_fixture test_contended_read_is_tried_again);
     Alcotest.test_case "a call that waited behind a clearing read reads nothing" `Quick
       (with_fixture test_waiting_call_reads_nothing_after_a_clearing_read);
     Alcotest.test_case "stale flush retains foreign append" `Quick (with_fixture test_stale_snapshot_keeps_foreign_append);
     Alcotest.test_case "same inode and size do not authorize overwrite" `Quick
       (with_fixture test_same_inode_same_length_edit_is_not_overwritten);
     Alcotest.test_case "known nonwrite retries but observed loss refuses" `Quick
       (with_fixture test_present_loss_and_transient_obstruction);
     Alcotest.test_case "torn-tail restart retains display prefix and refusal" `Quick
       (with_fixture test_restart_keeps_complete_prefix_before_torn_tail);
     Alcotest.test_case "unknown rewrite requires recovery and reload" `Quick
       (with_fixture test_unknown_rewrite_requires_explicit_recovery_and_reload);
     Alcotest.test_case "known append publishes before reserved cleanup escapes" `Quick
       (with_fixture test_reserved_cleanup_finishes_known_append_publication);
     Alcotest.test_case "completed recovery receipt survives reserved close" `Quick
       (with_fixture test_completed_recovery_survives_reserved_close);
     Alcotest.test_case "unfinished publication retains exact cleanup receipt" `Quick
       (with_fixture test_unfinished_publication_cannot_adopt_foreign_rows);
     Alcotest.test_case "snapshot reuse keeps row caches empty and preserves top-K order" `Quick
       (with_fixture test_snapshot_reuse_keeps_row_caches_empty_and_preserves_top_k_order)];
   "query consumers",
    [Alcotest.test_case "initial Missing is a complete empty thread" `Quick
       (with_fixture (test_query_boundary Initial_missing));
     Alcotest.test_case "present empty is a complete empty thread" `Quick
       (with_fixture (test_query_boundary Present_empty));
     Alcotest.test_case "nonregular comments are unavailable at consumers" `Quick
       (with_fixture (test_query_boundary Non_regular));
     Alcotest.test_case "rejected row preserves display but refuses complete queries" `Quick
       (with_fixture (test_query_boundary Invalid_row));
     Alcotest.test_case "torn tail preserves display but refuses complete queries" `Quick
       (with_fixture (test_query_boundary Torn_tail));
     Alcotest.test_case "incomplete queries preserve hidden target boundary" `Quick
       (with_fixture test_incomplete_queries_preserve_hidden_target_boundary)]]
