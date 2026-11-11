(** Original deletion decisions and ordered snapshot recovery. A decision that
    cannot be recorded leaves models unchanged. Once recorded, failed rewrites
    retain owned work, and a fresh initializer resumes only the original IDs. *)

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

(* Deny new private-file publication while reads and workspace observation
   remain available. This now rejects decision recording before model removal. *)
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
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Error (Board.Post_not_found _) -> ()
  | Error error -> Alcotest.fail (label ^ ": " ^ Board.show_board_error error)
  | Ok _ -> Alcotest.fail (label ^ ": the applied deletion was lost")

let test_unrecorded_deletion_preserves_the_model () =
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
  (match Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id:doomed_id with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "unrecorded deletion must be refused");
  Alcotest.(check int) "unrecorded deletion emits no applied transition" 0 !writes;
  ignore (Result.get_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:doomed_id));
  Alcotest.(check bool) "unrecorded deletion creates no dirty snapshot work" false (store ()).Board.dirty_posts
  );
  Board.reset_global_for_test ();
  let repaired = Board.global () in
  (match Board.delete_post repaired ~authorization:Board.Operator_deletion ~post_id:doomed_id with
   | Ok Board.Durable_deletion -> ()
   | Ok (Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail) -> Alcotest.fail detail
   | Error error -> Alcotest.fail (Board.show_board_error error));
  let rows = post_rows () in
  Alcotest.(check bool) "recorded deletion removes the original post" false (row_has_post_id doomed_id rows);
  Alcotest.(check bool) "surviving post remains on disk" true (row_has_post_id survivor_id rows)

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let test_individual_snapshot_failure path () =
  let doomed = create_post_exn ~content:"delete the final post and all dependent rows" in
  let post_id = Board.Post_id.to_string doomed.id in
  ignore
    (require_ok
       (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"comment-author"
          ~content:"dependent reply" ()));
  ignore (require_ok (Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~voter:"voter" ~direction:Board.Up));
  ignore
    (require_ok
       (Board_dispatch.toggle_reaction ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
          ~target_id:post_id ~user_id:"reactor" ~emoji:"👍"));
  flush ();
  let active = store () in
  let path = path (store ()) in
  let admission_source_obstructed = String.equal path (Board.persist_path active)
    || String.equal path (Board.comments_path active) in
  let backup = path ^ ".before-delete" in
  Unix.rename path backup;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir path; Unix.rename backup path)
    (fun () ->
      (match admission_source_obstructed, Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id with
       | true, Error (Board.Io_error _) -> ()
       | false, Ok (Board.Deletion_persistence_pending _) -> ()
       | _, Error error -> Alcotest.fail (Board.show_board_error error)
       | _, Ok (Board.Deletion_decision_pending detail) -> Alcotest.fail detail
       | true, Ok (Board.Deletion_persistence_pending _) | _, Ok Board.Durable_deletion ->
         Alcotest.fail "unexpected deletion boundary for the obstructed source");
      Alcotest.(check bool) "only an admitted deletion creates snapshot retry work" (not admission_source_obstructed)
        ((store ()).Board.dirty_posts || (store ()).Board.dirty_comments));
  Alcotest.(check bool) "retry retains the original store" true (active == store ());
  if admission_source_obstructed then (
    Alcotest.(check bool) "restored old posts file still contains the doomed row" true
      (row_has_post_id post_id (post_rows ()));
    ignore (require_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id));
    flush ();
    ignore (require_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id));
    match require_ok (Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id) with
    | Board.Durable_deletion -> ()
    | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail)
  else check_post_deleted "deletion remains applied before retry" post_id;
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

let test_failed_comments_write_preserves_later_sources () =
  let armed = ref false and syncs = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ ->
      incr syncs;
      if !armed then (armed := false; raise (Sys_error "comments rewrite parent sync failed")));
    close_fd = Unix.close } in
  let base_path = Env_config_core.base_path () in
  let active = Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  require_ok (Board.initialize_store active);
  let doomed = match Board.create_post active ~lookup:Recipient_lookup.none_declared
      ~author:"delete-rq-author" ~content:"ordered sources after admitted deletion"
      ~post_kind:Board.Human_post () with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error) in
  let post_id = Board.Post_id.to_string doomed.id in
  ignore (require_ok (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator active ~lookup:Recipient_lookup.none_declared
    ~post_id ~author:"comment-author" ~content:"original dependent reply" ()));
  ignore (require_ok (Board.vote active ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~voter:"voter" ~direction:Board.Up));
  ignore (require_ok (Board.toggle_reaction active ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
    ~target_id:post_id ~user_id:"reactor" ~emoji:"👍"));
  Board.flush_dirty active;
  let later = List.map (fun path -> path, Fs_compat.load_file path)
    [Board.vote_log_path active; Board.reactions_path active] in
  let check_later label = List.iter (fun (path, bytes) ->
    Alcotest.(check string) label bytes (Fs_compat.load_file path)) later in
  armed := true;
  (match require_ok (Board.delete_post active ~authorization:Board.Operator_deletion ~post_id) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion | Board.Deletion_decision_pending _ ->
     Alcotest.fail "post-decision comments failure lost its applied/pending boundary");
  Alcotest.(check string) "posts write completes before comments fail" ""
    (Fs_compat.load_file (Board.persist_path active));
  (match active.comments_source with
   | Board.Comments_unsettled _ -> ()
   | Board.Comments_unobserved | Board.Comments_readable _ | Board.Comments_publishing _
   | Board.Comments_recovered _ | Board.Comments_refused _ ->
     Alcotest.fail "actual post-rename comments uncertainty was not retained");
  check_later "failed comments source stops before later writes";
  let before_flush = !syncs in
  Board.flush_dirty active;
  Alcotest.(check int) "ordinary flush never replays unknown comments write" before_flush !syncs;
  check_later "ordinary flush preserves unattempted later sources";
  let restored = Board.create_store ~base_path () in
  require_ok (Board.initialize_store restored);
  Alcotest.(check int) "fresh recovery removes original post" 0 (Hashtbl.length restored.posts);
  Alcotest.(check int) "fresh recovery removes original replies" 0 (Hashtbl.length restored.comments);
  Alcotest.(check int) "fresh recovery removes original votes" 0 (Hashtbl.length restored.vote_log);
  Alcotest.(check int) "fresh recovery removes original reactions" 0 (Hashtbl.length restored.reactions)

let test_delete_refuses_changed_same_cursor_bytes () =
  let doomed = create_post_exn ~content:"body-aaaa" in
  let post_id = Board.Post_id.to_string doomed.id in
  flush ();
  let active = store () in
  let path = Board.persist_path active in
  let before = In_channel.with_open_bin path In_channel.input_all in
  let original_stat = Unix.stat path in
  let changed = Yojson.Safe.to_string (Board.post_to_yojson { doomed with body = "body-bbbb" }) ^ "\n" in
  Alcotest.(check int) "external edit keeps the accepted source length"
    (String.length before) (String.length changed);
  Alcotest.(check bool) "external edit changes actual source bytes" false (String.equal before changed);
  Fs_compat.invalidate_cached_writer path;
  Out_channel.with_open_gen [Open_wronly; Open_binary] 0o600 path
    (fun out -> output_string out changed);
  let changed_stat = Unix.stat path in
  Alcotest.(check (pair int int)) "edit retains the exact source inode"
    (original_stat.Unix.st_dev, original_stat.Unix.st_ino)
    (changed_stat.Unix.st_dev, changed_stat.Unix.st_ino);
  Alcotest.(check int) "edit retains the exact source length" original_stat.Unix.st_size changed_stat.Unix.st_size;
  (match Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "changed bytes authorized a deletion decision");
  (match active.deletion_state with
   | Board.Deletion_readable { plan = None; diagnostics; _ } ->
     Alcotest.(check bool) "guard retains exact-byte refusal" true
       (List.exists (function
          | Board.Deletion_guard_diagnostic failure ->
            (match failure.guard_error with
             | Fs_compat.Transaction_content_changed _ -> true
             | (Fs_compat.Stable_lock_contended _
               | Fs_compat.Unexpected_stable_lock_permissions _
               | Fs_compat.Invalid_stable_lock_state _
               | Fs_compat.Cursor_mismatch _
               | Fs_compat.Unexpected_transaction_file_kind _
               | Fs_compat.Ambiguous_transaction_file_identity _
               | Fs_compat.Transaction_path_binding_changed _
               | Fs_compat.Incomplete_transaction_tail _
               | Fs_compat.Invalid_transaction_suffix
               | Fs_compat.Private_jsonl_operation_failed _
               | Fs_compat.Rewrite_stage_failed _
               | Fs_compat.Rewrite_published_durability_unknown _
               | Fs_compat.Transaction_settlement_failed _
               | Fs_compat.Transaction_append_failed _) -> false)
          | Board.Deletion_file_diagnostic _
          | Board.Deletion_workspace_diagnostic _ | Board.Deletion_raised_diagnostic _ -> false) diagnostics)
   | Board.Deletion_unobserved | Board.Deletion_readable { plan = Some _; _ }
   | Board.Deletion_pending _ | Board.Deletion_unsettled _ | Board.Deletion_refused _
   | Board.Deletion_projection_failed _ -> Alcotest.fail "guard refusal became a deletion decision");
  let module Paths = Masc_board_handlers.Board_paths in
  Alcotest.(check bool) "refused guard writes no marker" false
    (Sys.file_exists (Paths.store_file_path active Paths.Deletion));
  let kept = require_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id) in
  Alcotest.(check string) "refusal preserves the observed model" doomed.body kept.body;
  Alcotest.(check bool) "refusal creates no pending snapshot" false active.dirty_posts;
  flush ();
  Alcotest.(check string) "ordinary flush preserves every foreign byte" changed
    (In_channel.with_open_bin path In_channel.input_all);
  let restarted = Board.create_store ~base_path:(Env_config_core.base_path ()) () in
  require_ok (Board.initialize_store restarted);
  match Board.read_post_for_evidence restarted ~post_id with
  | Ok saved -> Alcotest.(check string) "fresh initialization preserves foreign edit" "body-bbbb" saved.body
  | Error error -> Alcotest.fail (Board.show_board_read_error error)

let test_unreadable_snapshot_refuses_before_transition () =
  let post = create_post_exn ~content:"unreadable source cannot authorize deletion" in
  let post_id = Board.Post_id.to_string post.id in
  let writes = ref 0 in
  Board_dispatch.set_board_sse_hook (function
    | Board_dispatch.Post_changed _ -> incr writes
    | _ -> ());
  let _repair_source = refuse_posts_source () in
  (match Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "unreadable snapshot authorized a deletion");
  Alcotest.(check bool) "refused deletion keeps post" true
    (Result.is_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id));
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
      Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator ~result_boundary:Tool_output.Sent_to_client "masc_board_delete"
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
      Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
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
    Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
      (`Assoc ["dry_run", `Bool false; "max_age_hours", `Int 1])
  in
  let execution = Keeper_tool_execution.of_tool_result result in
  Alcotest.(check bool) "all refused deletions remain pre-effect" true
    (execution.failure_effect_disposition = Tool_result.Proven_pre_effect);
  Alcotest.(check bool) "storage refusal keeps the post" true
    (Result.is_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id));
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
  (* DIAG: the event hook runs under [Safe_ops.protect], which swallows whatever
     it raises. Without this ref an assertion failing inside the hook is
     invisible and the test reports the later "did not reach the corruption
     hook" line instead of the assertion that actually failed. *)
  let hook_failure = ref None in
  with_blocked_reactions (fun () ->
    (* The hook runs after persistence unlock. A real subsequent append CAS
       observes the damaged source while the deletion model stays pending. *)
    Board_dispatch.set_board_sse_hook (function
      | Board_dispatch.Post_changed _ ->
        (try
        let active = store () in
        let path = Board.persist_path active in
        let original = In_channel.with_open_bin path In_channel.input_all in
        Out_channel.with_open_gen [Open_wronly; Open_append; Open_binary] 0o600 path
          (fun out -> output_string out "{invalid-post-source\n");
        (match Board_dispatch.create_post ~author:"source-refusal-probe"
           ~content:"must not append to a changed source" ~post_kind:Board.Human_post () with
         | Error _ -> ()
         | Ok _ -> Alcotest.fail "changed source unexpectedly accepted a probe post");
        Alcotest.(check bool) "append CAS actually records source refusal" true
          (Result.is_error (Board.with_persist_lock active (fun () ->
             Board.require_posts_source_readable active)));
        repair_source := Some (fun () ->
          Out_channel.with_open_bin path (fun out -> output_string out original))
         with e -> hook_failure := Some e)
      | _ -> ());
    let result =
      Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator ~result_boundary:Tool_output.Sent_to_client "masc_board_cleanup"
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
      (Result.is_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:refused_id)));
  Board_dispatch.set_board_sse_hook (fun _ -> ());
  (* DIAG: surface the hook's own failure before the "did not reach" line, so
     the reported assertion is the one that actually failed. *)
  (match !hook_failure with
   | Some e -> raise e
   | None -> ());
  (match !repair_source with
   | Some repair -> repair ()
   | None -> Alcotest.fail "first applied deletion did not reach the corruption hook");
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  check_post_deleted "fresh store retains the applied parent deletion" pending_id;
  Alcotest.(check bool) "fresh store retains the refused post" true
    (Result.is_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:refused_id));
  flush ()

let () =
  Alcotest.run "board_delete_rewrite_requeue"
    [ ( "delete_post",
        [ Alcotest.test_case
            "unrecorded deletion keeps the model and emits no applied event"
            `Quick
            (with_eio test_unrecorded_deletion_preserves_the_model)
        ; Alcotest.test_case "obstructed parent refuses before decision" `Quick
            (with_eio (test_individual_snapshot_failure Board.persist_path))
        ; Alcotest.test_case "obstructed comments refuse before decision" `Quick
            (with_eio (test_individual_snapshot_failure Board.comments_path))
        ; Alcotest.test_case "votes rewrite remains pending and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.vote_log_path))
        ; Alcotest.test_case "reactions rewrite remains pending and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.reactions_path))
        ; Alcotest.test_case "post-decision comments failure preserves later sources" `Quick
            (with_eio test_failed_comments_write_preserves_later_sources)
        ; Alcotest.test_case "deletion guard refuses changed same-cursor bytes" `Quick
            (with_eio test_delete_refuses_changed_same_cursor_bytes)
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
