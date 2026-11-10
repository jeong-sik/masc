(** test_board_ttl.ml - Board TTL, permanent post, and post_kind classification tests *)

open Masc.Board

(* The store-level writers ask a recipient lookup; no name is declared here. *)
let get_created = function
  | Ok value -> value
  | Error failure ->
    Alcotest.fail (Masc.Board.Post_publication_failure.to_string failure)

let nobody_declared = Masc.Recipient_lookup.none_declared
let create_post store = create_post store ~lookup:nobody_declared
let add_comment store =
  add_comment store ~reader:Masc_board_handlers.Board_access.Operator
    ~lookup:nobody_declared

(* Every writing fixture loads posts and comments explicitly. Give each case
   its own workspace so that load cannot adopt another case's persisted rows. *)
let () = Mirage_crypto_rng_unix.use_default ()

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let original_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let base_path = Filename.temp_dir "masc-test-board-ttl-" "" in
  Fun.protect
    ~finally:(fun () ->
      match original_base with
      | Some value -> Unix.putenv "MASC_BASE_PATH" value
      | None -> Unix.unsetenv "MASC_BASE_PATH")
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base_path;
      f ())

let load_sources store =
  List.iter (fun load ->
    match load store with
    | Ok _ -> ()
    | Error (path, cause) ->
      Alcotest.failf "board fixture load failed: %s (%s)" path (Printexc.to_string cause))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments];
  List.iter (fun reload -> match reload store with
    | Ok _ -> ()
    | Error error -> Alcotest.fail (show_board_error error))
    [reload_votes; reload_reactions]
;;

let test_default_ttl () =
  Alcotest.(check int) "default_ttl_hours is 0" 0 Limits.default_ttl_hours

(* Issue #8449 PR A: Board_dispatch.sort_order schema enum SSOT.
   Witness covers all 5 variants; adding a 6th constructor will fail
   compilation in [sort_order_to_string]. *)
let test_sort_order_witness_in_enum () =
  let module D = Masc.Board_dispatch in
  let witness s =
    let actual = D.sort_order_to_string s in
    if not (List.mem actual D.valid_sort_order_strings) then
      Alcotest.failf "sort_order_to_string %S not in valid_sort_order_strings" actual
  in
  witness D.Hot;
  witness D.Trending;
  witness D.Recent;
  witness D.Updated;
  witness D.Discussed;
  Alcotest.(check int) "count" 5
    (List.length D.valid_sort_order_strings)

let test_permanent_post () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  match
    create_post store ~author:"test-agent" ~content:"Permanent post"
      ~post_kind:Human_post ()
  with
  | Ok post ->
      Alcotest.(check (float 0.0)) "expires_at = 0.0" 0.0 post.expires_at
  | Error e -> Alcotest.fail (Post_publication_failure.to_string e)

let test_expiring_post () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  match
    create_post store ~author:"test-agent" ~content:"Expiring post"
      ~post_kind:Human_post ~ttl_hours:24 ()
  with
  | Ok post ->
      Alcotest.(check bool) "expires_at > 0.0" true (post.expires_at > 0.0)
  | Error e -> Alcotest.fail (Post_publication_failure.to_string e)

let test_sweeper_skips_permanent () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  (match
     create_post store ~author:"test-agent" ~content:"Permanent"
       ~post_kind:Human_post ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Post_publication_failure.to_string e));
  let (removed_posts, _) = sweep store in
  Alcotest.(check int) "sweeper removed 0 permanent posts" 0 removed_posts

(* A post and its dependent rows leave together, in the pass that expires it. *)
let test_sweep_removes_the_rows_of_an_expired_target () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let post_id =
    match
      create_post store ~author:"test-agent"
        ~content:"Post with a reaction and a vote" ~post_kind:Human_post
        ~ttl_hours:1 ()
    with
    | Ok post -> Post_id.to_string post.id
    | Error e -> Alcotest.fail (Post_publication_failure.to_string e)
  in
  (match
     toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Reaction_post ~target_id:post_id
       ~user_id:"reactor-agent" ~emoji:"👍"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  (match vote store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"voter-agent" ~post_id ~direction:Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  let post = Hashtbl.find store.posts post_id in
  Hashtbl.replace store.posts post_id { post with expires_at = 1.0 };
  let (removed_posts, _) = sweep store in
  Alcotest.(check int) "the expired post was swept" 1 removed_posts;
  Alcotest.(check int) "its reaction went with it" 0 (Hashtbl.length store.reactions);
  Alcotest.(check int) "its vote went with it" 0 (Hashtbl.length store.vote_log)

(* A target that is merely not in memory is not a deleted target. Posts load
   before votes and reactions, and a failed or partial post load leaves the
   table empty; reading that as "every vote is orphaned" is what emptied the
   live board on 2026-09-19, because the next snapshot wrote the pruned
   tables to disk. *)
let test_sweep_keeps_rows_whose_target_is_not_loaded () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let post_id =
    match
      create_post store ~author:"test-agent" ~content:"Post that fails to load"
        ~post_kind:Human_post ()
    with
    | Ok post -> Post_id.to_string post.id
    | Error e -> Alcotest.fail (Post_publication_failure.to_string e)
  in
  (match
     toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Reaction_post ~target_id:post_id
       ~user_id:"reactor-agent" ~emoji:"👍"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  (match vote store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"voter-agent" ~post_id ~direction:Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  Hashtbl.remove store.posts post_id;
  let (removed_posts, _) = sweep store in
  Alcotest.(check int) "nothing expired" 0 removed_posts;
  Alcotest.(check int) "the reaction stayed" 1 (Hashtbl.length store.reactions);
  Alcotest.(check int) "the vote stayed" 1 (Hashtbl.length store.vote_log)

(* A reply the sweeper removes leaves the post's reply count with it, so a
   listing never announces a reply no read can return. *)
let test_sweep_takes_an_expired_reply_out_of_the_post_count () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let post_id =
    match
      create_post store ~author:"test-agent"
        ~content:"Post with a permanent and an expiring reply"
        ~post_kind:Human_post ()
    with
    | Ok post -> Post_id.to_string post.id
    | Error e -> Alcotest.fail (Post_publication_failure.to_string e)
  in
  let add_reply ~ttl_hours =
    match
      add_comment store ~post_id ~author:"commenter" ~content:"reply" ~ttl_hours ()
    with
    | Ok comment -> Comment_id.to_string comment.id
    | Error e -> Alcotest.fail (show_board_error e)
  in
  let (_ : string) = add_reply ~ttl_hours:0 in
  let expiring_id = add_reply ~ttl_hours:1 in
  let reply_count () = (Hashtbl.find store.posts post_id).reply_count in
  Alcotest.(check int) "both replies counted" 2 (reply_count ());
  let expiring = Hashtbl.find store.comments expiring_id in
  Hashtbl.replace store.comments expiring_id { expiring with expires_at = 1.0 };
  let (_, removed_comments) = sweep store in
  Alcotest.(check int) "the expired reply was swept" 1 removed_comments;
  Alcotest.(check int) "the count follows the swept reply" 1 (reply_count ());
  Alcotest.(check int) "the count matches the replies a read returns" 1
    (match read_post_and_comments store ~post_id with
     | Ok (_, comments) -> List.length comments
     | Error e -> Alcotest.fail (show_board_read_error e))

(* A swept post takes its comments with it, or they strand with a dangling
   post_id no read can reach. *)
let test_sweep_cascades_an_expired_post_to_its_comments () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let post_id =
    match
      create_post store ~author:"test-agent"
        ~content:"Expiring post with a permanent reply" ~post_kind:Human_post
        ~ttl_hours:1 ()
    with
    | Ok post -> Post_id.to_string post.id
    | Error e -> Alcotest.fail (Post_publication_failure.to_string e)
  in
  let comment_id =
    match
      add_comment store ~post_id ~author:"commenter" ~content:"reply"
        ~ttl_hours:0 ()
    with
    | Ok comment -> Comment_id.to_string comment.id
    | Error e -> Alcotest.fail (show_board_error e)
  in
  (match
     toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Reaction_comment
       ~target_id:comment_id ~user_id:"reactor-agent" ~emoji:"👍"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  let post = Hashtbl.find store.posts post_id in
  Hashtbl.replace store.posts post_id { post with expires_at = 1.0 };
  let (removed_posts, removed_comments) = sweep store in
  Alcotest.(check int) "the expired post was swept" 1 removed_posts;
  Alcotest.(check int) "its reply went with it" 1 removed_comments;
  Alcotest.(check bool) "no dangling comment" false
    (Hashtbl.mem store.comments comment_id);
  Alcotest.(check int) "the reply's reaction went with it" 0
    (Hashtbl.length store.reactions)

let test_sweep_drains_a_post_larger_than_two_comment_batches () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let unwrap = function
    | Ok value -> value
    | Error e -> Alcotest.fail (show_board_error e)
  in
  let post =
    get_created (create_post store ~author:"test-agent" ~content:"Large expired thread"
      ~post_kind:Human_post ~ttl_hours:1 ())
  in
  let post_id = Post_id.to_string post.id in
  let comment_count = (2 * Limits.sweeper_batch_size) + 1 in
  (* task-1758/#39356 comment cap (wool-nova FAIL issuecomment-5860167607,
     P1): [add_comment] now refuses once a post holds
     [Limits.comment_count_cap] live comments, so this fixture (more than
     two sweeper batches) can no longer be built through the public write
     path -- comment_count here already exceeds the default cap. The cap
     only blocks the *next write*; it never trims comments already in the
     store, so a thread this large legitimately exists whenever it grew
     before the cap took effect (or the cap was raised then lowered).
     Insert the filler rows directly at the same invariants [add_comment]'s
     commit step keeps (index entry, bumped reply_count, dirty marks,
     cache invalidation) and skip only the cap check, so this test keeps
     exercising the sweeper's batching, not the write-time guard. *)
  let insert_filler_comment () =
    let author = unwrap (Agent_id.of_string "commenter") in
    let comment =
      { id = Comment_id.generate ()
      ; post_id = post.id
      ; parent_id = None
      ; author
      ; content = "permanent reply"
      ; audience = None
      ; created_at = Unix.gettimeofday ()
      ; expires_at = 0.0
      ; votes_up = 0
      ; votes_down = 0
      }
    in
    let comment_key = Comment_id.to_string comment.id in
    Hashtbl.add store.comments comment_key comment;
    let existing =
      Hashtbl.find_opt store.comments_by_post post_id
      |> Option.value ~default:[]
    in
    Hashtbl.replace store.comments_by_post post_id (comment_key :: existing);
    let current_post = Hashtbl.find store.posts post_id in
    Hashtbl.replace store.posts post_id
      { current_post with
        reply_count = current_post.reply_count + 1
      ; updated_at = comment.created_at
      };
    mark_dirty_post store post_id;
    mark_dirty_comment store comment_key;
    invalidate_post_caches store;
    invalidate_comment_caches store;
    comment_key
  in
  let comment_ids =
    List.init comment_count (fun _ -> insert_filler_comment ())
  in
  (* The large retained thread must exist in canonical Comments before new
     votes/reactions can use it as a target. Keep the cap-bypass setup, then
     persist it once before exercising the real mutation and sweep paths. *)
  flush_dirty store;
  List.iter
    (fun comment_id ->
      ignore (unwrap (toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Reaction_comment
        ~target_id:comment_id ~user_id:"reactor-agent" ~emoji:"👍"));
      ignore (unwrap (vote_comment store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"voter-agent" ~comment_id
        ~direction:Up)))
    comment_ids;
  ignore (unwrap (toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Reaction_post
    ~target_id:post_id ~user_id:"reactor-agent" ~emoji:"👍"));
  ignore (unwrap (vote store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"voter-agent" ~post_id ~direction:Up));
  let current = Hashtbl.find store.posts post_id in
  Hashtbl.replace store.posts post_id { current with expires_at = 1.0 };
  (* Only removals below may dirty these rows. *)
  store.dirty_posts <- false;
  store.dirty_comments <- false;
  Hashtbl.clear store.dirty_post_ids;
  Hashtbl.clear store.dirty_comment_ids;
  let reload () =
    reset_global_for_test ();
    global ()
  in
  let check_partial store expected_remaining =
    let present_before =
      List.map (fun cid -> cid, Hashtbl.mem store.comments cid) comment_ids
    in
    let removed_posts, removed_comments = sweep store in
    Alcotest.(check int) "post survives partial cascade" 0 removed_posts;
    Alcotest.(check int) "one comment batch removed" Limits.sweeper_batch_size
      removed_comments;
    Alcotest.(check int) "remaining comment rows" expected_remaining
      (Hashtbl.length store.comments);
    Alcotest.(check int) "surviving reply count" expected_remaining
      (Hashtbl.find store.posts post_id).reply_count;
    Alcotest.(check int) "surviving reply index" expected_remaining
      (List.length (Hashtbl.find store.comments_by_post post_id));
    Alcotest.(check int) "post and surviving reply reactions retained"
      (expected_remaining + 1) (Hashtbl.length store.reactions);
    Alcotest.(check int) "post and surviving reply votes retained"
      (expected_remaining + 1) (Hashtbl.length store.vote_log);
    Alcotest.(check int) "post count retained" 1 !(store.post_count);
    Alcotest.(check bool) "changed post marked dirty" true
      (Hashtbl.mem store.dirty_post_ids post_id);
    List.iter (fun (cid, was_present) ->
      Alcotest.(check bool) "only this pass's deleted comments marked dirty"
        (was_present && not (Hashtbl.mem store.comments cid))
        (Hashtbl.mem store.dirty_comment_ids cid)) present_before;
    flush_dirty store;
    let resumed = reload () in
    Alcotest.(check int) "restart retains the unfinished expired parent" 1
      (Hashtbl.length resumed.posts);
    Alcotest.(check int) "restart retains only remaining replies" expected_remaining
      (Hashtbl.length resumed.comments);
    Alcotest.(check int) "restart rebuilds remaining reply count" expected_remaining
      (Hashtbl.find resumed.posts post_id).reply_count;
    Alcotest.(check int) "deleted reactions stay deleted after restart"
      (expected_remaining + 1) (Hashtbl.length resumed.reactions);
    Alcotest.(check int) "deleted votes stay deleted after restart"
      (expected_remaining + 1) (Hashtbl.length resumed.vote_log);
    resumed
  in
  let store = check_partial store (Limits.sweeper_batch_size + 1) in
  let store = check_partial store 1 in
  let removed_posts, removed_comments = sweep store in
  Alcotest.(check (pair int int)) "last reply and post leave together" (1, 1)
    (removed_posts, removed_comments);
  Alcotest.(check int) "no remaining comments" 0 (Hashtbl.length store.comments);
  Alcotest.(check int) "no remaining comment index" 0
    (Hashtbl.length store.comments_by_post);
  Alcotest.(check int) "no remaining posts" 0 (Hashtbl.length store.posts);
  Alcotest.(check int) "post count converged" 0 !(store.post_count);
  Alcotest.(check int) "all dependent reactions removed" 0
    (Hashtbl.length store.reactions);
  Alcotest.(check int) "all dependent votes removed" 0
    (Hashtbl.length store.vote_log);
  Alcotest.(check (pair int int)) "next sweep has no work" (0, 0) (sweep store);
  (* A failed final reaction snapshot must stay scheduled even when the
     post/comment tables are already empty. *)
  let reaction_path = reactions_path store in
  Sys.remove reaction_path;
  Fs_compat.mkdir_p reaction_path;
  let errors_before = persist_error_count () in
  flush_dirty store;
  Alcotest.(check bool) "reaction write failure is observed" true
    (persist_error_count () > errors_before);
  Alcotest.(check bool) "empty cleanup remains scheduled for retry" true
    store.dirty_posts;
  Unix.rmdir reaction_path;
  flush_dirty store;
  Alcotest.(check bool) "successful retry clears dirty state" false
    store.dirty_posts;
  let finished = reload () in
  Alcotest.(check int) "restart has no posts" 0 (Hashtbl.length finished.posts);
  Alcotest.(check int) "restart has no comments" 0 (Hashtbl.length finished.comments);
  Alcotest.(check int) "restart has no reactions" 0 (Hashtbl.length finished.reactions);
  Alcotest.(check int) "restart has no votes" 0 (Hashtbl.length finished.vote_log)

let schedule_reset_timestamp_for_test = 0.0

let reset_sweep_schedule_for_test =
  Masc_board_handlers.Board_core_persist.reset_sweep_schedule_for_test

let sweep_schedule_timestamps_for_test =
  Masc_board_handlers.Board_core_persist.sweep_schedule_timestamps_for_test

let maybe_sweep_for_test = Masc_board_handlers.Board_core_persist.maybe_sweep

let flusher_inbox_capacity_for_test =
  Masc_board_handlers.Board_core_persist.flusher_inbox_capacity

let flusher_schedule_dropped_count_for_test =
  Masc_board_handlers.Board_core_persist.flusher_schedule_dropped_count

let drain_flusher_inbox store =
  let rec loop acc =
    match Eio.Stream.take_nonblocking store.flusher_inbox with
    | None -> List.rev acc
    | Some msg -> loop (msg :: acc)
  in
  loop []

let check_one_sweep_and_flush label messages =
  let sweep_count, flush_count =
    List.fold_left
      (fun (sweeps, flushes) msg ->
         match msg with
         | Sweep -> (sweeps + 1, flushes)
         | Flush -> (sweeps, flushes + 1))
      (0, 0)
      messages
  in
  Alcotest.(check int) (label ^ " sweep count") 1 sweep_count;
  Alcotest.(check int) (label ^ " flush count") 1 flush_count

let test_maybe_sweep_updates_schedule_once () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  reset_sweep_schedule_for_test store;
  maybe_sweep_for_test store;
  let first_sweep, first_flush = sweep_schedule_timestamps_for_test store in
  Alcotest.(check bool) "sweep timestamp updated" true (first_sweep > 0.0);
  Alcotest.(check bool) "flush timestamp updated" true (first_flush > 0.0);
  maybe_sweep_for_test store;
  let second_sweep, second_flush = sweep_schedule_timestamps_for_test store in
  Alcotest.(check (float 0.0)) "sweep timestamp unchanged" first_sweep second_sweep;
  Alcotest.(check (float 0.0)) "flush timestamp unchanged" first_flush second_flush;
  check_one_sweep_and_flush "sequential" (drain_flusher_inbox store)

let test_maybe_sweep_concurrent_schedules_once () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  reset_sweep_schedule_for_test store;
  let callers = List.init 32 Fun.id in
  let _ =
    Eio.Fiber.List.map
      ~max_fibers:32
      (fun _ -> maybe_sweep_for_test store)
      callers
  in
  check_one_sweep_and_flush "concurrent" (drain_flusher_inbox store)

let test_maybe_sweep_full_inbox_rolls_back_schedule () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  reset_sweep_schedule_for_test store;
  for _ = 1 to flusher_inbox_capacity_for_test do
    Eio.Stream.add store.flusher_inbox Flush
  done;
  let dropped_before = flusher_schedule_dropped_count_for_test () in
  maybe_sweep_for_test store;
  let dropped_after = flusher_schedule_dropped_count_for_test () in
  let sweep_ts, flush_ts = sweep_schedule_timestamps_for_test store in
  Alcotest.(check int) "full inbox dropped scheduled messages" 2
    (dropped_after - dropped_before);
  Alcotest.(check (float 0.0))
    "sweep timestamp rolled back"
    schedule_reset_timestamp_for_test
    sweep_ts;
  Alcotest.(check (float 0.0))
    "flush timestamp rolled back"
    schedule_reset_timestamp_for_test
    flush_ts;
  Alcotest.(check int)
    "full inbox length unchanged"
    flusher_inbox_capacity_for_test
    (Eio.Stream.length store.flusher_inbox)

let test_post_kind_direct_default () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  match
    create_post store ~author:"test-agent" ~content:"Human post"
      ~post_kind:Human_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is direct" "direct" kind
  | Error e -> Alcotest.fail (Post_publication_failure.to_string e)

let test_post_kind_automation_contract () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  (* A hearth post reads the canonical sub-board policy before it appends
     (post creation policy guard); the fixture must observe it first. *)
  (match reload_sub_boards store with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (show_board_error error));
  match
    create_post store ~author:"dashboard-harness-bot" ~content:"Harness post"
      ~visibility:Internal ~ttl_hours:1 ~hearth:"dashboard-harness"
      ~post_kind:Automation_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is automation" "automation" kind
  | Error e -> Alcotest.fail (Post_publication_failure.to_string e)

let test_post_kind_system_contract () =
  let store = create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  match
    create_post store ~author:"operator" ~content:"System post"
      ~post_kind:System_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is system" "system" kind
  | Error e -> Alcotest.fail (Post_publication_failure.to_string e)

let () =
  Alcotest.run "Board_TTL"
    [
      ( "ttl",
        [
          Alcotest.test_case "default TTL is 0" `Quick test_default_ttl;
          Alcotest.test_case "permanent post" `Quick
            (with_eio test_permanent_post);
          Alcotest.test_case "expiring post" `Quick
            (with_eio test_expiring_post);
          Alcotest.test_case "sweeper skips permanent" `Quick
            (with_eio test_sweeper_skips_permanent);
          Alcotest.test_case "sweep removes the rows of an expired target"
            `Quick
            (with_eio test_sweep_removes_the_rows_of_an_expired_target);
          Alcotest.test_case "sweep keeps rows whose target is not loaded"
            `Quick
            (with_eio test_sweep_keeps_rows_whose_target_is_not_loaded);
          Alcotest.test_case "sweep takes an expired reply out of the post count"
            `Quick
            (with_eio test_sweep_takes_an_expired_reply_out_of_the_post_count);
          Alcotest.test_case "sweep cascades an expired post to its comments"
            `Quick
            (with_eio test_sweep_cascades_an_expired_post_to_its_comments);
          Alcotest.test_case "sweep drains a post larger than two comment batches"
            `Quick
            (with_eio test_sweep_drains_a_post_larger_than_two_comment_batches);
          Alcotest.test_case "maybe_sweep schedules once" `Quick
            (with_eio test_maybe_sweep_updates_schedule_once);
          Alcotest.test_case "maybe_sweep concurrent schedules once" `Quick
            (with_eio test_maybe_sweep_concurrent_schedules_once);
          Alcotest.test_case "maybe_sweep full inbox rolls back schedule" `Quick
            (with_eio test_maybe_sweep_full_inbox_rolls_back_schedule);
        ] );
      ( "sort_order_ssot",
        [
          Alcotest.test_case "witness covers all 5 variants" `Quick
            test_sort_order_witness_in_enum;
        ] );
      ( "post_kind",
        [
          Alcotest.test_case "direct default" `Quick
            (with_eio test_post_kind_direct_default);
          Alcotest.test_case "automation contract" `Quick
            (with_eio test_post_kind_automation_contract);
          Alcotest.test_case "system contract" `Quick
            (with_eio test_post_kind_system_contract);
        ] );
    ]
