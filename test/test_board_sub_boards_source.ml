open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let require_unavailable = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "an incomplete policy source was accepted"

let reload store = match Board.reload_sub_boards store with
  | Ok count -> count
  | Error (path, error) -> Alcotest.failf "reload %s: %s" path (Printexc.to_string error)

let new_store base_path =
  let store = Board.create_store ~base_path () in
  ignore (reload store);
  store

let create store slug = Board.create_sub_board store ~slug ~name:slug
    ~description:"preserve independently accepted policy" ~owner:"policy-owner" ()

let get store slug = require (Board.get_sub_board store ~sub_board_id:slug)

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-policy-source-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Board.reset_global_for_test ();
    Board_dispatch.reset_for_test ();
    (match before with
     | None -> Unix.unsetenv "MASC_BASE_PATH"
     | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base_path)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_stale_update_preserves_foreign_policy base_path =
  let first = new_store base_path in
  ignore (require (create first "existing"));
  let stale = new_store base_path in
  ignore (require (create first "foreign"));
  let path = Board.sub_boards_path first in
  let bytes = Fs_compat.load_file path in
  require_unavailable (Board.update_sub_board stale ~sub_board_id:"existing" ~name:"not committed" ());
  Alcotest.(check string) "stale update preserves foreign bytes" bytes (Fs_compat.load_file path);
  Alcotest.(check int) "failed update leaves the old display model" 1
    (List.length (Board.list_sub_boards stale));
  require_unavailable (Board.read_sub_boards stale);
  List.iter (fun slug -> require_unavailable (Board.get_sub_board stale ~sub_board_id:slug))
    ["existing"; "foreign"; "absent"];
  Alcotest.(check int) "explicit complete reload installs both policies" 2 (reload stale);
  ignore (require (Board.update_sub_board stale ~sub_board_id:"existing" ~name:"committed" ()));
  let restarted = new_store base_path in
  Alcotest.(check string) "the updated policy survives restart" "committed" (get restarted "existing").name;
  Alcotest.(check string) "the foreign policy survives update and restart" "foreign"
    (get restarted "foreign").name

let test_stale_append_and_delete_preserve_foreign_policy base_path =
  let first = new_store base_path in
  ignore (require (create first "existing"));
  let stale = new_store base_path in
  ignore (require (create first "foreign"));
  let path = Board.sub_boards_path first in
  let bytes = Fs_compat.load_file path in
  require_unavailable (create stale "not-appended");
  Alcotest.(check string) "stale append preserves both policies" bytes (Fs_compat.load_file path);
  ignore (reload stale);
  ignore (require (Board.update_sub_board first ~sub_board_id:"existing" ~name:"newer policy" ()));
  let bytes = Fs_compat.load_file path in
  require_unavailable (Board.delete_sub_board stale ~sub_board_id:"existing");
  Alcotest.(check string) "stale deletion preserves the newer policy" bytes (Fs_compat.load_file path);
  ignore (reload stale);
  require (Board.delete_sub_board stale ~sub_board_id:"existing");
  let restarted = new_store base_path in
  Alcotest.(check int) "only the explicitly deleted policy is removed" 1
    (List.length (require (Board.read_sub_boards restarted)));
  Alcotest.(check string) "foreign policy remains durable" "foreign" (get restarted "foreign").slug

let () =
  Alcotest.run "board_sub_boards_source"
    ["actual writers and restart",
      [Alcotest.test_case "stale update retains foreign policy" `Quick
         (with_fixture test_stale_update_preserves_foreign_policy);
       Alcotest.test_case "stale append and deletion retain foreign policy" `Quick
         (with_fixture test_stale_append_and_delete_preserve_foreign_policy)]]
