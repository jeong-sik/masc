(** Delete durability and rewrite retry (#26169).

    [Board.delete_post] is authoritative in memory: it removes the post and
    its comments, clears the dirty flags, then rewrites the four jsonl
    snapshots. Before the re-mark landed, a failed rewrite ended there — the
    dirty flags were already clear, so no later flush rewrote the files and
    the deleted post resurfaced from disk on restart. [flush_dirty] had
    received the same fix in #26168; this suite pins the delete half:

    - a delete whose snapshot rewrite fails reports an applied, persistence
      pending outcome, invalidates projections once, and leaves
      the store dirty, so the next flush repeats the rewrite;
    - after the disk is healthy again, that flush writes the post file
      without the deleted post — no resurrection. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-delete-rq-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p dir;
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(* Replaces the board's [.masc] directory with a regular file so any
   subsequent write under it raises [Sys_error] (ENOTDIR). Same fixture as
   [test_board_vote_persistence.ml], duplicated per the suite's per-file
   convention. *)
(* Deny board writes through permissions instead of breaking the workspace
   boundary: the store files lose their write bits (append fails) and the
   workspace directory loses create/rename rights (the rewrite stage fails),
   while reads and workspace observation keep working. The earlier fixture
   replaced .masc with a regular file, which made the posts source re-observe
   a refused workspace and latch Posts_refused — every write then stayed
   refused even after the fixture restored the directory (#47727). *)
let with_blocked_board_masc_dir f =
  (* Root ignores file permission bits, so a permission-denied fixture would
     silently stop denying writes and the blocked-phase assertions would
     fail for the opposite reason. The previous regular-file fixture stayed
     effective under root; this one skips instead of lying. *)
  if Unix.geteuid () = 0 then Alcotest.skip ();
  let store = Board.global () in
  let masc_dir = (Board.workspace_masc_dir store) in
  let paths =
    [ Board.persist_path store; Board.comments_path store; Board.vote_log_path store
    ; Board.reactions_path store; Board.sub_boards_path store ]
  in
  List.iter Fs_compat.invalidate_cached_writer paths;
  let file_modes =
    List.filter_map
      (fun path ->
         if Sys.file_exists path then Some (path, (Unix.stat path).Unix.st_perm) else None)
      paths
  in
  let dir_mode = (Unix.stat masc_dir).Unix.st_perm in
  List.iter (fun (path, _) -> Unix.chmod path 0o444) file_modes;
  Unix.chmod masc_dir 0o555;
  Fun.protect
    ~finally:(fun () ->
      Unix.chmod masc_dir dir_mode;
      List.iter (fun (path, mode) -> Unix.chmod path mode) file_modes;
      List.iter Fs_compat.invalidate_cached_writer paths)
    f

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  f ()

let store () = Board_dispatch.backend ()

let refuse_posts_source () =
  let active = store () in
  let path = Board.persist_path active in
  let original = In_channel.with_open_bin path In_channel.input_all in
  Out_channel.with_open_gen [Open_wronly; Open_append; Open_binary] 0o600 path
    (fun out -> output_string out "{invalid-post-source\n");
  Alcotest.(check bool) "actual malformed posts source fails reload" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_posts active));
  fun () ->
    Out_channel.with_open_bin path (fun out -> output_string out original);
    match Masc_board_handlers.Board_votes_json.load_persisted_posts active with
    | Ok _ -> ()
    | Error (failed_path, cause) ->
      Alcotest.failf "repaired posts reload failed: %s (%s)"
        failed_path (Printexc.to_string cause)

let create_post_exn ~content =
  match
    Board_dispatch.create_post ~author:"delete-rq-author" ~content
      ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.Post_publication_failure.to_string e)

let flush () = Board.flush_dirty (Board_dispatch.backend ())

let post_rows () = Fs_compat.load_jsonl (Board.persist_path (Board.global ()))

(* A row is the post when its own [id] field is the id -- not when the id
   happens to appear anywhere in the row's text (a body or a reply-to field
   could carry it and pass a substring search). *)
let row_has_post_id post_id rows =
  List.exists
    (fun json ->
       match json with
       | `Assoc fields ->
         (match List.assoc_opt "id" fields with
          | Some (`String id) -> String.equal id post_id
          | Some _ | None -> false)
       | _ -> false)
    rows

let check_post_deleted label post_id =
  match Board_dispatch.get_post ~post_id with
  | Error (Board.Post_not_found _) -> ()
  | Error error -> Alcotest.fail (label ^ ": " ^ Board.show_board_error error)
  | Ok _ -> Alcotest.fail (label ^ ": the applied deletion was lost")

let test_delete_rewrite_failure_keeps_resurrection_scheduled () =
  let doomed = create_post_exn ~content:"deleted while the disk is broken" in
  let survivor = create_post_exn ~content:"stays and gets re-marked dirty" in
  let doomed_id = Board.Post_id.to_string doomed.id in
  let survivor_id = Board.Post_id.to_string survivor.id in
  flush ();
  Alcotest.(check bool)
    "flushed clean before the delete" false (store ()).Board.dirty_posts;
  with_blocked_board_masc_dir (fun () ->
  let writes = ref 0 in
  Board_dispatch.set_board_sse_hook (function
    | Board_dispatch.Post_changed _ -> incr writes
    | _ -> ());
  (match Board_dispatch.delete_post ~post_id:doomed_id with
   | Ok (Board.Deletion_persistence_pending detail) ->
     Alcotest.(check bool) "pending outcome carries the persistence failure" true
       (String.length detail > 0)
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok Board.Durable_deletion ->
     Alcotest.fail "failed snapshot rewrites must not report durable deletion");
  Alcotest.(check int) "applied deletion is announced once" 1 !writes;
  (match Board_dispatch.delete_post ~post_id:doomed_id with
   | Error (Board.Post_not_found _) -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok _ -> Alcotest.fail "deletion retry cannot persist an already absent post");
  Alcotest.(check int) "refused retry emits no second transition" 1 !writes;
  Alcotest.(check bool)
    "failed rewrite re-marked the store dirty" true (store ()).Board.dirty_posts;
  Alcotest.(check bool)
    "failed rewrite re-marked comments dirty too" true
    (store ()).Board.dirty_comments
  (* Disk healthy again: the re-marked store schedules the rewrite, and the
     flush below is what performs it. *)
  );
  flush ();
  let rows = post_rows () in
  Alcotest.(check bool)
    "deleted post does not resurrect in the post file" false
    (row_has_post_id doomed_id rows);
  Alcotest.(check bool)
    "surviving post is still on disk" true (row_has_post_id survivor_id rows);
  Alcotest.(check bool)
    "flush after the successful rewrite is clean" false (store ()).Board.dirty_posts;
  Alcotest.(check bool)
    "comments are clean after the successful rewrite" false
    (store ()).Board.dirty_comments

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let test_individual_snapshot_failure path () =
  let doomed = create_post_exn ~content:"delete the final post and all dependent rows" in
  let post_id = Board.Post_id.to_string doomed.id in
  ignore
    (require_ok
       (Board_dispatch.add_comment ~post_id ~author:"comment-author"
          ~content:"dependent reply" ()));
  ignore (require_ok (Board_dispatch.vote ~post_id ~voter:"voter" ~direction:Board.Up));
  ignore
    (require_ok
       (Board_dispatch.toggle_reaction ~target_type:Board.Reaction_post
          ~target_id:post_id ~user_id:"reactor" ~emoji:"👍"));
  flush ();
  let active = store () in
  let path = path (store ()) in
  let posts_obstructed = String.equal path (Board.persist_path active) in
  let backup = path ^ ".before-delete" in
  Unix.rename path backup;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir path; Unix.rename backup path)
    (fun () ->
      (match Board_dispatch.delete_post ~post_id with
       | Ok (Board.Deletion_persistence_pending _) -> ()
       | Error error -> Alcotest.fail (Board.show_board_error error)
       | Ok Board.Durable_deletion ->
         Alcotest.fail "one failed snapshot must refuse durable deletion");
      Alcotest.(check bool) "failed final snapshot stays scheduled" true
        ((store ()).Board.dirty_posts || (store ()).Board.dirty_comments));
  Alcotest.(check bool) "retry retains the original store" true (active == store ());
  check_post_deleted "deletion remains applied before retry" post_id;
  if posts_obstructed then
    Alcotest.(check bool) "restored old posts file still contains the doomed row" true
      (row_has_post_id post_id (post_rows ()));
  flush ();
  Alcotest.(check bool) "successful retry uses the original store" true (active == store ());
  check_post_deleted "retry does not reload the doomed post" post_id;
  Alcotest.(check bool) "retry removes the doomed row from the actual posts file" false
    (row_has_post_id post_id (post_rows ()));
  Alcotest.(check bool) "successful retry clears posts work" false active.Board.dirty_posts;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let restored = store () in
  Alcotest.(check int) "restart has no deleted posts" 0 (Hashtbl.length restored.posts);
  Alcotest.(check int) "restart has no deleted replies" 0 (Hashtbl.length restored.comments);
  Alcotest.(check int) "restart has no deleted votes" 0 (Hashtbl.length restored.vote_log);
  Alcotest.(check int) "restart has no deleted reactions" 0 (Hashtbl.length restored.reactions)

let test_multiple_snapshot_failures_keep_healthy_writes_and_retry () =
  let doomed = create_post_exn ~content:"delete despite independent snapshot failures" in
  let post_id = Board.Post_id.to_string doomed.id in
  ignore
    (require_ok
       (Board_dispatch.add_comment ~post_id ~author:"comment-author"
          ~content:"dependent reply" ()));
  ignore (require_ok (Board_dispatch.vote ~post_id ~voter:"voter" ~direction:Board.Up));
  ignore
    (require_ok
       (Board_dispatch.toggle_reaction ~target_type:Board.Reaction_post
          ~target_id:post_id ~user_id:"reactor" ~emoji:"👍"));
  flush ();
  Alcotest.(check int) "comment is on disk before deletion" 1
    (List.length (Fs_compat.load_jsonl (Board.comments_path (Board.global ()))));
  Alcotest.(check int) "reaction is on disk before deletion" 1
    (List.length (Fs_compat.load_jsonl (Board.reactions_path (Board.global ()))));
  let active = store () in
  let with_blocked_path path f =
    let backup = path ^ ".before-delete" in
    Unix.rename path backup;
    Unix.mkdir path 0o700;
    Fun.protect
      ~finally:(fun () -> Unix.rmdir path; Unix.rename backup path)
      f
  in
  with_blocked_path (Board.persist_path (Board.global ())) (fun () ->
    with_blocked_path (Board.vote_log_path (Board.global ())) (fun () ->
      let errors_before = Board.persist_error_count () in
      (match Board_dispatch.delete_post ~post_id with
       | Ok (Board.Deletion_persistence_pending _) -> ()
       | Error error -> Alcotest.fail (Board.show_board_error error)
       | Ok Board.Durable_deletion ->
         Alcotest.fail "failed snapshots must leave deletion persistence pending");
      Alcotest.(check int) "both failed writes are counted" 2
        (Board.persist_error_count () - errors_before);
      Alcotest.(check string) "comments are removed before repair" ""
        (Fs_compat.load_file (Board.comments_path (Board.global ())));
      Alcotest.(check string) "reactions are removed before repair" ""
        (Fs_compat.load_file (Board.reactions_path (Board.global ())))));
  Alcotest.(check bool) "multiple failures retain the original store" true
    (active == store ());
  check_post_deleted "multiple failures keep deletion applied before retry" post_id;
  Alcotest.(check bool) "restored posts still contain the pending-deletion row" true
    (row_has_post_id post_id (post_rows ()));
  flush ();
  Alcotest.(check bool) "multiple-failure retry uses the original store" true
    (active == store ());
  check_post_deleted "multiple-failure retry does not reload the doomed post" post_id;
  Alcotest.(check bool) "multiple-failure retry removes the actual doomed row" false
    (row_has_post_id post_id (post_rows ()));
  Alcotest.(check bool) "multiple-failure retry clears posts work" false
    active.Board.dirty_posts;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let restored = store () in
  Alcotest.(check int) "restart has no deleted posts" 0 (Hashtbl.length restored.posts);
  Alcotest.(check int) "restart has no deleted replies" 0 (Hashtbl.length restored.comments);
  Alcotest.(check int) "restart has no deleted votes" 0 (Hashtbl.length restored.vote_log);
  Alcotest.(check int) "restart has no deleted reactions" 0 (Hashtbl.length restored.reactions)

let test_obstructed_delete_retry_refuses_changed_same_cursor_bytes () =
  let doomed = create_post_exn ~content:"body-aaaa" in
  let post_id = Board.Post_id.to_string doomed.id in
  flush ();
  let active = store () in
  let path = Board.persist_path active in
  let before = In_channel.with_open_bin path In_channel.input_all in
  let original_stat = Unix.stat path in
  let changed_row = Board.post_to_yojson { doomed with body = "body-bbbb" } in
  let changed = Yojson.Safe.to_string changed_row ^ "\n" in
  Alcotest.(check int) "external edit keeps the accepted source length"
    (String.length before) (String.length changed);
  Alcotest.(check bool) "external edit changes actual source bytes" false
    (String.equal before changed);
  let backup = path ^ ".before-delete" in
  Fs_compat.invalidate_cached_writer path;
  Unix.rename path backup;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.invalidate_cached_writer path;
      Unix.rmdir path;
      Unix.rename backup path)
    (fun () ->
      (match Board_dispatch.delete_post ~post_id with
       | Ok (Board.Deletion_persistence_pending _) -> ()
       | Error error -> Alcotest.fail (Board.show_board_error error)
       | Ok Board.Durable_deletion ->
         Alcotest.fail "the obstructed posts snapshot must remain pending");
      check_post_deleted "deletion applies while the source is obstructed" post_id;
      Alcotest.(check bool) "obstructed deletion leaves real retry work" true
        active.Board.dirty_posts;
      (* Change the real saved file without replacing its inode or extending
         it. Restoring the path therefore defeats cursor-only validation. *)
      Out_channel.with_open_gen [Open_wronly; Open_binary] 0o600 backup
        (fun out -> output_string out changed));
  let restored_stat = Unix.stat path in
  Alcotest.(check (pair int int)) "restoration retains the exact source inode"
    (original_stat.Unix.st_dev, original_stat.Unix.st_ino)
    (restored_stat.Unix.st_dev, restored_stat.Unix.st_ino);
  Alcotest.(check int) "restoration retains the exact source length"
    original_stat.Unix.st_size restored_stat.Unix.st_size;
  (match post_rows () with
   | [row] ->
     (match Board.post_of_yojson row with
      | Some saved ->
        Alcotest.(check string) "restored row is a valid edit of the actual doomed post"
          post_id (Board.Post_id.to_string saved.id);
        Alcotest.(check string) "restored row contains the changed body"
          "body-bbbb" saved.body
      | None -> Alcotest.fail "the external edit must remain a valid current post row")
   | rows -> Alcotest.failf "expected one real restored post row, got %d" (List.length rows));
  check_post_deleted "restoration does not reload the pending-deleted model" post_id;
  flush ();
  (* Observe the actual flush refusal through the public opaque snapshot/save
     contract, without setting a health cell or adopting the changed source. *)
  let retry = Board.with_persist_lock active (fun () ->
    let snapshot = Board.with_lock active (fun () -> Board.capture_posts_snapshot active) in
    Board.save_posts_snapshot active snapshot) in
  (match retry with
   | Board.Posts_not_written {
       failure = Board.Posts_transaction_failed (Fs_compat.Transaction_content_changed _); _ } -> ()
   | Board.Posts_not_written _ | Board.Posts_write_unknown _ | Board.Posts_written _ ->
     Alcotest.fail "retry must retain the real exact-byte CAS refusal");
  Alcotest.(check bool) "refused retry retains the original store" true (active == store ());
  check_post_deleted "refused CAS preserves the applied deletion" post_id;
  Alcotest.(check int) "refused CAS does not adopt any restored row" 0
    (Hashtbl.length active.posts);
  Alcotest.(check bool) "refused CAS retains pending deletion work" true
    active.Board.dirty_posts;
  Alcotest.(check string) "refused CAS preserves every changed disk byte" changed
    (In_channel.with_open_bin path In_channel.input_all);
  flush ();
  check_post_deleted "another flush cannot reload the doomed post" post_id;
  Alcotest.(check bool) "another refused flush retains pending work" true
    active.Board.dirty_posts;
  Alcotest.(check string) "another refused flush cannot overwrite changed bytes" changed
    (In_channel.with_open_bin path In_channel.input_all)

let test_unreadable_snapshot_refuses_before_transition () =
  let post = create_post_exn ~content:"unreadable source cannot authorize deletion" in
  let post_id = Board.Post_id.to_string post.id in
  let writes = ref 0 in
  Board_dispatch.set_board_sse_hook (function
    | Board_dispatch.Post_changed _ -> incr writes
    | _ -> ());
  let _repair_source = refuse_posts_source () in
  (match Board_dispatch.delete_post ~post_id with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "unreadable snapshot authorized a deletion");
  Alcotest.(check bool) "refused deletion keeps post" true
    (Result.is_ok (Board_dispatch.get_post ~post_id));
  Alcotest.(check int) "refusal emits no applied transition" 0 !writes

let with_blocked_reactions f =
  let path = Board.reactions_path (Board.global ()) in
  let backup = path ^ ".before-delete" in
  if not (Sys.file_exists path) then Fs_compat.save_file path "";
  Unix.rename path backup;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir path; Unix.rename backup path)
    f

let require_post_effect_failure_without_wait ~tool_name result =
  let execution = Keeper_tool_execution.of_tool_result result in
  Alcotest.(check bool) "pending persistence remains a typed post-effect failure" true
    (execution.failure_effect_disposition = Tool_result.Proven_post_effect);
  Alcotest.(check bool) "no generic deferred completion wait is invented" true
    (execution.deferred_kind = None);
  let terminal = ref Keeper_tools_agent_core.Terminal_effect_open in
  (match execution.disposition with
   | Tool_result.Failed Tool_result.Runtime_failure ->
     Keeper_tools_agent_core_bundle.For_testing.ordinary_on_failed
       ~mark_terminal_effect_failed:(fun failure ->
         terminal := Keeper_tools_agent_core.Terminal_effect_failed failure)
       Keeper_tool_descriptor.Tool_board_dispatch
       { Keeper_tools_agent_core.failure_class = Tool_result.Runtime_failure
       ; effect_disposition = execution.failure_effect_disposition
       ; detail = Keeper_terminal_effect_detail.Tool_failed
           { internal_tool_name = tool_name; message = execution.raw_output }
       }
   | Tool_result.Failed _ | Tool_result.Completed () | Tool_result.Deferred () ->
     Alcotest.fail "pending persistence must remain a runtime failure");
  match Keeper_agent_run.terminal_effect_boundary_decision !terminal with
  | Ok Runtime_agent.Continue -> ()
  | Error _ | Ok (Runtime_agent.Yield _) ->
    Alcotest.fail "ordinary Board persistence failure must reach the model without parking the turn"

let test_mcp_pending_delete_is_post_effect_failure () =
  let post = create_post_exn ~content:"tool deletion is applied before persistence" in
  let post_id = Board.Post_id.to_string post.id in
  flush ();
  with_blocked_reactions (fun () ->
    let result =
      Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client "masc_board_delete"
        (`Assoc ["post_id", `String post_id; "author", `String "delete-rq-author"])
    in
    require_post_effect_failure_without_wait ~tool_name:"masc_board_delete" result;
    let open Yojson.Safe.Util in
    let data = Tool_result.data result in
    Alcotest.(check string) "receipt names the applied deletion" post_id
      (data |> member "post_id" |> to_string);
    Alcotest.(check bool) "receipt preserves applied state" true
      (data |> member "applied" |> to_bool);
    Alcotest.(check string) "receipt preserves pending persistence" "pending"
      (data |> member "persistence" |> to_string));
  flush ()

let test_cleanup_counts_pending_separately () =
  let post = create_post_exn ~content:"old post to clean up" in
  let post_id = Board.Post_id.to_string post.id in
  let old_post = { post with Board.created_at = Time_compat.now () -. 7200.0 } in
  Board.put_post (store ()) old_post;
  Board.invalidate_post_caches (store ());
  (store ()).Board.dirty_posts <- true;
  flush ();
  with_blocked_reactions (fun () ->
    let result =
      Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
        (`Assoc ["dry_run", `Bool false; "max_age_hours", `Int 1])
    in
    require_post_effect_failure_without_wait ~tool_name:"masc_board_cleanup" result;
    let open Yojson.Safe.Util in
    let data = Tool_result.data result in
    Alcotest.(check int) "pending deletion is not durable" 0
      (data |> member "durable_deletions" |> to_int);
    Alcotest.(check int) "pending deletion is not a refused deletion" 0
      (data |> member "failed" |> to_int);
    let pending = data |> member "persistence_pending" |> to_list in
    Alcotest.(check (list string)) "pending deletion retains its post id" [post_id]
      (List.map (fun row -> row |> member "post_id" |> to_string) pending));
  flush ()

let test_cleanup_refusal_is_pre_effect () =
  let post = create_post_exn ~content:"old post with an unreadable snapshot" in
  let post_id = Board.Post_id.to_string post.id in
  Board.put_post (store ())
    { post with Board.created_at = Time_compat.now () -. 7200.0 };
  Board.invalidate_post_caches (store ());
  (store ()).Board.dirty_posts <- true;
  flush ();
  let _repair_source = refuse_posts_source () in
  let result =
    Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
      (`Assoc ["dry_run", `Bool false; "max_age_hours", `Int 1])
  in
  let execution = Keeper_tool_execution.of_tool_result result in
  Alcotest.(check bool) "all refused deletions remain pre-effect" true
    (execution.failure_effect_disposition = Tool_result.Proven_pre_effect);
  Alcotest.(check bool) "storage refusal keeps the post" true
    (Result.is_ok (Board_dispatch.get_post ~post_id));
  let open Yojson.Safe.Util in
  let data = Tool_result.data result in
  Alcotest.(check int) "cleanup counts refused deletion" 1
    (data |> member "refused_deletions" |> to_int);
  Alcotest.(check int) "refusal is not an unknown exception" 0
    (data |> member "outcome_unknown" |> to_int)

let test_cleanup_mixed_pending_and_refused_is_post_effect () =
  let pending = create_post_exn ~content:"first old post is applied" in
  let refused = create_post_exn ~content:"second old post is refused" in
  let pending_id = Board.Post_id.to_string pending.id in
  let refused_id = Board.Post_id.to_string refused.id in
  let now = Time_compat.now () in
  Board.put_post (store ())
    { pending with Board.created_at = now -. 7200.0 };
  Board.put_post (store ())
    { refused with Board.created_at = now -. 10800.0 };
  Board.invalidate_post_caches (store ());
  (store ()).Board.dirty_posts <- true;
  flush ();
  let repair_source = ref None in
  with_blocked_reactions (fun () ->
    (* The hook runs after persistence unlock, so this is a real subsequent
       source read rather than a reentrant loader under the write mutex. *)
    Board_dispatch.set_board_sse_hook (function
      | Board_dispatch.Post_changed _ ->
        repair_source := Some (refuse_posts_source ())
      | _ -> ());
    let result =
      Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
        (`Assoc ["dry_run", `Bool false; "max_age_hours", `Int 1])
    in
    require_post_effect_failure_without_wait ~tool_name:"masc_board_cleanup" result;
    let open Yojson.Safe.Util in
    let data = Tool_result.data result in
    Alcotest.(check int) "mixed cleanup counts one refused deletion" 1
      (data |> member "refused_deletions" |> to_int);
    Alcotest.(check (list string)) "mixed cleanup preserves exact pending deletion" [pending_id]
      (data |> member "persistence_pending" |> to_list
       |> List.map (fun row -> row |> member "post_id" |> to_string));
    Alcotest.(check bool) "refused post remains readable" true
      (Result.is_ok (Board_dispatch.get_post ~post_id:refused_id)));
  Board_dispatch.set_board_sse_hook (fun _ -> ());
  (match !repair_source with
   | Some repair -> repair ()
   | None -> Alcotest.fail "first applied deletion did not reach the corruption hook");
  flush ()

let () =
  Alcotest.run "board_delete_rewrite_requeue"
    [ ( "delete_post",
        [ Alcotest.test_case
            "a failed delete rewrite keeps the resurrection scheduled"
            `Quick
            (with_eio test_delete_rewrite_failure_keeps_resurrection_scheduled)
        ; Alcotest.test_case "posts rewrite remains pending and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.persist_path))
        ; Alcotest.test_case "comments rewrite remains pending and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.comments_path))
        ; Alcotest.test_case "votes rewrite remains pending and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.vote_log_path))
        ; Alcotest.test_case "reactions rewrite remains pending and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.reactions_path))
        ; Alcotest.test_case "multiple failed snapshots preserve healthy writes and retry" `Quick
            (with_eio test_multiple_snapshot_failures_keep_healthy_writes_and_retry)
        ; Alcotest.test_case "obstructed delete retry refuses changed same-cursor bytes" `Quick
            (with_eio test_obstructed_delete_retry_refuses_changed_same_cursor_bytes)
        ; Alcotest.test_case "unreadable snapshot refuses without a transition" `Quick
            (with_eio test_unreadable_snapshot_refuses_before_transition)
        ; Alcotest.test_case "MCP pending deletion is a post-effect failure" `Quick
            (with_eio test_mcp_pending_delete_is_post_effect_failure)
        ; Alcotest.test_case "cleanup counts pending separately" `Quick
            (with_eio test_cleanup_counts_pending_separately)
        ; Alcotest.test_case "cleanup refusal is pre-effect" `Quick
            (with_eio test_cleanup_refusal_is_pre_effect)
        ; Alcotest.test_case "mixed cleanup retains applied and refused outcomes" `Quick
            (with_eio test_cleanup_mixed_pending_and_refused_is_post_effect)
        ] )
    ]
