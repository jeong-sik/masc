(** Contract test for {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_posts} and
    {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_comments}.

    Prior to this contract change, the loaders had signature
    [store -> unit] and swallowed any [exn] from the JSONL read into an
    in-function [Log.BoardLog.error].  Callers could not distinguish a
    successful "no file" load from a partially-loaded store after an IO
    failure.

    The current contract returns [(int, string * exn) result] and forces
    callers to acknowledge failure.  These tests pin the [Ok 0] branch
    that is exercised on every fresh server start (no persistence file
    yet). *)

open Masc

let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-loader-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let test_load_persisted_posts_missing_file () =
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store () in
  match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
  | Ok 0 -> ()
  | Ok n -> Alcotest.failf "expected Ok 0 for missing file, got Ok %d" n
  | Error (path, e) ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error (%s, %s)"
      path
      (Printexc.to_string e)
;;

let test_load_persisted_comments_missing_file () =
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store () in
  match Masc_board_handlers.Board_votes_json.load_persisted_comments store with
  | Ok 0 -> ()
  | Ok n -> Alcotest.failf "expected Ok 0 for missing file, got Ok %d" n
  | Error (path, e) ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error (%s, %s)"
      path
      (Printexc.to_string e)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let read_source_file rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0 then true
    else if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  loop 0
;;

let test_global_fails_closed_on_corrupt_comments_file () =
  let _dir = fresh_test_base_path () in
  Board.ensure_masc_dir ();
  write_file (Board.comments_path ()) "{not-jsonl";
  Board.reset_global_for_test ();
  match Board.global () with
  | _ -> Alcotest.fail "expected board global startup to fail closed"
  | exception Board.Persistence_load_failed msg ->
    Alcotest.(check bool)
      "failure names comments loader"
      true
      (contains_substring msg "load comments failed")
;;

let test_global_lazy_slot_is_atomic () =
  let source = read_source_file "lib/board/board_votes.ml" in
  Alcotest.(check bool)
    "global lazy slot uses Atomic.t"
    true
    (contains_substring source "let global_lazy : store Eio.Lazy.t Atomic.t");
  Alcotest.(check bool)
    "global lazy slot is not a mutable ref"
    false
    (contains_substring source "let global_lazy : store Eio.Lazy.t ref")
;;

let () =
  Random.self_init ();
  Alcotest.run
    "board_persistence_load_contract"
    [ ( "loader_contract"
      , [ Alcotest.test_case
            "posts loader returns Ok 0 when file absent"
            `Quick
            test_load_persisted_posts_missing_file
        ; Alcotest.test_case
            "comments loader returns Ok 0 when file absent"
            `Quick
            test_load_persisted_comments_missing_file
        ; Alcotest.test_case
            "global fails closed on corrupt comments file"
            `Quick
            test_global_fails_closed_on_corrupt_comments_file
        ; Alcotest.test_case
            "global lazy slot is atomic"
            `Quick
            test_global_lazy_slot_is_atomic
        ] )
    ]
;;
