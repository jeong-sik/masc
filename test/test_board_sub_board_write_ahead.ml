(** Write-ahead durability for sub-board creation (#29004).

    create_sub_board previously mutated the in-memory store, then ran
    a durable append whose failure was swallowed (persist-error
    counter + unit): the caller got [Ok sb] for a sub-board that
    existed only in memory and vanished on restart — the silent
    persist failure class. These tests pin the converted contract:

    - a failed durable append commits nothing and surfaces a typed
      [Io_error];
    - the same call succeeds once the disk is healthy again;
    - a successful create is durable across a restart with no
      snapshot flush in between. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-subboard-wa-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(* Replaces the board's [.masc] directory with a regular file so any
   subsequent [Fs_compat.mkdir_p]/[append_file] under it raises
   [Sys_error] (ENOTDIR). Same fixture as
   [test_board_vote_persistence.ml], duplicated per that suite's
   per-file fixture convention. *)
let block_board_masc_dir_with_file () =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-subboard-wa-blocked-%06x" (Random.bits ()))
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

let create ~slug =
  Board_dispatch.create_sub_board ~slug ~name:"WA" ~description:"write-ahead"
    ~owner:"subboard-wa-owner" ()

let find_by_slug slug =
  Board_dispatch.list_sub_boards ()
  |> List.find_opt (fun (sb : Board.sub_board) -> String.equal sb.slug slug)

let test_failed_append_commits_nothing () =
  let working_base =
    Sys.getenv_opt "MASC_BASE_PATH" |> Option.value ~default:""
  in
  ignore (block_board_masc_dir_with_file ());
  let before_errors = Board.persist_error_count () in
  (match create ~slug:"wa-blocked" with
   | Ok _ -> Alcotest.fail "create must not succeed when the append fails"
   | Error (Board.Io_error _) -> ()
   | Error e ->
     Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Alcotest.(check bool)
    "persist error counter incremented" true
    (Board.persist_error_count () > before_errors);
  Unix.putenv "MASC_BASE_PATH" working_base;
  (* Nothing was committed: the same slug is free once the disk is
     healthy again. *)
  (match create ~slug:"wa-blocked" with
   | Ok _ -> ()
   | Error e ->
     Alcotest.fail ("retry must succeed, got " ^ Board.show_board_error e));
  match find_by_slug "wa-blocked" with
  | Some _ -> ()
  | None -> Alcotest.fail "retried sub-board missing from the store"

let test_create_is_durable_across_restart () =
  (match create ~slug:"wa-durable" with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (* No snapshot flush: the append alone must carry the sub-board
     across a restart. *)
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  match find_by_slug "wa-durable" with
  | Some sb ->
    Alcotest.(check string) "slug survives restart" "wa-durable" sb.Board.slug
  | None -> Alcotest.fail "sub-board lost across restart"

let () =
  Alcotest.run "board_sub_board_write_ahead"
    [
      ( "durability",
        [
          Alcotest.test_case "failed append leaves nothing committed" `Quick
            (with_eio test_failed_append_commits_nothing);
          Alcotest.test_case "create is durable across restart" `Quick
            (with_eio test_create_is_durable_across_restart);
        ] );
    ]
