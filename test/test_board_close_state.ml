(** Typed close state for Board posts (task-1758/#39356).

    A post minted before this field existed, and every open post since,
    carries no ["closed"] key on disk: [Board_votes_json.optional_closed]
    reads that absence as [None] (open). [Board_votes.set_closed] and
    [reopen] write the JSONL row the same durable way as [set_pinned]
    (append, then commit in memory), so a restart between the write and
    the next read sees exactly what was persisted -- these tests restart
    the store after each mutation rather than trusting the in-memory
    copy. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-close-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

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

let store () =
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store -> store

let restart () =
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ()

let get_post_exn post_id =
  match Board_dispatch.get_post ~post_id with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

(* Close, restart (forcing a disk read, not the in-memory copy), and check
   every field of the recorded [closed] state round-trips: who closed it,
   the successor it names, and the summary. Also pins the pre-close state
   (no ["closed"] key at all) as the same shape a post minted before this
   field existed would have on disk. *)
let test_close_persists_successor_and_summary_across_restart () =
  let post =
    create_post_exn ~author:"close-author" ~content:"thread to close"
  in
  let post_id = Board.Post_id.to_string post.id in
  let successor =
    create_post_exn ~author:"close-author" ~content:"continues here"
  in
  let successor_id = Board.Post_id.to_string successor.id in
  restart ();
  let pre = get_post_exn post_id in
  Alcotest.(check bool) "open before any close call" true
    (Option.is_none pre.closed);
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"close-author"
       ~successor_id ~summary:"moved to the successor" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  let closed = get_post_exn post_id in
  match closed.closed with
  | None -> Alcotest.fail "expected closed state to survive a restart"
  | Some c ->
    Alcotest.(check string) "closed_by round-trips"
      "close-author" (Board.Agent_id.to_string c.closed_by);
    Alcotest.(check bool) "successor_id round-trips" true
      (match c.successor_id with
       | Some id -> String.equal (Board.Post_id.to_string id) successor_id
       | None -> false);
    Alcotest.(check (option string)) "summary round-trips"
      (Some "moved to the successor") c.summary;
    Alcotest.(check bool) "closed_at is a real timestamp" true
      (Float.is_finite c.closed_at && c.closed_at > 0.0)

(* Reopen clears [closed] back to [None] and that clearing is itself
   durable -- a restart after reopen must not resurrect the old close. *)
let test_reopen_clears_closed_state_across_restart () =
  let post =
    create_post_exn ~author:"reopen-author" ~content:"thread to reopen"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"reopen-author" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  Alcotest.(check bool) "closed after set_closed" true
    (Option.is_some (get_post_exn post_id).closed);
  (match Board_votes.reopen (store ()) ~post_id with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  Alcotest.(check bool) "open again after reopen + restart" true
    (Option.is_none (get_post_exn post_id).closed);
  (* Idempotent: reopening an already-open post is not an error. *)
  match Board_votes.reopen (store ()) ~post_id with
  | Ok () -> ()
  | Error e ->
    Alcotest.fail ("reopen on an open post must be Ok (), got " ^
                    Board.show_board_error e)

(* Re-closing an already-closed post overwrites the previous close (last
   write wins), it does not error and does not merge the two summaries. *)
let test_reclosing_overwrites_the_previous_close () =
  let post =
    create_post_exn ~author:"reclose-author" ~content:"closed twice"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"first-closer"
       ~summary:"first reason" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"second-closer"
       ~summary:"second reason" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  match (get_post_exn post_id).closed with
  | None -> Alcotest.fail "expected the post to remain closed"
  | Some c ->
    Alcotest.(check string) "second close_by wins"
      "second-closer" (Board.Agent_id.to_string c.closed_by);
    Alcotest.(check (option string)) "second summary wins"
      (Some "second reason") c.summary

(* set_closed and reopen on a post_id that does not exist report
   Post_not_found rather than silently doing nothing. *)
let test_close_and_reopen_report_post_not_found () =
  (match Board_votes.set_closed (store ()) ~post_id:"p-doesnotexist"
           ~closed_by:"someone" () with
   | Error (Board.Post_not_found _) -> ()
   | Ok () -> Alcotest.fail "set_closed on a missing post must not be Ok ()"
   | Error e ->
     Alcotest.fail ("expected Post_not_found, got " ^ Board.show_board_error e));
  match Board_votes.reopen (store ()) ~post_id:"p-doesnotexist" with
  | Error (Board.Post_not_found _) -> ()
  | Ok () -> Alcotest.fail "reopen on a missing post must not be Ok ()"
  | Error e ->
    Alcotest.fail ("expected Post_not_found, got " ^ Board.show_board_error e)

let () =
  Alcotest.run "board_close_state"
    [ ( "close_state"
      , [ Alcotest.test_case
            "close persists successor and summary across restart" `Quick
            (with_eio test_close_persists_successor_and_summary_across_restart)
        ; Alcotest.test_case
            "reopen clears closed state across restart" `Quick
            (with_eio test_reopen_clears_closed_state_across_restart)
        ; Alcotest.test_case
            "reclosing overwrites the previous close" `Quick
            (with_eio test_reclosing_overwrites_the_previous_close)
        ; Alcotest.test_case
            "close and reopen report post_not_found" `Quick
            (with_eio test_close_and_reopen_report_post_not_found)
        ] )
    ]
