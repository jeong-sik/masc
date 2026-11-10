open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let fresh_store base_path =
  Board_dispatch.reset_for_test ();
  Board.reset_global_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl ~base_path
    ~recipient_lookup:Recipient_lookup.none_declared ());
  Board.global ()

let post store content =
  match Board.create_post store ~lookup:Recipient_lookup.none_declared
      ~author:"vote-source-owner" ~content ~post_kind:Board.Human_post
      ~ttl_hours:0 () with
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let cast store (parent : Board.post) voter =
  Board.vote store ~post_id:(Board.Post_id.to_string parent.id)
    ~voter ~direction:Board.Up

let require_io_error = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "unavailable vote source was accepted"

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-votes-source-" "" in
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

let test_stale_snapshot_preserves_accepted_vote base_path =
  let stale = fresh_store base_path in
  let parent = post stale "both accepted votes must survive an old flush" in
  ignore (require (cast stale parent "first-voter"));
  let other = fresh_store base_path in
  ignore (require (cast other parent "foreign-voter"));
  let path = Board.vote_log_path stale in
  let accepted = Fs_compat.load_file path in
  Board.flush_dirty stale;
  Alcotest.(check string) "stale full ledger cannot remove the foreign vote" accepted
    (Fs_compat.load_file path);
  let restarted = fresh_store base_path in
  let loaded = require (Board.get_post restarted
      ~post_id:(Board.Post_id.to_string parent.id)) in
  Alcotest.(check int) "fresh counts include both accepted votes" 2 loaded.votes_up;
  List.iter (fun voter ->
    match require (Board.current_vote_for_post restarted ~voter
        ~post_id:(Board.Post_id.to_string parent.id)) with
    | Some Board.Up -> ()
    | Some Board.Down | None -> Alcotest.fail "an accepted vote disappeared")
    ["first-voter"; "foreign-voter"]

let test_stale_append_cannot_adopt_a_foreign_ledger base_path =
  let stale = fresh_store base_path in
  let parent = post stale "a stale append cannot make an incomplete model authoritative" in
  let other = fresh_store base_path in
  ignore (require (cast other parent "foreign-voter"));
  let path = Board.vote_log_path stale in
  let accepted = Fs_compat.load_file path in
  require_io_error (cast stale parent "stale-voter");
  Alcotest.(check string) "refused append leaves the accepted ledger unchanged" accepted
    (Fs_compat.load_file path);
  Alcotest.(check int) "refused append does not publish a new model vote" 0
    (require (Board.get_post stale ~post_id:(Board.Post_id.to_string parent.id))).votes_up;
  let restarted = fresh_store base_path in
  Alcotest.(check int) "fresh counts retain the one accepted vote" 1
    (require (Board.get_post restarted ~post_id:(Board.Post_id.to_string parent.id))).votes_up;
  (match require (Board.current_vote_for_post restarted ~voter:"stale-voter"
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | None -> ()
   | Some _ -> Alcotest.fail "a refused append was replayed")

let () =
  Alcotest.run "board_votes_source"
    ["actual writers and fresh loads",
      [Alcotest.test_case "stale snapshot retains another writer's vote" `Quick
         (with_fixture test_stale_snapshot_preserves_accepted_vote);
       Alcotest.test_case "stale append cannot adopt a newer ledger" `Quick
         (with_fixture test_stale_append_cannot_adopt_a_foreign_ledger)]]
