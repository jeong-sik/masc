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
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(* Replaces the board's [.masc] directory with a regular file so any
   subsequent [Fs_compat.mkdir_p]/[append_file] under it raises
   [Sys_error] (ENOTDIR). Same fixture as
   [test_board_vote_persistence.ml]; duplicated locally per that
   suite's per-file fixture convention. *)
let block_board_masc_dir_with_file () =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-comment-wa-blocked-%06x" (Random.bits ()))
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
  Board_dispatch.init_jsonl ();
  f ()

let create_post_exn ~author ~content =
  match
    Board_dispatch.create_post ~author ~content ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

let flush () =
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store -> Board.flush_dirty store

let comment_rows () = Fs_compat.load_jsonl (Board.comments_path ())

let test_comment_append_failure_commits_nothing () =
  let post =
    create_post_exn ~author:"comment-wa-author"
      ~content:"comment write-ahead under test"
  in
  let post_id = Board.Post_id.to_string post.id in
  let working_base =
    Sys.getenv_opt "MASC_BASE_PATH" |> Option.value ~default:""
  in
  ignore (block_board_masc_dir_with_file ());
  (match
     Board_dispatch.add_comment ~post_id ~author:"comment-wa-commenter"
       ~content:"must not survive a failed append" ()
   with
   | Ok _ -> Alcotest.fail "comment must not succeed when the append fails"
   | Error (Board.Io_error _) -> ()
   | Error e ->
     Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Unix.putenv "MASC_BASE_PATH" working_base;
  (match Board_dispatch.get_comments ~post_id with
   | Ok [] -> ()
   | Ok comments ->
     Alcotest.failf "failed append left %d comment(s) in memory"
       (List.length comments)
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match Board_dispatch.get_post ~post_id with
   | Ok loaded ->
     Alcotest.(check int)
       "failed append leaves reply_count untouched" 0 loaded.reply_count
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (* Nothing was committed, so the retry starts clean once the disk is
     healthy again. *)
  (match
     Board_dispatch.add_comment ~post_id ~author:"comment-wa-commenter"
       ~content:"retry lands durably" ()
   with
   | Ok _ -> ()
   | Error e ->
     Alcotest.fail ("retry must succeed, got " ^ Board.show_board_error e));
  flush ();
  Alcotest.(check int)
    "comment WAL has exactly the retried row, no ghost from the failure" 1
    (List.length (comment_rows ()));
  match Board_dispatch.get_post ~post_id with
  | Ok loaded ->
    Alcotest.(check int) "retry bumped reply_count" 1 loaded.reply_count
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_post_append_failure_commits_nothing () =
  let working_base =
    Sys.getenv_opt "MASC_BASE_PATH" |> Option.value ~default:""
  in
  ignore (block_board_masc_dir_with_file ());
  (match
     Board_dispatch.create_post ~author:"post-wa-author"
       ~content:"must not survive a failed append"
       ~post_kind:Board.Human_post ()
   with
   | Ok _ -> Alcotest.fail "post must not succeed when the append fails"
   | Error (Board.Io_error _) -> ()
   | Error e ->
     Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Unix.putenv "MASC_BASE_PATH" working_base;
  (* Same store, no reset: the failed create must have left nothing in
     memory for the healthy-path retry to collide with. *)
  (match Board_dispatch.list_posts () with
   | [] -> ()
   | posts ->
     Alcotest.failf "failed create left %d post(s) behind" (List.length posts));
  (match
     Board_dispatch.create_post ~author:"post-wa-author"
       ~content:"retry lands durably" ~post_kind:Board.Human_post ()
   with
   | Ok _ -> ()
   | Error e ->
     Alcotest.fail ("retry must succeed, got " ^ Board.show_board_error e));
  Alcotest.(check int)
    "exactly the retried post is listed" 1
    (List.length (Board_dispatch.list_posts ()));
  Alcotest.(check int)
    "posts WAL has exactly the retried row, no ghost from the failure" 1
    (List.length (Fs_compat.load_jsonl (Board.persist_path ())))

(* An edit that cannot reach disk used to report success: the rewrite carrying
   the new content and the new updated_at discarded its failure and the call
   returned Ok. A restart showed the old post, and a keeper board cursor rides
   updated_at, so nothing said the edit was gone (#26168). *)
let test_post_edit_failure_is_reported () =
  let working_base =
    Sys.getenv_opt "MASC_BASE_PATH" |> Option.value ~default:""
  in
  let post =
    match
      Board_dispatch.create_post ~author:"edit-author" ~content:"original"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e ->
      Alcotest.fail ("setup create must succeed, got " ^ Board.show_board_error e)
  in
  let post_id = Board.Post_id.to_string post.Board.id in
  ignore (block_board_masc_dir_with_file ());
  (match
     Board_dispatch.update_post ~post_id ~editor:"edit-author"
       ~content:"edit that cannot reach disk" ()
   with
   | Ok _ -> Alcotest.fail "an edit that cannot be persisted must not report success"
   | Error (Board.Io_error _) -> ()
   | Error e ->
     Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Unix.putenv "MASC_BASE_PATH" working_base

let test_restart_recomputes_reply_count_from_comment_wal () =
  let post =
    create_post_exn ~author:"restart-wa-author"
      ~content:"reply_count is derived on load"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_dispatch.add_comment ~post_id ~author:"restart-wa-commenter"
       ~content:"counted after restart" ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (* No snapshot flush: the posts snapshot on disk still carries
     reply_count = 0 and the post's creation-time [updated_at]. The
     comment WAL row alone must restore both. *)
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  match Board_dispatch.get_post ~post_id with
  | Ok loaded ->
    Alcotest.(check int)
      "restart recomputes reply_count from the comment WAL" 1
      loaded.reply_count;
    (match Board_dispatch.get_comments ~post_id with
     | Ok [ c ] ->
       Alcotest.(check (float 0.0))
         "restart restores updated_at to the comment high-water mark"
         c.created_at loaded.updated_at
     | Ok comments ->
       Alcotest.failf "expected exactly 1 comment, got %d"
         (List.length comments)
     | Error e -> Alcotest.fail (Board.show_board_error e))
  | Error e -> Alcotest.fail (Board.show_board_error e)

let () =
  Alcotest.run "board_comment_post_write_ahead"
    [
      ( "durability",
        [
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
        ] );
    ]
