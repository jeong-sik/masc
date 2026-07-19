(** Regression for autonomous Board dirty-projection recovery.

    This executable has a test-only persistence flush interval in [test/dune].
    Production continues to use the operator-owned Board flush interval. *)

open Masc

let () = Random.self_init ()

let fresh_base prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%06x" prefix (Random.bits ()))
;;

let await ~clock predicate =
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
    let rec loop () =
      if predicate ()
      then ()
      else begin
        Eio.Time.sleep clock 0.002;
        loop ()
      end
    in
    loop ())
;;

let test_failed_flush_retries_without_new_board_activity () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Unix.putenv "MASC_BASE_PATH" (fresh_base "masc-board-flush-source");
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let store =
    match Board_dispatch.backend () with
    | Board_dispatch.Jsonl store -> store
  in
  let post =
    match
      Board.create_post store ~author:"flusher-retry-author"
        ~content:"dirty projection survives a transient filesystem failure"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let post_id = Board.Post_id.to_string post.id in
  (match Board.vote store ~voter:"flusher-retry-voter" ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  Alcotest.(check bool) "vote dirtied the post projection" true store.Board.dirty_posts;
  let recovery_base = fresh_base "masc-board-flush-recovery" in
  Unix.putenv "MASC_BASE_PATH" recovery_base;
  let board_dir = Filename.dirname (Board.persist_path ()) in
  Fs_compat.mkdir_p (Filename.dirname board_dir);
  Fs_compat.save_file board_dir "blocks Board projection directory creation";
  let errors_before = Board.persist_error_count () in
  Eio.Switch.run (fun sw ->
    (match Board_dispatch.start_runtime_actors ~sw ~clock with
     | Ok () -> ()
     | Error failures ->
       Alcotest.fail
         (Board_dispatch.runtime_actor_start_failures_to_string failures));
    (match Board.request_flush store with
     | Ok () -> ()
     | Error detail -> Alcotest.fail detail);
    await ~clock (fun () -> Board.persist_error_count () > errors_before);
    Unix.unlink board_dir;
    Fs_compat.mkdir_p board_dir;
    await ~clock (fun () -> not store.Board.dirty_posts));
  let persisted_ids =
    Fs_compat.load_file (Board.persist_path ())
    |> String.split_on_char '\n'
    |> List.filter_map (fun row ->
      if String.equal row ""
      then None
      else Yojson.Safe.from_string row |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string_option)
  in
  Alcotest.(check bool)
    "autonomous retry persisted the original post"
    true
    (List.exists (String.equal post_id) persisted_ids)
;;

let () =
  Alcotest.run
    "board_flusher_autonomous_retry"
    [ ( "recovery"
      , [ Alcotest.test_case
            "failed flush retries without new Board activity"
            `Quick
            test_failed_flush_retries_without_new_board_activity
        ] )
    ]
;;
