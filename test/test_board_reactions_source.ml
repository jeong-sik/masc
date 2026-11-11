open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let require_io_error = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "unavailable reaction source granted authority"

let fresh_store base_path =
  Board_dispatch.reset_for_test ();
  Board.reset_global_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl ~base_path
    ~recipient_lookup:Recipient_lookup.none_declared ());
  Board_dispatch.backend ()

let post store content =
  match Board.create_post store ~lookup:Recipient_lookup.none_declared
      ~author:"reaction-source-owner" ~content ~post_kind:Board.Human_post
      ~ttl_hours:0 () with
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let toggle store (parent : Board.post) user emoji =
  Board.toggle_reaction store ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ~user_id:user ~emoji

let summaries store (parent : Board.post) user =
  require (Board.list_reactions store ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ~user_id:user ())

let dirty_through_vote store (parent : Board.post) =
  ignore (require (Board.vote store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"compaction-trigger"
    ~post_id:(Board.Post_id.to_string parent.id) ~direction:Board.Up));
  Alcotest.(check bool) "a real accepted vote schedules post compaction" true
    store.Board.dirty_posts

let reaction_cursor store =
  match store.Board.reactions_source with
  | Board.Reactions_readable observed ->
    Fs_compat.Private_jsonl_cursor.fingerprint observed.reaction_snapshot.cursor
  | Reactions_unobserved | Reactions_publishing _ | Reactions_refused _ | Reactions_unsettled _ ->
    Alcotest.fail "expected a fully observed reaction source"

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-reactions-source-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    let module Paths = Masc_board_handlers.Board_paths in
    let workspace_masc_dir = Common.masc_dir_from_base_path ~base_path in
    List.iter (fun kind -> Fs_compat.invalidate_cached_writer
      (Paths.file_path ~workspace_masc_dir kind))
      [Paths.Posts; Comments; Votes; Reactions; Sub_boards];
    (match before with None -> Unix.unsetenv "MASC_BASE_PATH"
     | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base_path)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_stale_toggle_preserves_accepted_reaction base_path =
  let stale = fresh_store base_path in
  let parent = post stale "a stale toggle cannot replace another accepted reaction" in
  let other = fresh_store base_path in
  ignore (require (toggle other parent "foreign-reactor" "🔥"));
  let path = Board.reactions_path stale in
  let accepted = Fs_compat.load_file path in
  require_io_error (toggle stale parent "stale-reactor" "👍");
  Alcotest.(check string) "refused rewrite preserves exact accepted bytes" accepted
    (Fs_compat.load_file path);
  Alcotest.(check int) "refused rewrite publishes no new model row" 0
    (Hashtbl.length stale.Board.reactions);
  require_io_error (Board.list_reactions stale ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ());
  let restarted = fresh_store base_path in
  match summaries restarted parent "foreign-reactor" with
  | [summary] ->
    Alcotest.(check string) "accepted emoji survives a fresh load" "🔥" summary.emoji;
    Alcotest.(check int) "only the accepted row exists" 1 summary.count;
    Alcotest.(check bool) "accepted reactor remains selected" true summary.reacted
  | _ -> Alcotest.fail "a stale toggle lost or replayed a reaction"

let test_stale_flush_preserves_accepted_reaction base_path =
  let stale = fresh_store base_path in
  let parent = post stale "a stale ordinary flush cannot compact away another reaction" in
  ignore (require (toggle stale parent "first-reactor" "👍"));
  dirty_through_vote stale parent;
  let other = fresh_store base_path in
  ignore (require (toggle other parent "foreign-reactor" "🔥"));
  let path = Board.reactions_path stale in
  let accepted = Fs_compat.load_file path in
  Board.flush_dirty stale;
  (match stale.Board.reactions_source with
   | Board.Reactions_refused { reaction_failure = Reactions_transaction_failed _; _ } -> ()
   | Reactions_unobserved | Reactions_readable _ | Reactions_publishing _
   | Reactions_unsettled _ | Reactions_refused _ ->
     Alcotest.fail "ordinary flush did not reach the stale reaction transaction");
  Alcotest.(check string) "stale compaction leaves both accepted rows intact" accepted
    (Fs_compat.load_file path);
  let restarted = fresh_store base_path in
  let rows = summaries restarted parent "foreign-reactor" in
  Alcotest.(check int) "both accepted reactions survive a fresh store" 2 (List.length rows);
  List.iter (fun (summary : Board.reaction_summary) ->
    Alcotest.(check int) "each accepted identity occurs once" 1 summary.count) rows;
  match List.find_opt (fun (summary : Board.reaction_summary) -> String.equal summary.emoji "🔥") rows with
  | Some summary -> Alcotest.(check bool) "foreign reaction remains selected" true summary.reacted
  | None -> Alcotest.fail "foreign reaction disappeared after stale flush"

let test_valid_orphan_survives_compaction base_path =
  let seeded = fresh_store base_path in
  let reaction : Board.reaction =
    { target_type = Board.Reaction_post; target_id = "p-retained-orphan"
    ; user_id = Result.get_ok (Board.Agent_id.of_string "orphan-reactor")
    ; emoji = "🔥"; created_at = 1.0 } in
  let path = Board.reactions_path seeded in
  let accepted = Yojson.Safe.to_string (Board.reaction_to_yojson reaction) ^ "\n" in
  Fs_compat.save_file path accepted;
  let loaded = fresh_store base_path in
  Alcotest.(check int) "a missing target does not invalidate a valid row" 1
    (require (Board.reload_reactions loaded));
  let parent = post loaded "actual dirty work selects orphan-preserving compaction" in
  dirty_through_vote loaded parent;
  let before = reaction_cursor loaded in
  Board.flush_dirty loaded;
  Alcotest.(check bool) "the real reaction rewrite published a fresh file receipt" false
    (String.equal before (reaction_cursor loaded));
  Alcotest.(check string) "compaction preserves the orphan and its original timestamp" accepted
    (Fs_compat.load_file path);
  let restarted = fresh_store base_path in
  match require (Board.list_reactions_batch restarted
    ~targets:[Board.Reaction_post, reaction.target_id] ~user_id:"orphan-reactor" ()) with
  | [(_, [summary])] ->
    Alcotest.(check int) "the retained orphan remains a source row" 1 summary.count;
    Alcotest.(check bool) "its actor identity is preserved" true summary.reacted
  | _ -> Alcotest.fail "valid orphan rows were garbage-collected"

let test_public_target_spelling_survives_restart base_path =
  let store = fresh_store base_path in
  let parent = post store "public raw target spelling must share the persisted identity" in
  let canonical = Board.Post_id.to_string parent.id in
  let raw = " " ^ canonical ^ " " in
  let accepted = (require (Board_dispatch.toggle_reaction
    ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
    ~target_id:raw ~user_id:"public-reactor" ~emoji:"🔥")).reaction in
  Alcotest.(check string) "accepted public receipt uses the canonical target" canonical accepted.target_id;
  let restarted = fresh_store base_path in
  Alcotest.(check int) "the strict decoder accepts the row after restart" 1
    (require (Board.reload_reactions restarted));
  (match require (Board.list_reactions restarted ~target_type:Board.Reaction_post
     ~target_id:raw ~user_id:"public-reactor" ()) with
   | [summary] -> Alcotest.(check bool) "single query shares the canonical target" true summary.reacted
   | _ -> Alcotest.fail "raw target spelling lost a persisted reaction");
  match require (Board.list_reactions_batch restarted
    ~targets:[Board.Reaction_post, raw] ~user_id:"public-reactor" ()) with
  | [((_, target_id), [summary])] ->
    Alcotest.(check string) "batch result uses the same canonical identity" canonical target_id;
    Alcotest.(check int) "the accepted row occurs once" 1 summary.count
  | _ -> Alcotest.fail "batch query disagrees with the accepted target identity"

let reaction_fault_store base_path io =
  let store = Board.create_store_with_reactions_io_for_testing ~base_path ~io () in
  List.iter (fun load -> match load store with
    | Ok _ -> ()
    | Error (path, error) ->
      Alcotest.failf "load %s: %s" path (Printexc.to_string error))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments];
  ignore (require (Board.reload_votes store));
  ignore (require (Board.reload_reactions store));
  store

let test_partial_source_is_not_empty_wire_state base_path =
  let seeded = fresh_store base_path in
  let parent = post seeded "partial reaction input stays visible without write authority" in
  ignore (require (toggle seeded parent "retained-reactor" "👍"));
  let path = Board.reactions_path seeded in
  let damaged = Fs_compat.load_file path ^ "{invalid reaction json\n" in
  Fs_compat.save_file path damaged;
  let partial = fresh_store base_path in
  require_io_error (Board.reload_reactions partial);
  Alcotest.(check int) "valid partial rows remain available for display" 1
    (Hashtbl.length partial.Board.reactions);
  let post_id = Board.Post_id.to_string parent.id in
  require_io_error (Board.list_reactions partial ~target_type:Board.Reaction_post
    ~target_id:post_id ~user_id:"retained-reactor" ());
  require_io_error (Board.list_reactions_batch partial
    ~targets:[Board.Reaction_post, post_id] ());
  let reader = Masc_board_handlers.Board_access.Operator in
  let reactions = Server_utils.board_reactions_for_post ~reader
    ~voter:(Some "retained-reactor") ~post_id in
  (match reactions with
   | None -> ()
   | Some _ -> Alcotest.fail "partial input became a known Dashboard summary");
  let json = Server_utils.board_post_dashboard_json ?reactions ~author_karma:0 parent in
  (match json with
   | `Assoc fields ->
     List.iter (fun key -> Alcotest.(check bool)
       ("unavailable Dashboard state omits " ^ key) false (List.mem_assoc key fields))
       ["reactions"; "supported_reaction_emojis"]
   | _ -> Alcotest.fail "expected a Dashboard post object");
  let module Http = Server_board_reaction_http in
  let targets = match Http.targets_of_strings ~target_type:(Some "post")
      ~target_ids:(Some post_id) with
    | Ok value -> value
    | Error error -> Alcotest.fail (Yojson.Safe.to_string (Http.error_json error)) in
  (match Http.list_batch_json ~reader ~actor:"retained-reactor" targets with
   | Ok _ -> Alcotest.fail "partial source produced a successful empty HTTP batch"
   | Error error -> Alcotest.(check bool) "the shared HTTP result is a storage failure" true
       (Http.error_status error = `Internal_server_error));
  require_io_error (toggle partial parent "refused-reactor" "🔥");
  Board.flush_dirty partial;
  Alcotest.(check string) "reload, toggle and flush retain the damaged source" damaged
    (Fs_compat.load_file path)

let test_unknown_rewrite_retains_exact_bytes_without_replay base_path =
  let seeded = fresh_store base_path in
  let parent = post seeded "an uncertain reaction removal is not replayed" in
  let armed = ref false and calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        incr calls;
        if !armed then (armed := false; raise (Failure "reaction parent sync")))
    ; close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = reaction_fault_store base_path io in
  ignore (require (toggle store parent "uncertain-reactor" "👍"));
  let path = Board.reactions_path store in
  let accepted = Fs_compat.load_file path in
  armed := true;
  require_io_error (toggle store parent "uncertain-reactor" "👍");
  Alcotest.(check bool) "the actual post-rename parent sync fault was reached" false !armed;
  Alcotest.(check string) "the rename is visible without a durability proof" ""
    (Fs_compat.load_file path);
  Alcotest.(check int) "uncertain removal leaves the prior model for display" 1
    (Hashtbl.length store.Board.reactions);
  let check_retained () = match store.Board.reactions_source with
    | Board.Reactions_unsettled { reaction_pending; _ } ->
      Alcotest.(check string) "the complete before observation stays owned" accepted
        reaction_pending.reaction_before.reaction_snapshot.bytes;
      Alcotest.(check string) "the exact intended removal stays owned" ""
        reaction_pending.reaction_intended_bytes
    | Reactions_unobserved | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ ->
      Alcotest.fail "the uncertain rewrite lost its pending evidence" in
  check_retained ();
  let before = !calls in
  require_io_error (Board.list_reactions store ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ());
  require_io_error (Board.reload_reactions store);
  require_io_error (toggle store parent "not-replayed" "🔥");
  Board.flush_dirty store;
  Alcotest.(check int) "ordinary operations perform no reaction IO replay" before !calls;
  check_retained ();
  let restarted = fresh_store base_path in
  Alcotest.(check int) "a fresh store can observe the currently empty file" 0
    (require (Board.reload_reactions restarted));
  Alcotest.(check int) "fresh observation sees no remaining reaction" 0
    (List.length (summaries restarted parent "uncertain-reactor"));
  check_retained ()

let test_known_rewrite_publishes_before_reserved_cleanup base_path =
  let seeded = fresh_store base_path in
  let parent = post seeded "accepted reactions survive reserved cleanup" in
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
  let store = reaction_fault_store base_path io in
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.reactions_path store));
  armed := true;
  (match toggle store parent "cleanup-reactor" "👍" with
   | _ -> Alcotest.fail "the original reserved cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  Alcotest.(check bool) "the actual stable-lock descriptor close failed" false !armed;
  ignore (reaction_cursor store);
  (match summaries store parent "cleanup-reactor" with
   | [summary] ->
     Alcotest.(check bool) "known success publishes before its cleanup cause escapes" true summary.reacted;
     Alcotest.(check int) "the accepted model changed once" 1 summary.count
   | _ -> Alcotest.fail "the known write did not publish its model");
  ignore (require (toggle store parent "next-reactor" "🔥"));
  let restarted = fresh_store base_path in
  Alcotest.(check int) "accepted write and subsequent toggle survive a fresh store" 2
    (List.length (summaries restarted parent "cleanup-reactor"))

let () =
  Alcotest.run "board_reactions_source"
    ["actual writers and fresh loads",
      [Alcotest.test_case "stale toggle retains another writer's reaction" `Quick
         (with_fixture test_stale_toggle_preserves_accepted_reaction);
       Alcotest.test_case "stale compaction retains another writer's reaction" `Quick
         (with_fixture test_stale_flush_preserves_accepted_reaction);
       Alcotest.test_case "valid orphan survives compaction and restart" `Quick
         (with_fixture test_valid_orphan_survives_compaction);
       Alcotest.test_case "public target spelling remains valid after restart" `Quick
         (with_fixture test_public_target_spelling_survives_restart)];
     "actual partial source and transaction settlement",
      [Alcotest.test_case "partial source is not empty Dashboard or HTTP state" `Quick
         (with_fixture test_partial_source_is_not_empty_wire_state);
       Alcotest.test_case "unknown rewrite retains exact bytes without replay" `Quick
         (with_fixture test_unknown_rewrite_retains_exact_bytes_without_replay);
       Alcotest.test_case "known rewrite publishes before reserved cleanup escapes" `Quick
         (with_fixture test_known_rewrite_publishes_before_reserved_cleanup)]]
