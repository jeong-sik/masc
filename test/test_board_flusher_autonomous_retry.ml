(** Regression for autonomous Board dirty-projection recovery.

    This executable has a test-only persistence flush interval in [test/dune].
    Production continues to use the operator-owned Board flush interval. *)

open Masc

let () = Random.self_init ()

let request_flush = Masc_board_handlers.Board_core_persist.request_flush

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
    (match request_flush store with
     | Ok () -> ()
     | Error detail -> Alcotest.fail detail);
    await ~clock (fun () -> Board.persist_error_count () > errors_before));
  Unix.unlink board_dir;
  Fs_compat.mkdir_p board_dir;
  Eio.Switch.run (fun sw ->
    (match Board_dispatch.start_runtime_actors ~sw ~clock with
     | Ok () -> ()
     | Error failures ->
       Alcotest.fail
         (Board_dispatch.runtime_actor_start_failures_to_string failures));
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

let test_failed_flush_does_not_block_sweep () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Unix.putenv "MASC_BASE_PATH" (fresh_base "masc-board-flusher-fair-source");
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let store =
    match Board_dispatch.backend () with
    | Board_dispatch.Jsonl store -> store
  in
  let post =
    match
      Board.create_post store ~author:"flusher-fair-author"
        ~content:"an expired post must sweep while flush recovery is pending"
        ~post_kind:Board.Human_post ~ttl_hours:1 ()
    with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let post_id = Board.Post_id.to_string post.id in
  Hashtbl.replace store.Board.posts post_id
    { post with expires_at = Time_compat.now () -. 1.0 };
  (match
     Board.vote store ~voter:"flusher-fair-voter" ~post_id
       ~direction:Board.Up
   with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  let recovery_base = fresh_base "masc-board-flusher-fair-recovery" in
  Unix.putenv "MASC_BASE_PATH" recovery_base;
  let persist_path = Board.persist_path () in
  Fs_compat.mkdir_p persist_path;
  let errors_before = Board.persist_error_count () in
  Eio.Switch.run (fun sw ->
    (match Board_dispatch.start_runtime_actors ~sw ~clock with
     | Ok () -> ()
     | Error failures ->
       Alcotest.fail
         (Board_dispatch.runtime_actor_start_failures_to_string failures));
    await ~clock (fun () -> Board.persist_error_count () > errors_before);
    await ~clock (fun () -> not (Hashtbl.mem store.Board.posts post_id));
    Unix.rmdir persist_path;
    await ~clock (fun () -> not store.Board.dirty_posts));
  Alcotest.(check bool)
    "expired post remained swept after projection recovery"
    false
    (Hashtbl.mem store.Board.posts post_id)
;;

let test_routing_recovery_resumes_on_replacement_owner () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Unix.putenv "MASC_BASE_PATH" (fresh_base "masc-board-routing-owner-recovery");
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let delivery_enabled = Atomic.make false in
  let first_attempt, resolve_first_attempt = Eio.Promise.create () in
  let first_attempt_resolved = Atomic.make false in
  let delivered, resolve_delivered = Eio.Promise.create () in
  let delivered_resolved = Atomic.make false in
  Board_dispatch.set_board_signal_hook (fun _event ->
    if Atomic.get delivery_enabled
    then begin
      if Atomic.compare_and_set delivered_resolved false true
      then Eio.Promise.resolve resolve_delivered ();
      Ok Board_dispatch.Atomic_sink_accepted
    end
    else begin
      if Atomic.compare_and_set first_attempt_resolved false true
      then Eio.Promise.resolve resolve_first_attempt ();
      Error "forced transient routing failure"
    end);
  Eio.Switch.run (fun first_owner ->
    (match Board_dispatch.start_runtime_actors ~sw:first_owner ~clock with
     | Ok () -> ()
     | Error failures ->
       Alcotest.fail
         (Board_dispatch.runtime_actor_start_failures_to_string failures));
    (match
       Board_dispatch.create_post ~author:"routing-owner-recovery-author"
         ~content:"committed routing survives owner replacement"
         ~post_kind:Board.Human_post ()
     with
     | Ok _ -> ()
     | Error error -> Alcotest.fail (Board.show_board_error error));
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      Eio.Promise.await first_attempt));
  Atomic.set delivery_enabled true;
  Eio.Switch.run (fun replacement_owner ->
    (match
       Board_dispatch.start_runtime_actors ~sw:replacement_owner ~clock
     with
     | Ok () -> ()
     | Error failures ->
       Alcotest.fail
         (Board_dispatch.runtime_actor_start_failures_to_string failures));
    Eio.Time.with_timeout_exn clock 1.0 (fun () -> Eio.Promise.await delivered))
;;

let test_sse_hook_failure_boundary () =
  let event =
    Board_dispatch.Post_voted
      { post_id = "sse-failure-boundary-post"
      ; voter = "sse-failure-boundary-voter"
      ; direction = Board.Up
      }
  in
  Board_dispatch.set_board_sse_hook (fun _ ->
    raise (Failure "forced observable SSE hook failure"));
  Board_dispatch.emit_board_sse_event event;
  Board_dispatch.set_board_sse_hook (fun _ -> raise Out_of_memory);
  (match Board_dispatch.emit_board_sse_event event with
   | exception Out_of_memory -> ()
   | exception cause ->
     Alcotest.failf
       "expected Out_of_memory propagation, got %s"
       (Printexc.to_string cause)
   | () -> Alcotest.fail "Out_of_memory must not be suppressed as an SSE failure");
  Board_dispatch.set_board_sse_hook (fun _ -> ())
;;

let () =
  Alcotest.run
    "board_flusher_autonomous_retry"
    [ ( "recovery"
      , [ Alcotest.test_case
            "failed flush retries without new Board activity"
            `Quick
            test_failed_flush_retries_without_new_board_activity
        ; Alcotest.test_case
            "failed flush does not block sweep"
            `Quick
            test_failed_flush_does_not_block_sweep
        ] )
    ; ( "routing"
      , [ Alcotest.test_case
            "routing recovery resumes on replacement owner"
            `Quick
            test_routing_recovery_resumes_on_replacement_owner
        ] )
    ; ( "sse"
      , [ Alcotest.test_case
            "hook failure boundary"
            `Quick
            test_sse_hook_failure_boundary
        ] )
    ]
;;
