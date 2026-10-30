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
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(* Replaces the board's [.masc] directory with a regular file so any
   subsequent write under it raises [Sys_error] (ENOTDIR). Same fixture as
   [test_board_vote_persistence.ml], duplicated per the suite's per-file
   convention. *)
let block_board_masc_dir_with_file () =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-delete-rq-blocked-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" base;
  let masc_dir = Filename.dirname (Board.persist_path ()) in
  Fs_compat.mkdir_p (Filename.dirname masc_dir);
  Fs_compat.save_file masc_dir "not a directory";
  base

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ~recipient_lookup:Recipient_lookup.none_declared ();
  f ()

let store () =
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store -> store

let create_post_exn ~content =
  match
    Board_dispatch.create_post ~author:"delete-rq-author" ~content
      ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

let flush () =
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store -> Board.flush_dirty store

let post_rows () = Fs_compat.load_jsonl (Board.persist_path ())

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

let test_delete_rewrite_failure_keeps_resurrection_scheduled () =
  let doomed = create_post_exn ~content:"deleted while the disk is broken" in
  let survivor = create_post_exn ~content:"stays and gets re-marked dirty" in
  let doomed_id = Board.Post_id.to_string doomed.id in
  let survivor_id = Board.Post_id.to_string survivor.id in
  flush ();
  Alcotest.(check bool)
    "flushed clean before the delete" false (store ()).Board.dirty_posts;
  let working_base =
    Sys.getenv_opt "MASC_BASE_PATH" |> Option.value ~default:""
  in
  ignore (block_board_masc_dir_with_file ());
  let writes = ref 0 in
  Board_dispatch.set_board_write_hook (fun () -> incr writes);
  (match Board_dispatch.delete_post ~post_id:doomed_id with
   | Ok (Board.Deletion_persistence_pending detail) ->
     Alcotest.(check bool) "pending outcome carries the persistence failure" true
       (String.length detail > 0)
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok Board.Durable_deletion ->
     Alcotest.fail "failed snapshot rewrites must not report durable deletion");
  Alcotest.(check int) "applied deletion invalidates projections once" 1 !writes;
  (match Board_dispatch.delete_post ~post_id:doomed_id with
   | Error (Board.Post_not_found _) -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok _ -> Alcotest.fail "deletion retry cannot persist an already absent post");
  Alcotest.(check int) "refused retry emits no second transition" 1 !writes;
  Alcotest.(check bool)
    "failed rewrite re-marked the store dirty" true (store ()).Board.dirty_posts;
  Alcotest.(check bool)
    "failed rewrite re-marked comments dirty too" true
    (store ()).Board.dirty_comments;
  (* Disk healthy again: the re-marked store schedules the rewrite, and the
     flush below is what performs it. *)
  Unix.putenv "MASC_BASE_PATH" working_base;
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
  let path = path () in
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
  flush ();
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ~recipient_lookup:Recipient_lookup.none_declared ();
  let restored = store () in
  Alcotest.(check int) "restart has no deleted posts" 0 (Hashtbl.length restored.posts);
  Alcotest.(check int) "restart has no deleted replies" 0 (Hashtbl.length restored.comments);
  Alcotest.(check int) "restart has no deleted votes" 0 (Hashtbl.length restored.vote_log);
  Alcotest.(check int) "restart has no deleted reactions" 0 (Hashtbl.length restored.reactions)

let test_unreadable_snapshot_refuses_before_transition () =
  let post = create_post_exn ~content:"unreadable source cannot authorize deletion" in
  let post_id = Board.Post_id.to_string post.id in
  let writes = ref 0 in
  Board_dispatch.set_board_write_hook (fun () -> incr writes);
  (store ()).Board.posts_load_result <- Error "snapshot could not be fully loaded";
  (match Board_dispatch.delete_post ~post_id with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "unreadable snapshot authorized a deletion");
  Alcotest.(check bool) "refused deletion keeps post" true
    (Result.is_ok (Board_dispatch.get_post ~post_id));
  Alcotest.(check int) "refusal emits no applied transition" 0 !writes

let with_blocked_reactions f =
  let path = Board.reactions_path () in
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
  Hashtbl.replace (store ()).Board.posts post_id old_post;
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
  Hashtbl.replace (store ()).Board.posts post_id
    { post with Board.created_at = Time_compat.now () -. 7200.0 };
  Board.invalidate_post_caches (store ());
  (store ()).Board.posts_load_result <- Error "snapshot read failed";
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
  Hashtbl.replace (store ()).Board.posts pending_id
    { pending with Board.created_at = now -. 7200.0 };
  Hashtbl.replace (store ()).Board.posts refused_id
    { refused with Board.created_at = now -. 10800.0 };
  Board.invalidate_post_caches (store ());
  (store ()).Board.dirty_posts <- true;
  flush ();
  with_blocked_reactions (fun () ->
    Board_dispatch.set_board_write_hook (fun () ->
      (store ()).Board.posts_load_result <- Error "source became unreadable after first deletion");
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
  (store ()).Board.posts_load_result <- Ok ();
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
