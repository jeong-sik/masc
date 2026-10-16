(** Delete durability and rewrite retry (#26169).

    [Board.delete_post] is authoritative in memory: it removes the post and
    its comments, clears the dirty flags, then rewrites the four jsonl
    snapshots. Before the re-mark landed, a failed rewrite ended there — the
    dirty flags were already clear, so no later flush rewrote the files and
    the deleted post resurfaced from disk on restart. [flush_dirty] had
    received the same fix in #26168; this suite pins the delete half:

    - a delete whose snapshot rewrite fails reports [Io_error] and leaves
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
  Board_dispatch.init_jsonl ();
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
  (match Board_dispatch.delete_post ~post_id:doomed_id with
   | Error (Board.Io_error _) -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok () -> Alcotest.fail "failed snapshot rewrites must not report durable deletion");
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
       | Error (Board.Io_error _) -> ()
       | Error error -> Alcotest.fail (Board.show_board_error error)
       | Ok () -> Alcotest.fail "one failed snapshot must refuse durable deletion");
      Alcotest.(check bool) "failed final snapshot stays scheduled" true
        ((store ()).Board.dirty_posts || (store ()).Board.dirty_comments));
  flush ();
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let restored = store () in
  Alcotest.(check int) "restart has no deleted posts" 0 (Hashtbl.length restored.posts);
  Alcotest.(check int) "restart has no deleted replies" 0 (Hashtbl.length restored.comments);
  Alcotest.(check int) "restart has no deleted votes" 0 (Hashtbl.length restored.vote_log);
  Alcotest.(check int) "restart has no deleted reactions" 0 (Hashtbl.length restored.reactions)

let () =
  Alcotest.run "board_delete_rewrite_requeue"
    [ ( "delete_post",
        [ Alcotest.test_case
            "a failed delete rewrite keeps the resurrection scheduled"
            `Quick
            (with_eio test_delete_rewrite_failure_keeps_resurrection_scheduled)
        ; Alcotest.test_case "posts rewrite failure returns Io_error and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.persist_path))
        ; Alcotest.test_case "comments rewrite failure returns Io_error and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.comments_path))
        ; Alcotest.test_case "votes rewrite failure returns Io_error and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.vote_log_path))
        ; Alcotest.test_case "reactions rewrite failure returns Io_error and retries" `Quick
            (with_eio (test_individual_snapshot_failure Board.reactions_path))
        ] )
    ]
