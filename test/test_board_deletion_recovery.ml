open Masc

module Paths = Masc_board_handlers.Board_paths

let () = Mirage_crypto_rng_unix.use_default ()
let () = Printexc.record_backtrace true
let require = function Ok value -> value | Error error -> Alcotest.fail (Board.show_board_error error)
let read_post store id = match Board.read_post_for_evidence store ~post_id:id with
  | Ok post -> post | Error error -> Alcotest.fail (Board.show_board_read_error error)
let marker store = Paths.store_file_path store Paths.Deletion

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture run () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-deletion-recovery-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> run base_path)

let fresh base_path =
  let store = Board.create_store ~base_path () in
  require (Board.initialize_store store);
  store

let post ?hearth store content =
  match Board.create_post store ~lookup:Recipient_lookup.none_declared ~author:"deletion-owner"
      ~content ?hearth ~post_kind:Board.Human_post ~ttl_hours:0 () with
  | Ok post -> post
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let seed store =
  let parent = post store "fixed original deletion" in
  let reply = require (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator store ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~author:"reader" ~content:"fixed original reply" ~ttl_hours:0 ()) in
  Board.flush_dirty store;
  parent, reply

let sources store = [Board.persist_path store; Board.comments_path store;
  Board.vote_log_path store; Board.reactions_path store]
let snapshots store = List.map (fun path -> path, Fs_compat.load_file path) (sources store)
let check_bytes label snapshots =
  List.iter (fun (path, bytes) -> Alcotest.(check string) label bytes (Fs_compat.load_file path)) snapshots
let check_removed store (parent : Board.post) (reply : Board.comment) =
  (match Board.read_post_for_evidence store ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Read_post_not_found _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_read_error error)
   | Ok _ -> Alcotest.fail "original post remains after recovery");
  match Board.get_comment store ~comment_id:(Board.Comment_id.to_string reply.id) with
  | Error (Board.Comment_not_found _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "original comment remains after recovery"

let expect_progress store expected = match store.Board.deletion_state with
  | Board.Deletion_pending work ->
    Alcotest.(check bool) "exact deletion progress retained" true (work.deletion_progress = expected)
  | Board.Deletion_unobserved | Board.Deletion_readable _ | Board.Deletion_unsettled _
  | Board.Deletion_refused _ | Board.Deletion_projection_failed _ -> Alcotest.fail "owned deletion work lost"

let same_inode left right = left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino

(* The injected exception follows an actual stable-lock descriptor close. *)
let reserved_marker_io ~retirement marker_path armed calls =
  let saw_record = ref false in
  let lock_path = Fs_compat.private_jsonl_lock_path marker_path in
  { Fs_compat.before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      incr calls;
      let stat = Unix.fstat fd in
      let lock = Unix.lstat lock_path in
      Unix.close fd;
      if same_inode stat lock then (
        let present = Sys.file_exists marker_path in
        if present then saw_record := true;
        if !armed && (if retirement then !saw_record && not present else present) then (
          armed := false;
          raise Eio.Time.Timeout))) }

let test_unknown_record base_path =
  let armed = ref false and calls = ref 0 and marker_path = ref "" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed && Sys.file_exists !marker_path then (
      armed := false; raise (Sys_error "decision parent sync failed")));
    close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  marker_path := marker store;
  require (Board.initialize_store store);
  let parent, reply = seed store in
  let before = snapshots store in
  armed := true;
  (match require (Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Deletion_decision_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_persistence_pending _ -> Alcotest.fail "unknown decision was reported applied");
  ignore (read_post store (Board.Post_id.to_string parent.id));
  check_bytes "unknown record changes no data source" before;
  (match store.deletion_state with
   | Board.Deletion_unsettled { attempt = Board.Recording_decision plan; intended_bytes; _ } ->
     Alcotest.(check string) "unknown retains its exact intended marker" intended_bytes (Fs_compat.load_file !marker_path);
     Alcotest.(check string) "unknown owns the original post" (Board.Post_id.to_string parent.id)
       (match plan.operation with
        | Board.Delete_post { deleted_post; _ } -> Board.Post_id.to_string deleted_post
        | Board.Delete_sub_board _ -> Alcotest.fail "wrong decision kind")
   | Board.Deletion_unsettled { attempt = Board.Retiring_decision _; _ }
   | Board.Deletion_unobserved | Board.Deletion_readable _ | Board.Deletion_pending _
   | Board.Deletion_refused _ | Board.Deletion_projection_failed _ -> Alcotest.fail "record uncertainty lost");
  let calls_before = !calls in
  Board.flush_dirty store;
  Alcotest.(check bool) "reinitialization cannot erase uncertainty" true (Result.is_error (Board.initialize_store store));
  Alcotest.(check bool) "ordinary reload cannot erase uncertainty" true (Result.is_error (Board.reload_votes store));
  Alcotest.(check int) "ordinary operations do not replay the marker" calls_before !calls;
  let restarted = fresh base_path in
  check_removed restarted parent reply;
  Alcotest.(check bool) "fresh recovery retires the original decision" false (Sys.file_exists !marker_path)

let test_reserved_marker retirement base_path =
  let armed = ref false and calls = ref 0 in
  let marker_path = Paths.file_path ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path) Paths.Deletion in
  let io = reserved_marker_io ~retirement marker_path armed calls in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  require (Board.initialize_store store);
  let parent, reply = seed store in
  let before = snapshots store in
  armed := true;
  (match Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok _ | Error _ -> Alcotest.fail "original marker cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  if retirement then (
    check_removed store parent reply;
    match store.deletion_state with
    | Board.Deletion_readable { observation; plan = None; diagnostics } ->
      Alcotest.(check bool) "known empty receipt precedes reserved cleanup" true
        (Fs_compat.Private_jsonl_cursor.is_missing observation.decision_snapshot.cursor);
      Alcotest.(check bool) "retirement cleanup evidence retained" true (diagnostics <> [])
    | Board.Deletion_readable { plan = Some _; _ } | Board.Deletion_unobserved
    | Board.Deletion_pending _ | Board.Deletion_unsettled _ | Board.Deletion_refused _
    | Board.Deletion_projection_failed _ -> Alcotest.fail "known retirement lost")
  else (
    expect_progress store Board.Decision_recorded;
    check_bytes "record cleanup stops before model/snapshot work" before;
    ignore (require (Board.get_comment store ~comment_id:(Board.Comment_id.to_string reply.id)));
    Board.flush_dirty store;
    check_removed store parent reply);
  check_removed (fresh base_path) parent reply

let test_unknown_retirement base_path =
  let armed = ref false and saw_record = ref false and calls = ref 0 and marker_path = ref "" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ ->
      if Sys.file_exists !marker_path then saw_record := true;
      if !armed && !saw_record && not (Sys.file_exists !marker_path) then (
        armed := false; raise (Sys_error "retirement parent sync failed")));
    close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  marker_path := marker store;
  require (Board.initialize_store store);
  let parent, reply = seed store in
  armed := true;
  (match require (Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_decision_pending _ -> Alcotest.fail "unknown retirement misclassified");
  check_removed store parent reply;
  (match store.deletion_state with
   | Board.Deletion_unsettled { attempt = Board.Retiring_decision _; _ } -> ()
   | Board.Deletion_unsettled { attempt = Board.Recording_decision _; _ }
   | Board.Deletion_unobserved | Board.Deletion_readable _ | Board.Deletion_pending _
   | Board.Deletion_refused _ | Board.Deletion_projection_failed _ -> Alcotest.fail "retirement uncertainty lost");
  let calls_before = !calls in
  Board.flush_dirty store;
  Alcotest.(check int) "unknown retirement is never replayed" calls_before !calls;
  check_removed (fresh base_path) parent reply

let test_last_source_cleanup base_path =
  let armed = ref false and calls = ref 0 and lock_path = ref None in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      incr calls;
      let stat = Unix.fstat fd in
      let lock = Option.map Unix.lstat !lock_path in
      Unix.close fd;
      match !armed, lock with
      | true, Some lock when same_inode stat lock -> armed := false; raise Eio.Time.Timeout
      | false, (None | Some _) | true, (None | Some _) -> ()) } in
  let store = Board.create_store_with_reactions_io_for_testing ~base_path ~io () in
  require (Board.initialize_store store);
  let parent, reply = seed store in
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.reactions_path store));
  armed := true;
  (match Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok _ | Error _ -> Alcotest.fail "last source cleanup cause swallowed"
   | exception Eio.Time.Timeout -> ());
  expect_progress store Board.Sources_written;
  Alcotest.(check bool) "reserved last-source settlement stops retirement IO" true (Sys.file_exists (marker store));
  let before = snapshots store and calls_before = !calls in
  Board.flush_dirty store;
  check_bytes "retirement does not rewrite known sources" before;
  Alcotest.(check int) "known last source is not replayed" calls_before !calls;
  Alcotest.(check bool) "subsequent flush retires marker" false (Sys.file_exists (marker store));
  check_removed (fresh base_path) parent reply

let test_retirement_then_new_dirty_work base_path =
  let obstruct = ref false and marker_path = ref "" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd in
      let lock_path = Fs_compat.private_jsonl_lock_path !marker_path in
      let lock = Unix.lstat lock_path in
      Unix.close fd;
      if !obstruct && same_inode stat lock && Sys.file_exists !marker_path then (
        obstruct := false; Unix.chmod lock_path 0o400)) } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  marker_path := marker store;
  require (Board.initialize_store store);
  let room = require (Board.create_sub_board store ~slug:"recovery-room" ~name:"Recovery room"
    ~description:"retirement and pending hearth unlink" ~owner:"deletion-owner" ()) in
  let survivor = post ~hearth:room.slug store "surviving hearth owner" in
  let parent, reply = seed store in
  obstruct := true;
  (match require (Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_decision_pending _ -> Alcotest.fail "expected proven nonwrite at retirement");
  expect_progress store Board.Sources_written;
  let later = require (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator store
    ~lookup:Recipient_lookup.none_declared ~post_id:(Board.Post_id.to_string survivor.id)
    ~author:"later-reader" ~content:"accepted after source persistence" ()) in
  Alcotest.(check bool) "later reply creates real subsequent dirty work" true store.dirty_posts;
  Unix.chmod (Fs_compat.private_jsonl_lock_path !marker_path) 0o600;
  Board.flush_dirty store;
  Alcotest.(check bool) "single shutdown flush also writes new dirty work" false store.dirty_posts;
  let restarted = fresh base_path in
  check_removed restarted parent reply;
  let kept = read_post restarted (Board.Post_id.to_string survivor.id) in
  Alcotest.(check (option string)) "unrelated hearth remains attached" (Some room.slug) kept.hearth;
  Alcotest.(check int) "later reply counter survives the same shutdown flush" 1 kept.reply_count;
  Alcotest.(check bool) "later reply row remains after restart" true
    (Hashtbl.mem restarted.Board.comments (Board.Comment_id.to_string later.id))

let test_invalid_marker base_path =
  let store = fresh base_path in
  let parent, _ = seed store in
  let bad = "{\"version\":1,\"decision_id\":\"unknown\"}\n" in
  let observed = Result.get_ok (Fs_compat.read_private_jsonl_durable_locked_result (marker store) ~after:None) in
  ignore (Result.get_ok (Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
    (marker store) ~expected:observed bad));
  let before = snapshots store in
  let restarted = Board.create_store ~base_path () in
  Alcotest.(check bool) "invalid marker refuses common initialization" true
    (Result.is_error (Board.initialize_store restarted));
  Alcotest.(check bool) "invalid marker cannot admit a new deletion" true
    (Result.is_error (Board.delete_post restarted ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id)));
  Board.flush_dirty restarted;
  check_bytes "invalid decision preserves every data source" before;
  Alcotest.(check string) "invalid decision bytes are retained" bad (Fs_compat.load_file (marker store))

let test_changed_comment_parent base_path =
  let armed = ref false and calls = ref 0 in
  let marker_path = Paths.file_path ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path) Paths.Deletion in
  let io = reserved_marker_io ~retirement:false marker_path armed calls in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  require (Board.initialize_store store);
  let parent, reply = seed store in
  let other = post store "another parent owns the observed comment ID" in
  armed := true;
  (match Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok _ | Error _ -> Alcotest.fail "expected interruption after original decision recording"
   | exception Eio.Time.Timeout -> ());
  let path = Board.comments_path store in
  let observed = Result.get_ok (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None) in
  let changed = Yojson.Safe.to_string (Board.comment_to_yojson { reply with post_id = other.id }) ^ "\n" in
  ignore (Result.get_ok (Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result path ~expected:observed changed));
  let before = snapshots store in
  let restarted = Board.create_store ~base_path () in
  Alcotest.(check bool) "fresh recovery refuses a captured ID with a different parent" true
    (Result.is_error (Board.initialize_store restarted));
  check_bytes "ownership refusal precedes every data snapshot write" before;
  ignore (read_post restarted (Board.Post_id.to_string parent.id));
  let kept = require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id)) in
  Alcotest.(check string) "other thread keeps its accepted comment" (Board.Post_id.to_string other.id)
    (Board.Post_id.to_string kept.post_id);
  expect_progress restarted Board.Decision_recorded;
  Alcotest.(check bool) "original decision remains available for diagnosis" true (Sys.file_exists marker_path)

let author_authority () = Board.Author_deletion {
  reader = Masc_board_handlers.Board_access.named "deletion-owner";
  author = require (Board.Agent_id.of_string "deletion-owner") }

let transfer store (parent : Board.post) =
  ignore (require (Board.update_post_with_outcome store ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~editor:"deletion-owner" ~content:parent.body
    ~new_author:"next-owner" ()))

let check_owner store (parent : Board.post) owner =
  let kept = read_post store (Board.Post_id.to_string parent.id) in
  Alcotest.(check string) "accepted post ownership survives" owner (Board.Agent_id.to_string kept.author)

let test_stale_author_refuses_before_record base_path =
  let stale = fresh base_path in
  let parent, reply = seed stale in
  let authorization = author_authority () in
  let other = fresh base_path in
  transfer other parent;
  let before = snapshots other in
  (match Board.delete_post stale ~authorization ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "stale author recorded a deletion decision");
  Alcotest.(check bool) "stale guard never creates a marker" false (Sys.file_exists (marker stale));
  (* [other] rewrote the posts file, so [stale] no longer has source authority
     and an evidence read is refused. Its cached display is what the refused
     request must leave alone. *)
  let displayed = match Board.read_post stale ~post_id:(Board.Post_id.to_string parent.id) with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.show_board_read_error error) in
  Alcotest.(check string) "refused request leaves the stale display on its old owner"
    "deletion-owner" (Board.Agent_id.to_string displayed.author);
  check_bytes "stale request preserves foreign ownership and every dependent source" before;
  Board.flush_dirty stale;
  check_bytes "ordinary flush does not replay refused request" before;
  let restarted = fresh base_path in
  check_owner restarted parent "next-owner";
  ignore (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id)))

let test_original_actor_rechecked_after_transfer base_path =
  let store = fresh base_path in
  let parent, _ = seed store in
  let authorization = author_authority () in
  (* The request authority was captured while the original author still owned this post.
     A same-store edit can finish before the deletion enters persistence. *)
  transfer store parent;
  let before = snapshots store in
  (match Board.delete_post store ~authorization ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Unauthorized _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "original actor was replaced by the new post owner");
  Alcotest.(check bool) "authorization refusal creates no marker" false (Sys.file_exists (marker store));
  check_bytes "same-store authorization refusal leaves all bytes intact" before;
  check_owner (fresh base_path) parent "next-owner"

let test_unknown_transfer_refuses_same_store_deletion base_path =
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if !armed then (
      armed := false; raise (Sys_error "ownership rewrite parent sync failed")));
    close_fd = Unix.close } in
  let store = Board.create_store_with_source_io_for_testing ~base_path ~io:{ posts = Some io } () in
  require (Board.initialize_store store);
  let parent, _ = seed store in
  armed := true;
  (match Board.update_post_with_outcome store ~lookup:Recipient_lookup.none_declared
      ~post_id:(Board.Post_id.to_string parent.id) ~editor:"deletion-owner" ~content:parent.body
      ~new_author:"next-owner" () with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "real parent-sync failure did not leave the ownership write unknown");
  let displayed = match Board.read_post store ~post_id:(Board.Post_id.to_string parent.id) with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.show_board_read_error error) in
  Alcotest.(check string) "display retains the old owner without source authority"
    "deletion-owner" (Board.Agent_id.to_string displayed.author);
  let before = snapshots store in
  (match Board.delete_post store ~authorization:(author_authority ())
      ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "unknown source authorized a same-store deletion");
  Alcotest.(check bool) "unknown source creates no deletion authority" false
    (Sys.file_exists (marker store));
  check_bytes "refusal preserves the published ownership change" before;
  let restarted = fresh base_path in
  check_owner restarted parent "next-owner";
  (match Board.delete_post restarted ~authorization:(author_authority ())
      ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Unauthorized _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "fresh ownership authorized the original actor");
  check_bytes "fresh authorization refusal preserves all source bytes" before

type readset_guard = Posts_guard | Comments_guard

let test_readset_guard_cleanup_keeps_known_decision target base_path =
  let armed = ref false and captured = ref None in
  let file = match target with Posts_guard -> Paths.Posts | Comments_guard -> Paths.Comments in
  let source_path = Paths.file_path ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path) file in
  let lock_path = Fs_compat.private_jsonl_lock_path source_path in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd and lock = Unix.lstat lock_path in
      Unix.close fd;
      if !armed && same_inode stat lock then (
        armed := false;
        try raise Eio.Time.Timeout with exception_ ->
          let backtrace = Printexc.get_raw_backtrace () in
          captured := Some backtrace;
          Printexc.raise_with_backtrace exception_ backtrace)) } in
  let store = match target with
    | Posts_guard -> Board.create_store_with_source_io_for_testing ~base_path ~io:{ posts = Some io } ()
    | Comments_guard -> Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  require (Board.initialize_store store);
  let parent, reply = seed store in
  let before = snapshots store in
  armed := true;
  (match Board.delete_post store ~authorization:(author_authority ())
      ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok _ | Error _ -> Alcotest.fail "reserved guard cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  expect_progress store Board.Decision_recorded;
  check_owner store parent "deletion-owner";
  check_bytes "known marker plus guard cleanup stops before model and snapshots" before;
  (match store.deletion_state with
   | Board.Deletion_pending work ->
     Alcotest.(check bool) "guard retains original path, cause and backtrace" true
       (List.exists (function
          | Board.Deletion_guard_diagnostic guard ->
            (match guard.guard_error with
             | Fs_compat.Private_jsonl_operation_failed failure ->
            String.equal guard.guard_path source_path && failure.operation = Fs_compat.Close_stable_lock
            && (match failure.exception_ with Eio.Time.Timeout -> true | _ -> false)
            && (match !captured with None -> false | Some backtrace ->
              let length = Printexc.raw_backtrace_length backtrace in
              length > 0 && Printexc.raw_backtrace_length failure.backtrace >= length
              && List.for_all (fun index ->
                Printexc.get_raw_backtrace_slot backtrace index
                = Printexc.get_raw_backtrace_slot failure.backtrace index) (List.init length Fun.id))
             | (Fs_compat.Stable_lock_contended _
               | Fs_compat.Unexpected_stable_lock_permissions _
               | Fs_compat.Invalid_stable_lock_state _
               | Fs_compat.Cursor_mismatch _
               | Fs_compat.Unexpected_transaction_file_kind _
               | Fs_compat.Ambiguous_transaction_file_identity _
               | Fs_compat.Transaction_path_binding_changed _
               | Fs_compat.Transaction_content_changed _
               | Fs_compat.Incomplete_transaction_tail _
               | Fs_compat.Invalid_transaction_suffix
               | Fs_compat.Rewrite_stage_failed _
               | Fs_compat.Rewrite_published_durability_unknown _
               | Fs_compat.Transaction_settlement_failed _
               | Fs_compat.Transaction_append_failed _) -> false)
          | Board.Deletion_file_diagnostic _
          | Board.Deletion_workspace_diagnostic _ | Board.Deletion_raised_diagnostic _ -> false)
         work.decision_receipt.decision_cleanup)
   | Board.Deletion_unobserved | Board.Deletion_readable _ | Board.Deletion_unsettled _
   | Board.Deletion_refused _ | Board.Deletion_projection_failed _ -> Alcotest.fail "known receipt lost");
  Board.flush_dirty store;
  check_removed store parent reply;
  check_removed (fresh base_path) parent reply

let test_later_child_after_decision base_path =
  let armed = ref false and calls = ref 0 in
  let marker_path = Paths.file_path ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path) Paths.Deletion in
  let io = reserved_marker_io ~retirement:false marker_path armed calls in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  require (Board.initialize_store store);
  let parent, original_reply = seed store in
  let other = fresh base_path in
  armed := true;
  (match Board.delete_post store ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok _ | Error _ -> Alcotest.fail "expected interruption after the fixed decision"
   | exception Eio.Time.Timeout -> ());
  expect_progress store Board.Decision_recorded;
  Alcotest.(check bool) "original decision exists before foreign append" true (Sys.file_exists marker_path);
  let later = require (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator other ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~author:"late-reader"
    ~content:"accepted after the fixed decision" ()) in
  let comment_id = Board.Comment_id.to_string later.id in
  ignore (require (Board.vote_comment other ~reader:Masc_board_handlers.Board_access.Operator ~comment_id ~voter:"late-voter" ~direction:Board.Up));
  ignore (require (Board.toggle_reaction other ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_comment
    ~target_id:comment_id ~user_id:"late-reactor" ~emoji:"👍"));
  let before = List.map (fun path -> path, Fs_compat.load_file path)
    [Board.comments_path other; Board.vote_log_path other; Board.reactions_path other] in
  Board.flush_dirty store;
  check_bytes "stale comments snapshot preserves the later child and its dependents" before;
  let restarted = fresh base_path in
  check_removed restarted parent original_reply;
  let kept = require (Board.get_comment restarted ~comment_id) in
  Alcotest.(check string) "later accepted child survives original decision recovery" later.content kept.content;
  Alcotest.(check int) "later child's vote survives" 1 kept.votes_up;
  Alcotest.(check bool) "later child retains its parent index" true
    (match Hashtbl.find_opt restarted.comments_by_post (Board.Post_id.to_string parent.id) with
     | None -> false | Some ids -> List.mem comment_id ids);
  let reactions = require (Board.list_reactions restarted ~target_type:Board.Reaction_comment
    ~target_id:comment_id ()) in
  Alcotest.(check bool) "later child's reaction survives" true
    (List.exists (fun (summary : Board.reaction_summary) ->
       String.equal summary.emoji "👍" && summary.count = 1) reactions);
  Alcotest.(check bool) "original decision can retire after preserving later child" false
    (Sys.file_exists marker_path)

let test_comments_refusal_and_parent_cleanup base_path =
  let armed = ref false in
  let posts_path = Paths.file_path ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path) Paths.Posts in
  let lock_path = Fs_compat.private_jsonl_lock_path posts_path in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> ());
    close_fd = (fun fd ->
      let stat = Unix.fstat fd and lock = Unix.lstat lock_path in
      Unix.close fd;
      if !armed && same_inode stat lock then (armed := false; raise Eio.Time.Timeout)) } in
  let store = Board.create_store_with_source_io_for_testing ~base_path ~io:{ posts = Some io } () in
  require (Board.initialize_store store);
  let parent, _ = seed store in
  let other = fresh base_path in
  let foreign = require (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator other ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string parent.id) ~author:"foreign-reader"
    ~content:"accepted before the deletion decision" ()) in
  let before = snapshots other in
  armed := true;
  (match Board.delete_post store ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok _ | Error _ -> Alcotest.fail "outer reserved cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  (match store.deletion_state with
   | Board.Deletion_readable { plan = None; diagnostics; _ } ->
     let paths = List.filter_map (function
       | Board.Deletion_guard_diagnostic failure -> Some failure.guard_path
       | Board.Deletion_file_diagnostic _ | Board.Deletion_workspace_diagnostic _
       | Board.Deletion_raised_diagnostic _ -> None) diagnostics in
     Alcotest.(check (list string)) "inner refusal and outer cleanup retain both actual paths"
       [Board.comments_path store; posts_path] paths
   | Board.Deletion_unobserved | Board.Deletion_readable { plan = Some _; _ }
   | Board.Deletion_pending _ | Board.Deletion_unsettled _ | Board.Deletion_refused _
   | Board.Deletion_projection_failed _ -> Alcotest.fail "refused inner guard became an executed marker");
  Alcotest.(check bool) "refused read-set never creates marker" false (Sys.file_exists (marker store));
  check_bytes "pre-decision refusal preserves every accepted source" before;
  let restarted = fresh base_path in
  ignore (read_post restarted (Board.Post_id.to_string parent.id));
  ignore (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string foreign.id)))

let competing_comments_append path row =
  match Fs_compat.append_private_jsonl_durable_stable_result path row with
  | Error (Fs_compat.Stable_lock_contended _) -> 0
  | Error _ -> 2
  | Ok _ -> 3

let test_comments_guard_spans_marker_io base_path =
  let armed = ref false and comment_row = ref "" in
  let workspace_masc_dir = Common.masc_dir_from_base_path ~base_path in
  let comments_path = Paths.file_path ~workspace_masc_dir Paths.Comments in
  let marker_path = Paths.file_path ~workspace_masc_dir Paths.Deletion in
  let receipt_path = Filename.concat base_path "comment-contention.txt" in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ ->
      if !armed && Sys.file_exists marker_path then (
        armed := false;
        (* Exec gives the competitor a fresh in-process mutex registry. This
           runs only after marker rename, while its parent sync is pending. *)
        let pid = Unix.create_process Sys.executable_name
          [| Sys.executable_name; "--contend-comments"; comments_path; !comment_row |]
          Unix.stdin Unix.stdout Unix.stderr in
        let _, status = Unix.waitpid [] pid in
        let observed = match status with
          | Unix.WEXITED 0 -> "contended\n"
          | Unix.WEXITED _ -> "not-contended\n"
          | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> "competitor-failed\n" in
        Out_channel.with_open_bin receipt_path (fun output -> output_string output observed)));
    close_fd = Unix.close } in
  let store = Board.create_store_with_deletion_io_for_testing ~base_path ~io () in
  require (Board.initialize_store store);
  let parent, reply = seed store in
  comment_row := Yojson.Safe.to_string (Board.comment_to_yojson reply) ^ "\n";
  armed := true;
  (match require (Board.delete_post store ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Durable_deletion -> ()
   | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail);
  Alcotest.(check string) "real comments stable lock excludes writer through marker IO" "contended\n"
    (In_channel.with_open_bin receipt_path In_channel.input_all);
  check_removed (fresh base_path) parent reply

let run_cases () = Alcotest.run "board_deletion_recovery"
  ["real files, interruption and restart", [
    Alcotest.test_case "unknown record does not apply and fresh startup recovers" `Quick (with_fixture test_unknown_record);
    Alcotest.test_case "known record survives reserved cleanup before model work" `Quick (with_fixture (test_reserved_marker false));
    Alcotest.test_case "known retirement survives reserved cleanup" `Quick (with_fixture (test_reserved_marker true));
    Alcotest.test_case "unknown retirement is not replayed" `Quick (with_fixture test_unknown_retirement);
    Alcotest.test_case "last source cleanup stops before marker retirement" `Quick (with_fixture test_last_source_cleanup);
    Alcotest.test_case "retirement flush also saves later reply" `Quick (with_fixture test_retirement_then_new_dirty_work);
    Alcotest.test_case "invalid decision preserves source bytes" `Quick (with_fixture test_invalid_marker);
    Alcotest.test_case "captured comment belonging to another thread is preserved" `Quick (with_fixture test_changed_comment_parent);
    Alcotest.test_case "stale author cannot record a deletion after foreign ownership transfer" `Quick
      (with_fixture test_stale_author_refuses_before_record);
    Alcotest.test_case "original request actor is rechecked after same-store transfer" `Quick
      (with_fixture test_original_actor_rechecked_after_transfer);
    Alcotest.test_case "unknown ownership transfer refuses deletion until fresh loading" `Quick
      (with_fixture test_unknown_transfer_refuses_same_store_deletion);
    Alcotest.test_case "reserved parent guard cleanup retains known decision before model" `Quick
      (with_fixture (test_readset_guard_cleanup_keeps_known_decision Posts_guard));
    Alcotest.test_case "reserved comments guard cleanup retains known decision before model" `Quick
      (with_fixture (test_readset_guard_cleanup_keeps_known_decision Comments_guard));
    Alcotest.test_case "only a comment accepted after decision remains outside its fixed IDs" `Quick
      (with_fixture test_later_child_after_decision);
    Alcotest.test_case "comments refusal plus outer cleanup leaves marker unrecorded" `Quick
      (with_fixture test_comments_refusal_and_parent_cleanup);
    Alcotest.test_case "comments lock spans actual marker publication" `Quick
      (with_fixture test_comments_guard_spans_marker_io)
  ]]

let () = match Array.to_list Sys.argv with
  | [_; "--contend-comments"; path; row] -> exit (competing_comments_append path row)
  | _ -> run_cases ()
