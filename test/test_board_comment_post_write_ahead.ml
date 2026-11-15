(** Write-ahead durability for comment and post creation (#28952).

    PR #28934 converted votes to write-ahead (validate, durably append,
    then commit from a fresh read) and documented comments as the same
    known race class; posts shared the shape too. These tests pin the
    converted contract for both creation paths:

    - a failed durable append commits nothing (no comment/post in
      memory, no reply-count drift, typed [Io_error]);
    - the same call succeeds once the disk is healthy again — the
      failure left no residual state to collide with;
    - restart derives [reply_count] and the [updated_at] high-water
      mark from the comment WAL, so dropping the eager posts-snapshot
      save from the comment path loses nothing across a crash. *)

open Masc
let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-comment-wa-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p dir;
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(* Replaces the board's [.masc] directory with a regular file so any
   subsequent [Fs_compat.mkdir_p]/[append_file] under it raises
   [Sys_error] (ENOTDIR). Same fixture as
   [test_board_vote_persistence.ml]; duplicated locally per that
   suite's per-file fixture convention. *)
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

let create_post_exn ~author ~content =
  match
    Board_dispatch.create_post ~author ~content ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.Post_publication_failure.to_string e)

let noop_observer : Board_metrics_hooks.observer =
  { observe_persist_lock_acquire_sec = (fun _ -> ())
  ; observe_persist_lock_held_sec = (fun _ -> ())
  ; inc_dispatch_flusher_start_outcome = (fun () -> ())
  }

let with_observer observer f =
  Eio.Switch.run (fun sw ->
    Eio.Switch.on_release sw (fun () ->
      Board_metrics_hooks.set_observer noop_observer);
    Board_metrics_hooks.set_observer observer;
    f ())

let check_effect label expected failure =
  let effect_testable = Alcotest.testable
      (fun fmt value -> Format.pp_print_string fmt (Failure_effect.to_string value))
      ( = ) in
  Alcotest.check effect_testable label expected
    (Board.Post_publication_failure.effect_disposition failure)

let post_rows () =
  let path = Board.persist_path (Board.global ()) in
  if Sys.file_exists path then Fs_compat.load_jsonl path else []

let test_held_observer_failure_keeps_the_committed_receipt () =
  let calls = ref 0 in
  let failure = with_observer
      { noop_observer with observe_persist_lock_held_sec = (fun _ ->
          incr calls;
          if !calls = 1 then failwith "held observer failed") }
      (fun () ->
        match Board_dispatch.create_post_with_unresolved
                ~author:"receipt-author"
                ~content:"published before observer failure @unresolved-receipt"
                ~post_kind:Board.Human_post () with
        | Ok _ -> Alcotest.fail "the failing held observer must be reported"
        | Error failure -> failure)
  in
  Alcotest.(check int) "the real held observer was invoked once" 1 !calls;
  check_effect "publication preceded the observer failure"
    Failure_effect.Proven_post_effect failure;
  (match Board.Post_publication_failure.cause failure with
   | Board.Post_publication_failure.Raised (Failure _) -> ()
   | Board.Post_publication_failure.Raised _
   | Board.Post_publication_failure.Board_error _ ->
     Alcotest.fail "expected the ordinary observer exception");
  let creation = match Board.Post_publication_failure.committed failure with
    | Some creation -> creation
    | None -> Alcotest.fail "committed publication lost its creation receipt"
  in
  let post_id = Board.Post_id.to_string creation.post.id in
  Alcotest.(check string) "the receipt retains the actual published body"
    "published before observer failure @unresolved-receipt" creation.post.body;
  Alcotest.(check string) "the receipt retains the actual author" "receipt-author"
    (Board.Agent_id.to_string creation.post.author);
  Alcotest.(check (list string)) "the admitted unresolved names are retained"
    ["unresolved-receipt"] creation.unresolved;
  Alcotest.(check bool) "the admitted audience is retained" true
    (creation.post.audience = Some creation.audience);
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok post ->
     Alcotest.(check string) "receipt identifies the actual committed post"
       creation.post.body post.body;
     Alcotest.(check string) "receipt retains the actual post identity" post_id
       (Board.Post_id.to_string post.id)
   | Error error -> Alcotest.fail (Board.show_board_error error));
  (match post_rows () with
   | [row] ->
     (match Board.post_of_yojson row with
      | Some post ->
        Alcotest.(check string) "the WAL contains the same committed ID" post_id
          (Board.Post_id.to_string post.id);
        Alcotest.(check string) "the WAL contains the actual receipt body"
          creation.post.body post.body
      | None -> Alcotest.fail "the actual post WAL row did not decode")
   | rows -> Alcotest.failf "expected one actual post WAL row, got %d" (List.length rows));
  (* No reset or replacement store: this takes the very persistence mutex
     whose held observer failed, so a poisoned lock cannot hide in readback. *)
  let later = create_post_exn ~author:"receipt-author" ~content:"later real write" in
  Alcotest.(check bool) "the later write has its own identity" false
    (String.equal post_id (Board.Post_id.to_string later.id));
  Alcotest.(check int) "both real posts remain in memory" 2
    (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
  Alcotest.(check int) "both actual writes reached the WAL" 2
    (List.length (post_rows ()))

let test_combined_reserved_held_observer_is_reraised_after_commit () =
  let original_backtrace = Printexc.get_raw_backtrace () in
  let original, original_backtrace = Eio.Exn.combine
      (Failure "ordinary held observer failure", original_backtrace)
      (Eio.Time.Timeout, original_backtrace) in
  let active = Board.global () in
  let calls = ref 0 in
  let raised = with_observer
      { noop_observer with observe_persist_lock_held_sec = (fun _ ->
          incr calls;
          if !calls = 1 then Printexc.raise_with_backtrace original original_backtrace) }
      (fun () ->
        match Board_dispatch.create_post_with_unresolved
                ~author:"combined-receipt-author"
                ~content:"committed before combined observer failure"
                ~post_kind:Board.Human_post () with
        | Ok _ -> Alcotest.fail "reserved observer failure must be rethrown"
        | Error failure ->
          Alcotest.fail ("reserved observer failure became a typed publication failure: " ^
            Board.Post_publication_failure.to_string failure)
        | exception (Eio.Exn.Multiple _ as raised) -> raised)
  in
  Alcotest.(check bool) "the original combined exception is rethrown" true (raised == original);
  Alcotest.(check int) "the held observer failed once" 1 !calls;
  Alcotest.(check bool) "the original store is retained" true (active == Board.global ());
  let post = match Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator () with
    | [post] -> post
    | posts -> Alcotest.failf "expected one actual committed post, got %d" (List.length posts)
  in
  let post_id = Board.Post_id.to_string post.id in
  Alcotest.(check string) "the actual committed body remains in memory"
    "committed before combined observer failure" post.body;
  (match post_rows () with
   | [row] ->
     (match Board.post_of_yojson row with
      | Some persisted ->
        Alcotest.(check string) "the actual committed identity remains on disk" post_id
          (Board.Post_id.to_string persisted.id);
        Alcotest.(check string) "disk retains the actual committed body" post.body persisted.body
      | None -> Alcotest.fail "the actual committed post row did not decode")
   | rows -> Alcotest.failf "expected one actual committed post row, got %d" (List.length rows));
  (* Keep the same store and mutex after the original reserved failure. *)
  let later = create_post_exn ~author:"combined-receipt-author" ~content:"later real write" in
  Alcotest.(check bool) "the later write has a distinct identity" false
    (String.equal post_id (Board.Post_id.to_string later.id));
  Alcotest.(check int) "both actual posts remain in memory" 2
    (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
  Alcotest.(check int) "both actual writes remain on disk" 2 (List.length (post_rows ()))

let test_fusion_combined_held_observer_preserves_replay_and_later_creation () =
  let original_backtrace = Printexc.get_raw_backtrace () in
  let original, original_backtrace = Eio.Exn.combine
      (Failure "ordinary Fusion held observer failure", original_backtrace)
      (Eio.Time.Timeout, original_backtrace) in
  let active = Board.global () in
  let content = "Fusion result committed before combined observer failure" in
  let create run_id =
    Board_dispatch.create_post_once_by_fusion_run_id
      ~fusion_run_id:run_id ~author:"fusion-observer-keeper" ~content
      ~post_kind:Board.System_post ~visibility:Board.Unlisted ~ttl_hours:1
      ~origin:
        { Board.turn_ref = None
        ; source = Some "fusion"
        ; fusion_run_id = Some run_id
        ; fusion_producer = Some "fusion-observer-keeper"
        }
      ()
  in
  let calls = ref 0 in
  let raised = with_observer
      { noop_observer with observe_persist_lock_held_sec = (fun _ ->
          incr calls;
          if !calls = 1 then Printexc.raise_with_backtrace original original_backtrace) }
      (fun () ->
        match create "fusion-combined-observer-first" with
        | Ok _ -> Alcotest.fail "the reserved Fusion observer failure must be rethrown"
        | Error failure ->
          Alcotest.fail ("the reserved Fusion observer failure became a typed failure: " ^
            Board.Post_publication_failure.to_string failure)
        | exception (Eio.Exn.Multiple _ as raised) -> raised)
  in
  Alcotest.(check bool) "Fusion rethrows the original combined exception" true
    (raised == original);
  Alcotest.(check int) "the actual Fusion held observer failed once" 1 !calls;
  let committed = match Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator () with
    | [post] -> post
    | posts -> Alcotest.failf "expected one committed Fusion post, got %d" (List.length posts)
  in
  let committed_id = Board.Post_id.to_string committed.id in
  Alcotest.(check string) "the actual Fusion body remains in memory" content committed.body;
  let persisted_ids () =
    List.map (fun row ->
      match Board.post_of_yojson row with
      | Some post ->
        Alcotest.(check string) "the actual Fusion body remains on disk" content post.body;
        Board.Post_id.to_string post.id
      | None -> Alcotest.fail "the actual Fusion WAL row did not decode")
      (post_rows ())
  in
  Alcotest.(check (list string)) "the committed Fusion identity remains on disk"
    [committed_id] (persisted_ids ());
  (* Reuse the original origin mutex: a swallowed poison must not masquerade
     as an idempotent replay, nor can a replacement store repair this test. *)
  (match create "fusion-combined-observer-first" with
   | Ok (Board.Post_already_present post) ->
     Alcotest.(check string) "the exact Fusion replay returns the committed ID"
       committed_id (Board.Post_id.to_string post.id)
   | Ok (Board.Post_created _) -> Alcotest.fail "the Fusion replay created a duplicate"
   | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure));
  Alcotest.(check int) "the Fusion replay adds no model post" 1
    (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
  Alcotest.(check (list string)) "the Fusion replay adds no disk row"
    [committed_id] (persisted_ids ());
  let later = match create "fusion-combined-observer-next" with
    | Ok (Board.Post_created creation) -> creation.post
    | Ok (Board.Post_already_present _) -> Alcotest.fail "a new Fusion run was treated as a replay"
    | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure)
  in
  let later_id = Board.Post_id.to_string later.id in
  Alcotest.(check bool) "a different Fusion origin creates its own identity" false
    (String.equal committed_id later_id);
  Alcotest.(check bool) "Fusion retained the original store throughout recovery" true
    (active == Board.global ());
  let ids = [committed_id; later_id] |> List.sort String.compare in
  Alcotest.(check (list string)) "both Fusion identities remain in the original model"
    ids
    (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()
     |> List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id)
     |> List.sort String.compare);
  Alcotest.(check (list string)) "both Fusion writes remain on disk"
    ids (persisted_ids () |> List.sort String.compare)

(* The acquire-wait sample is reported after the persistence lock is released,
   so its observer cannot prevent the write. A failing observer is reported
   with the receipt of the write that already happened. *)
let test_acquire_observer_failure_follows_the_write () =
  let calls = ref 0 in
  let failure = with_observer
      { noop_observer with observe_persist_lock_acquire_sec = (fun _ ->
          incr calls;
          if !calls = 1 then failwith "acquire observer failed") }
      (fun () ->
        match Board_dispatch.create_post_with_unresolved
                ~author:"receipt-author" ~content:"published before the acquire sample"
                ~post_kind:Board.Human_post () with
        | Ok _ -> Alcotest.fail "the failing acquire observer must be reported"
        | Error failure -> failure)
  in
  Alcotest.(check int) "the real acquire observer was invoked once" 1 !calls;
  check_effect "publication preceded the observer failure"
    Failure_effect.Proven_post_effect failure;
  let creation = match Board.Post_publication_failure.committed failure with
    | Some creation -> creation
    | None -> Alcotest.fail "the committed post lost its receipt"
  in
  (match Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator () with
   | [post] ->
     Alcotest.(check string) "the receipt names the published post"
       (Board.Post_id.to_string creation.post.id) (Board.Post_id.to_string post.id)
   | posts -> Alcotest.failf "expected one published post, got %d" (List.length posts));
  Alcotest.(check int) "the write reached the WAL once" 1 (List.length (post_rows ()));
  ignore (create_post_exn ~author:"receipt-author" ~content:"healthy after the observer failure");
  Alcotest.(check int) "the same store accepts a later real write" 2
    (List.length (post_rows ()))

(* #51273: both lock observers used to run while [persist_mutex] was held, so
   an observer that read Board through the same lock waited on itself forever.
   [read_post_for_evidence] takes the persistence lock. *)
let test_lock_observers_may_read_board_through_the_persistence_lock () =
  let seed = create_post_exn ~author:"reentrant-author" ~content:"read by the observer" in
  let post_id = Board.Post_id.to_string seed.id in
  let reading = ref false in
  let acquire_reads = ref 0 and held_reads = ref 0 in
  let read_back reads =
    (* The read below has its own persistence interval and reports it to this
       same observer; that nested report does not read again. *)
    if not !reading then begin
      reading := true;
      let result =
        Board_dispatch.read_post_for_evidence
          ~reader:Masc_board_handlers.Board_access.Operator ~post_id in
      reading := false;
      match result with
      | Ok (post : Board.post) ->
        Alcotest.(check string) "the observer reads the committed post"
          post_id (Board.Post_id.to_string post.id);
        incr reads
      | Error error ->
        Alcotest.fail (Board.show_board_error (Board.board_error_of_read_error error))
    end
  in
  with_observer
    { noop_observer with
      observe_persist_lock_acquire_sec = (fun _ -> read_back acquire_reads)
    ; observe_persist_lock_held_sec = (fun _ -> read_back held_reads)
    }
    (fun () ->
      ignore (create_post_exn ~author:"reentrant-author" ~content:"written while observed");
      match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator
              ~post_id ~author:"reentrant-commenter" ~content:"commented while observed" () with
      | Ok _ -> ()
      | Error error -> Alcotest.fail (Board.show_board_error error));
  Alcotest.(check bool) "the acquire observer read Board through the lock" true
    (!acquire_reads > 0);
  Alcotest.(check bool) "the held observer read Board through the lock" true
    (!held_reads > 0);
  Alcotest.(check int) "both observed writes are published" 2
    (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
  Alcotest.(check int) "both observed writes reached the WAL" 2 (List.length (post_rows ()))

let flush () =
  Board.flush_dirty (Board_dispatch.backend ())

let comment_rows () = Fs_compat.load_jsonl (Board.comments_path (Board.global ()))

let test_comment_append_failure_commits_nothing () =
  let post =
    create_post_exn ~author:"comment-wa-author"
      ~content:"comment write-ahead under test"
  in
  let post_id = Board.Post_id.to_string post.id in
  with_blocked_board_masc_dir (fun () ->
  (match
     Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"comment-wa-commenter"
       ~content:"must not survive a failed append" ()
   with
   | Ok _ -> Alcotest.fail "comment must not succeed when the append fails"
   | Error (Board.Io_error _) -> ()
   | Error e ->
     Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e))
  );
  (match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok [] -> ()
   | Ok comments ->
     Alcotest.failf "failed append left %d comment(s) in memory"
       (List.length comments)
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok loaded ->
     Alcotest.(check int)
       "failed append leaves reply_count untouched" 0 loaded.reply_count
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (* Nothing was committed, so the retry starts clean once the disk is
     healthy again. *)
  (match
     Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"comment-wa-commenter"
       ~content:"retry lands durably" ()
   with
   | Ok _ -> ()
   | Error e ->
     Alcotest.fail ("retry must succeed, got " ^ Board.show_board_error e));
  flush ();
  Alcotest.(check int)
    "comment WAL has exactly the retried row, no ghost from the failure" 1
    (List.length (comment_rows ()));
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Ok loaded ->
    Alcotest.(check int) "retry bumped reply_count" 1 loaded.reply_count
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_post_append_failure_commits_nothing () =
  with_blocked_board_masc_dir (fun () ->
  (match
     Board_dispatch.create_post ~author:"post-wa-author"
       ~content:"must not survive a failed append"
       ~post_kind:Board.Human_post ()
   with
   | Ok _ -> Alcotest.fail "post must not succeed when the append fails"
   | Error failure ->
     check_effect "blocked filesystem proves the append did not start"
       Failure_effect.Proven_pre_effect failure;
     Alcotest.(check bool) "append failure has no committed receipt" true
       (Option.is_none (Board.Post_publication_failure.committed failure));
     (match Board.Post_publication_failure.cause failure with
      | Board.Post_publication_failure.Board_error (Board.Io_error _) -> ()
      | Board.Post_publication_failure.Board_error _
      | Board.Post_publication_failure.Raised _ ->
        Alcotest.fail ("expected Io_error, got " ^
          Board.Post_publication_failure.to_string failure)))
  );
  (* Same store, no reset: the failed create must have left nothing in
     memory for the healthy-path retry to collide with. *)
  (match Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator () with
   | [] -> ()
   | posts ->
     Alcotest.failf "failed create left %d post(s) behind" (List.length posts));
  (match
     Board_dispatch.create_post ~author:"post-wa-author"
       ~content:"retry lands durably" ~post_kind:Board.Human_post ()
   with
   | Ok _ -> ()
   | Error e ->
     Alcotest.fail ("retry must succeed, got " ^
       Board.Post_publication_failure.to_string e));
  Alcotest.(check int)
    "exactly the retried post is listed" 1
    (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
  Alcotest.(check int)
    "posts WAL has exactly the retried row, no ghost from the failure" 1
    (List.length (Fs_compat.load_jsonl (Board.persist_path (Board.global ()))))

(* An edit that cannot reach disk used to report success: the rewrite carrying
   the new content and the new updated_at discarded its failure and the call
   returned Ok. A restart showed the old post, and a keeper board cursor rides
   updated_at, so nothing said the edit was gone (#26168). *)
let test_post_edit_failure_is_reported () =
  let post =
    match
      Board_dispatch.create_post ~author:"edit-author" ~content:"original"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e ->
      Alcotest.fail ("setup create must succeed, got " ^
        Board.Post_publication_failure.to_string e)
  in
  let post_id = Board.Post_id.to_string post.Board.id in
  with_blocked_board_masc_dir (fun () ->
  (match
     Board_dispatch.update_post ~post_id ~editor:"edit-author"
       ~content:"edit that cannot reach disk" ()
   with
   | Ok _ -> Alcotest.fail "an edit that cannot be persisted must not report success"
   | Error (Board.Io_error _) -> ()
   | Error e ->
     Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e))
  )

let test_restart_recomputes_reply_count_from_comment_wal () =
  let post =
    create_post_exn ~author:"restart-wa-author"
      ~content:"reply_count is derived on load"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"restart-wa-commenter"
       ~content:"counted after restart" ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (* No snapshot flush: the posts snapshot on disk still carries
     reply_count = 0 and the post's creation-time [updated_at]. The
     comment WAL row alone must restore both. *)
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Ok loaded ->
    Alcotest.(check int)
      "restart recomputes reply_count from the comment WAL" 1
      loaded.reply_count;
    (match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
     | Ok [ c ] ->
       Alcotest.(check (float 0.0))
         "restart restores updated_at to the comment high-water mark"
         c.created_at loaded.updated_at
     | Ok comments ->
       Alcotest.failf "expected exactly 1 comment, got %d"
         (List.length comments)
     | Error e -> Alcotest.fail (Board.show_board_error e))
  | Error e -> Alcotest.fail (Board.show_board_error e)

(* Adding a comment bumps the post's [updated_at] in memory and marks it
   dirty; only [flush_dirty] carries that to the posts file. That flush
   cleared the dirty flags before writing, so a failed write dropped the bump
   from the file and from the queue at once -- nothing would retry, and a
   keeper cursor already past the old [updated_at] would not rescan the post
   (#26168). The flags now survive the failure. *)
let test_flush_failure_keeps_the_post_bump_scheduled () =
  let post = create_post_exn ~author:"flush-retry-author" ~content:"flush retry body" in
  let store = Board_dispatch.backend () in
  flush ();
  Alcotest.(check bool) "flushed clean before the comment" false store.Board.dirty_posts;
  (match
     Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator
       ~post_id:(Board.Post_id.to_string post.Board.id)
       ~author:"flush-retry-commenter"
       ~content:"a reply that bumps updated_at"
       ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail ("comment must succeed: " ^ Board.show_board_error e));
  Alcotest.(check bool)
    "the comment marked the post dirty"
    true
    store.Board.dirty_posts;
  let before = Board.persist_error_count () in
  with_blocked_board_masc_dir (fun () ->
  flush ();
  Alcotest.(check bool)
    "the failed flush was counted"
    true
    (Board.persist_error_count () > before);
  Alcotest.(check bool)
    "the bump is still scheduled after the write failed"
    true
    store.Board.dirty_posts
  )
;;

let test_creation_commits_before_releasing_persistence () =
  let store = Board_dispatch.backend () in
  let counts store =
    Board.with_lock store (fun () ->
      [ Hashtbl.length store.Board.posts
      ; Hashtbl.length store.Board.comments
      ; Hashtbl.length store.Board.sub_boards
      ])
  in
  let released_states = ref [] in
  (* The state the creation in progress must already have reached. A creation
     may pass through more than one persistence section -- adding a comment
     writes, then reads the post back through [read_post_for_evidence] to pick
     the event's visibility (lib/board/board_core.ml:17-20) -- and every one of
     those sections must end with the new row already visible. Recording the
     state each section ends with against this target catches a write whose
     commit slipped outside the lock, which comparing only the final list
     would not. *)
  let expected = ref [ 0; 0; 0 ] in
  let violations = ref [] in
  let noop : Board_metrics_hooks.observer =
    { observe_persist_lock_acquire_sec = (fun _ -> ())
    ; observe_persist_lock_held_sec = (fun _ -> ())
    ; inc_dispatch_flusher_start_outcome = (fun () -> ())
    }
  in
  Eio.Switch.run (fun sw ->
    Eio.Switch.on_release sw (fun () -> Board_metrics_hooks.set_observer noop);
    Board_metrics_hooks.set_observer
      { noop with observe_persist_lock_held_sec = (fun _ ->
          (* This existing observer runs as soon as a persistence critical
             section is released, before the call that owned it continues.
             Every successful append must already be
             visible to the next snapshot writer before it can enter, so the
             section that performs a creation must end with the target state
             already reached. A later section that only reads carries the same
             target and passes. *)
          let actual = counts store in
          released_states := actual :: !released_states;
          if actual <> !expected then
            violations := (actual, !expected) :: !violations) };
    expected := [ 1; 0; 0 ];
    let post = create_post_exn ~author:"commit-author" ~content:"durable post" in
    expected := [ 1; 1; 0 ];
    (match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator
       ~post_id:(Board.Post_id.to_string post.id)
       ~author:"commit-commenter" ~content:"durable comment" () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Board.show_board_error e));
    expected := [ 1; 1; 1 ];
    (match Board_dispatch.create_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~slug:"commit-board"
       ~name:"Commit board" ~description:"Persistence boundary"
       ~owner:"commit-author" () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Board.show_board_error e)));
  (* A creation is not the only path through the persistence section: adding a
     comment reads the post back through [read_post_for_evidence] to decide the
     event's visibility, and that read shares the same lock order
     (lib/board/board_core.ml:17-20). A read-only section therefore ends with the
     same counts as the write that preceded it, and the per-section check above
     already admits it. What must not pass is a section that ends before the
     creation it performs is visible, and that is what [violations] records. *)
  Alcotest.(check (list (list (list int))))
    "no persistence section ends before its creation is committed"
    []
    (List.rev
       (List.map
          (fun (actual, want) -> [ actual; want ])
          !violations));
  Alcotest.(check (list (list int)))
    "post, comment and sub-board are committed before persistence unlock"
    [ [1; 0; 0]; [1; 1; 0]; [1; 1; 1] ]
    (let rec collapse previous acc = function
       | [] -> List.rev acc
       | counts :: rest when counts = previous -> collapse previous acc rest
       | counts :: rest -> collapse counts (counts :: acc) rest
     in
     collapse [] [] (List.rev !released_states));
  flush ();
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let reloaded = Board_dispatch.backend () in
  Alcotest.(check (list int)) "all three creations survive snapshot and reload"
    [1; 1; 1] (counts reloaded)

let test_dispatch_preparation_failure_proves_no_publication () =
  let preparation_calls = ref 0 in
  let persistence_calls = ref 0 in
  let expected_exception = Failure "flusher startup observer failed" in
  let check_pre_effect label = function
    | Ok _ -> Alcotest.fail (label ^ " must report the backend preparation failure")
    | Error failure ->
      check_effect (label ^ " did not begin publication")
        Failure_effect.Proven_pre_effect failure;
      Alcotest.(check bool) (label ^ " has no committed receipt") true
        (Option.is_none (Board.Post_publication_failure.committed failure));
      (match Board.Post_publication_failure.cause failure with
       | Board.Post_publication_failure.Raised exn ->
         Alcotest.(check bool) (label ^ " retains the preparation exception") true
           (exn == expected_exception)
       | Board.Post_publication_failure.Board_error _ ->
         Alcotest.fail (label ^ " lost the preparation exception"))
  in
  let create_fusion () =
    Board_dispatch.create_post_once_by_fusion_run_id
       ~fusion_run_id:"fusion-uninit-1" ~author:"uninit-author"
       ~content:"never started" ~post_kind:Board.Automation_post
       ~visibility:Board.Internal ~ttl_hours:0
       ~origin:
         { Board.turn_ref = None
         ; source = Some "fusion"
         ; fusion_run_id = Some "fusion-uninit-1"
         ; fusion_producer = Some "uninit-author"
         }
       ()
  in
  let saved_context = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state saved_context) (fun () ->
    Eio.Switch.run (fun sw ->
      Eio_context.set_switch sw;
      let finished = Eio.Switch.run (fun inner -> inner) in
      Board_dispatch.reset_for_test ();
      (* As in test_board_dispatch, a finished turn switch refuses the
         flusher fork. Its existing observer then fails inside backend (),
         before either Board creation function is entered. *)
      with_observer
        { noop_observer with
          observe_persist_lock_acquire_sec = (fun _ -> incr persistence_calls)
        ; inc_dispatch_flusher_start_outcome = (fun () ->
            incr preparation_calls;
            raise expected_exception)
        }
        (fun () -> Eio_context.with_turn_switch finished (fun () ->
          check_pre_effect "create_post_with_unresolved"
            (Board_dispatch.create_post_with_unresolved
               ~author:"uninit-author" ~content:"never started"
               ~post_kind:Board.Human_post ());
          check_pre_effect "create_post_once_by_fusion_run_id" (create_fusion ())));
      Alcotest.(check int) "both calls reached the failing preparation observer"
        2 !preparation_calls;
      Alcotest.(check int) "neither call entered persistence" 0 !persistence_calls;
      Alcotest.(check int) "neither call published a post" 0
        (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
      Alcotest.(check int) "neither call appended a WAL row" 0 (List.length (post_rows ()));
      (* The auto-initialized backend remains usable; do not replace it or
         install a lookup to make these unaddressed publications succeed. *)
      ignore (create_post_exn ~author:"uninit-author" ~content:"healthy after preparation failure");
      (match create_fusion () with
       | Ok (Board.Post_created _) -> ()
       | Ok (Board.Post_already_present _) ->
         Alcotest.fail "the failed preparation must not reserve the fusion publication"
       | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure));
      Alcotest.(check int) "both healthy publications reached the same store" 2
        (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
      Alcotest.(check int) "both healthy publications reached the WAL" 2
        (List.length (post_rows ()))))


let restart_board () =
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ())

let board_result_exn = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let create_policy_board ?(access = Board.Open) slug =
  Board_dispatch.create_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~slug ~name:"Policy admission"
    ~description:"Concurrent producer policy" ~owner:"policy-owner" ~access ()

let policy_post hearth =
  Board_dispatch.create_post_with_unresolved ~author:"policy-visitor"
    ~content:"post admitted by the current policy" ~post_kind:Board.Human_post
    ~hearth ()

let post_refusal_exn = function
  | Ok _ -> Alcotest.fail "the policy must refuse this publication"
  | Error failure ->
    check_effect "policy refusal precedes append"
      Failure_effect.Proven_pre_effect failure;
    Alcotest.(check bool) "a refused post has no committed receipt" true
      (Option.is_none (Board.Post_publication_failure.committed failure));
    failure

let check_denied_policy failure =
  match Board.Post_publication_failure.cause failure with
  | Board.Post_publication_failure.Board_error (Board.Validation_error _) -> ()
  | Board.Post_publication_failure.Board_error _
  | Board.Post_publication_failure.Raised _ ->
    Alcotest.fail (Board.Post_publication_failure.to_string failure)

let fanout_counts () =
  let signals = ref 0 and sse = ref 0 and changes = ref 0 in
  Board_dispatch.set_board_signal_hook (fun _ -> incr signals);
  Board_dispatch.set_board_sse_hook (function
    | Board_dispatch.Post_changed _ -> incr changes
    | _ -> incr sse);
  fun () -> [!signals; !sse; !changes]

let check_no_posts () =
  Alcotest.(check int) "no post reached memory" 0
    (List.length (Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator ()));
  Alcotest.(check int) "no post reached the WAL" 0 (List.length (post_rows ()))

let sub_board_rows () =
  let path = Board.sub_boards_path (Board.global ()) in
  if Sys.file_exists path then Fs_compat.load_jsonl path else []

(* Hold the persistence lock while [first] and then [second] start. Each runs
   until it waits for that lock, and [Eio.Mutex] admits waiters in arrival
   order, so [first] owns persistence with [second] already queued behind it.
   [while_queued] runs before either is admitted. *)
let queue_on_persistence ?(while_queued = fun () -> ()) ~sw first second =
  let first_done, resolve_first = Eio.Promise.create () in
  let second_done, resolve_second = Eio.Promise.create () in
  let first_waited, second_waited =
    Board.with_persist_lock (Board_dispatch.backend ()) (fun () ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve_first (first ()));
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve_second (second ()));
      let waited =
        not (Eio.Promise.is_resolved first_done),
        not (Eio.Promise.is_resolved second_done)
      in
      while_queued ();
      waited)
  in
  Alcotest.(check bool) "the first operation waits for persistence" true first_waited;
  Alcotest.(check bool) "the second operation queues behind it" true second_waited;
  let first_result = Eio.Promise.await first_done in
  first_result, Eio.Promise.await second_done

let test_queued_post_uses_the_policy_before_append () =
  ignore (board_result_exn (create_policy_board "queued-policy"));
  let observations = fanout_counts () in
  let failure = Eio.Switch.run (fun sw ->
    (* The post stages under Open policy, then queues behind the real update
       before that update has changed state. *)
    let updated, posted =
      queue_on_persistence ~sw
        (fun () ->
          Board_dispatch.update_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"queued-policy"
            ~access:Board.Owner_only ())
        (fun () -> policy_post "queued-policy")
    in
    ignore (board_result_exn updated);
    post_refusal_exn posted)
  in
  check_denied_policy failure;
  check_no_posts ();
  Alcotest.(check (list int)) "a refused post emits no fanout" [0; 0; 0]
    (observations ());
  restart_board ();
  check_no_posts ();
  let policy = board_result_exn
      (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"queued-policy") in
  Alcotest.(check bool) "the denying policy survives restart" true
    (policy.access = Board.Owner_only)

let test_post_admission_defers_the_policy_update () =
  ignore (board_result_exn (create_policy_board "admitted-policy"));
  let observations = fanout_counts () in
  let creation = Eio.Switch.run (fun sw ->
    (* The competing update queues behind the post before the post appends. It
       must wait there without mutating the policy. *)
    let posted, updated =
      queue_on_persistence ~sw
        ~while_queued:(fun () ->
          let policy = board_result_exn
              (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"admitted-policy") in
          Alcotest.(check bool) "a waiting update has not changed policy" true
            (policy.access = Board.Open))
        (fun () -> policy_post "admitted-policy")
        (fun () ->
          Board_dispatch.update_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"admitted-policy"
            ~access:Board.Owner_only ())
    in
    ignore (board_result_exn updated);
    match posted with
    | Ok creation -> creation
    | Error failure ->
      Alcotest.fail (Board.Post_publication_failure.to_string failure))
  in
  let post_id = Board.Post_id.to_string creation.post.id in
  Alcotest.(check int) "the admitted post has one WAL row" 1
    (List.length (post_rows ()));
  Alcotest.(check (list int)) "the accepted post emits its fanout once" [1; 1; 0]
    (observations ());
  check_denied_policy (post_refusal_exn (policy_post "admitted-policy"));
  Alcotest.(check int) "the later refusal appends nothing" 1
    (List.length (post_rows ()));
  restart_board ();
  let post = board_result_exn (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id) in
  Alcotest.(check string) "restart retains the exact admitted post" post_id
    (Board.Post_id.to_string post.id);
  Alcotest.(check string) "the retained receipt body survives restart"
    creation.post.body post.body;
  let policy = board_result_exn
      (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"admitted-policy") in
  Alcotest.(check bool) "the serialized update survives restart" true
    (policy.access = Board.Owner_only)

let test_same_slug_loser_never_appends () =
  let winner, loser, rows_after_each_interval = Eio.Switch.run (fun sw ->
    let rows_after_each_interval = ref [] in
    with_observer
      { noop_observer with
        observe_persist_lock_held_sec = (fun _ ->
          (* Observe each real write before a possible later cleanup rewrite
             could conceal an appended losing row. *)
          (* Observers run outside the lock now, and reading the rows
             yields: read first, then prepend, so one interval's sample does
             not overwrite another's. *)
          let rows = List.length (sub_board_rows ()) in
          rows_after_each_interval := rows :: !rows_after_each_interval)
      }
      (fun () ->
        let winner, loser =
          queue_on_persistence ~sw
            (fun () -> create_policy_board "one-policy")
            (fun () -> create_policy_board "one-policy")
        in
        board_result_exn winner, loser, List.rev !rows_after_each_interval))
  in
  (match loser with
   | Error (Board.Already_exists _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "two same-slug creations were accepted");
  (* The first interval is the empty one that queued both creations. *)
  Alcotest.(check (list int)) "neither persistence interval appends a losing row"
    [0; 1; 1] rows_after_each_interval;
  Alcotest.(check int) "one sub-board row remains" 1 (List.length (sub_board_rows ()));
  restart_board ();
  let reloaded = board_result_exn
      (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"one-policy") in
  Alcotest.(check string) "the winner keeps its identity after restart"
    (Board.Sub_board_id.to_string winner.id)
    (Board.Sub_board_id.to_string reloaded.id)

let test_new_restrictive_board_rechecks_a_queued_unknown_hearth () =
  let observations = fanout_counts () in
  let failure = Eio.Switch.run (fun sw ->
    let created, posted =
      queue_on_persistence ~sw
        (fun () -> create_policy_board ~access:Board.Owner_only "new-private-policy")
        (fun () -> policy_post "new-private-policy")
    in
    ignore (board_result_exn created);
    post_refusal_exn posted)
  in
  check_denied_policy failure;
  check_no_posts ();
  Alcotest.(check (list int)) "the newly denied post emits no fanout" [0; 0; 0]
    (observations ());
  restart_board ();
  check_no_posts ();
  let policy = board_result_exn
      (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"new-private-policy") in
  Alcotest.(check bool) "the new restrictive policy survives restart" true
    (policy.access = Board.Owner_only)

let test_partial_policy_source_refuses_only_hearth_posts () =
  ignore (board_result_exn (create_policy_board "partial-policy"));
  Fs_compat.append_file (Board.sub_boards_path (Board.global ())) "{broken-policy-row\n";
  restart_board ();
  Alcotest.(check int) "best-effort reads retain the valid policy row" 1
    (List.length (Board.list_sub_boards (Board.global ())));
  Alcotest.(check bool) "complete policy list refuses partial data" true
    (Result.is_error (Board_dispatch.list_sub_boards ~reader:Masc_board_handlers.Board_access.Operator ()));
  let observations = fanout_counts () in
  List.iter (fun hearth ->
    let failure = post_refusal_exn (policy_post hearth) in
    match Board.Post_publication_failure.cause failure with
    | Board.Post_publication_failure.Board_error (Board.Io_error _) -> ()
    | Board.Post_publication_failure.Board_error _
    | Board.Post_publication_failure.Raised _ ->
      Alcotest.fail (Board.Post_publication_failure.to_string failure))
    ["partial-policy"; "policy-may-be-in-the-unreadable-row"];
  check_no_posts ();
  Alcotest.(check (list int)) "partial source refusals emit no fanout" [0; 0; 0]
    (observations ());
  let post = create_post_exn ~author:"policy-visitor" ~content:"no hearth policy needed" in
  Alcotest.(check int) "a hearth-free post still appends" 1
    (List.length (post_rows ()));
  restart_board ();
  let reloaded = board_result_exn
      (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:(Board.Post_id.to_string post.id)) in
  Alcotest.(check string) "the hearth-free post survives the partial policy reload"
    post.body reloaded.body

let test_partial_policy_source_refuses_comment_publication () =
  ignore (board_result_exn (create_policy_board "comment-policy"));
  let post = match policy_post "comment-policy" with
    | Ok creation -> creation.post
    | Error failure ->
      Alcotest.fail (Board.Post_publication_failure.to_string failure)
  in
  let post_id = Board.Post_id.to_string post.id in
  Fs_compat.append_file (Board.sub_boards_path (Board.global ())) "{broken-comment-policy-row\n";
  let policy_source = Fs_compat.load_file (Board.sub_boards_path (Board.global ())) in
  restart_board ();
  let observations = fanout_counts () in
  (match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"policy-owner"
           ~content:"a comment needs a readable hearth policy" () with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "partial policy source admitted a comment");
  let comments = board_result_exn (Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id) in
  Alcotest.(check int) "no comment reached memory" 0 (List.length comments);
  let comment_path = Board.comments_path (Board.global ()) in
  let rows = if Sys.file_exists comment_path then comment_rows () else [] in
  Alcotest.(check int) "no comment reached the WAL" 0 (List.length rows);
  let retained = board_result_exn (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id) in
  Alcotest.(check int) "the refused comment leaves reply count unchanged" 0
    retained.reply_count;
  Alcotest.(check string) "the existing post remains readable" post.body retained.body;
  Alcotest.(check int) "the existing post remains the sole post row" 1
    (List.length (post_rows ()));
  Alcotest.(check (list int)) "the refused comment emits no fanout" [0; 0; 0]
    (observations ());
  Alcotest.(check string) "comment refusal preserves the corrupt policy source"
    policy_source (Fs_compat.load_file (Board.sub_boards_path (Board.global ())))

let test_queued_update_does_not_resurrect_a_deleted_policy () =
  ignore (board_result_exn (create_policy_board "deleted-policy"));
  let updated = Eio.Switch.run (fun sw ->
    let deleted, updated =
      queue_on_persistence ~sw
        (fun () ->
          Board_dispatch.delete_sub_board ~authorization:Board.Operator_sub_board_deletion ~sub_board_id:"deleted-policy")
        (fun () ->
          Board_dispatch.update_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:"deleted-policy"
            ~name:"must not resurrect" ())
    in
    (match board_result_exn deleted with
     | Board.Durable_deletion -> ()
     | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail);
    updated)
  in
  (match updated with
   | Error (Board.Invalid_id _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "a queued update accepted a deleted policy");
  Alcotest.(check int) "the deleted policy has no persisted row" 0
    (List.length (sub_board_rows ()));
  restart_board ();
  Alcotest.(check int) "a stale queued update does not revive the policy" 0
    (List.length ((Result.get_ok (Board_dispatch.list_sub_boards ~reader:Masc_board_handlers.Board_access.Operator ()))))

let () =
  Alcotest.run "board_comment_post_write_ahead"
    [
      ( "durability",
        [
          Alcotest.test_case "held observer failure retains committed receipt and later writes" `Quick
            (with_eio test_held_observer_failure_keeps_the_committed_receipt);
          Alcotest.test_case "combined reserved held observer is rethrown after commit" `Quick
            (with_eio test_combined_reserved_held_observer_is_reraised_after_commit);
          Alcotest.test_case "Fusion combined held observer preserves replay and later creation" `Quick
            (with_eio test_fusion_combined_held_observer_preserves_replay_and_later_creation);
          Alcotest.test_case "acquire observer failure follows the write" `Quick
            (with_eio test_acquire_observer_failure_follows_the_write);
          Alcotest.test_case "lock observers may read Board through the persistence lock" `Quick
            (with_eio test_lock_observers_may_read_board_through_the_persistence_lock);
          Alcotest.test_case "dispatch preparation failure proves no publication" `Quick
            (with_eio test_dispatch_preparation_failure_proves_no_publication);
          Alcotest.test_case "creations commit before persistence unlock" `Quick
            (with_eio test_creation_commits_before_releasing_persistence);
          Alcotest.test_case "queued post uses the policy before append" `Quick
            (with_eio test_queued_post_uses_the_policy_before_append);
          Alcotest.test_case "post admission defers the policy update" `Quick
            (with_eio test_post_admission_defers_the_policy_update);
          Alcotest.test_case "same-slug loser never appends" `Quick
            (with_eio test_same_slug_loser_never_appends);
          Alcotest.test_case "new restrictive board rechecks a queued unknown hearth" `Quick
            (with_eio test_new_restrictive_board_rechecks_a_queued_unknown_hearth);
          Alcotest.test_case "partial policy source refuses only hearth posts" `Quick
            (with_eio test_partial_policy_source_refuses_only_hearth_posts);
          Alcotest.test_case "partial policy source refuses comment publication" `Quick
            (with_eio test_partial_policy_source_refuses_comment_publication);
          Alcotest.test_case "queued update does not resurrect a deleted policy" `Quick
            (with_eio test_queued_update_does_not_resurrect_a_deleted_policy);
          Alcotest.test_case
            "comment: failed append leaves nothing committed" `Quick
            (with_eio test_comment_append_failure_commits_nothing);
          Alcotest.test_case "post: failed append leaves nothing committed"
            `Quick
            (with_eio test_post_append_failure_commits_nothing);
          Alcotest.test_case "post: an edit that cannot be persisted fails"
            `Quick
            (with_eio test_post_edit_failure_is_reported);
          Alcotest.test_case "restart derives reply_count from comment WAL"
            `Quick
            (with_eio test_restart_recomputes_reply_count_from_comment_wal);
          Alcotest.test_case "a failed flush keeps the post bump scheduled"
            `Quick
            (with_eio test_flush_failure_keeps_the_post_bump_scheduled);
        ] );
    ]
