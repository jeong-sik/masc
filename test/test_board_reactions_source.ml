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
  Board.toggle_reaction store ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ~user_id:user ~emoji

let summaries store (parent : Board.post) user =
  require (Board.list_reactions store ~target_type:Board.Reaction_post
    ~target_id:(Board.Post_id.to_string parent.id) ~user_id:user ())

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
  let other = fresh_store base_path in
  ignore (require (toggle other parent "foreign-reactor" "🔥"));
  let path = Board.reactions_path stale in
  let accepted = Fs_compat.load_file path in
  Board.flush_dirty stale;
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
  Board.flush_dirty loaded;
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
         (with_fixture test_public_target_spelling_survives_restart)]]
