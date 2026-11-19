(* Where the stores beside the Agent-Core history end
   (RFC librarian-call-only-proposes §5.1). The files are written here as
   plain rows: the ends depend on line breaks alone, not on what a row says. *)

open Alcotest
module Ends = Masc.Keeper_turn_log_ends

let keeper_name = "ends-keeper"

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK -> Unix.unlink path
;;

let in_workspace test () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_file "test_turn_log_ends_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  let session_dir = Filename.concat base_path "session" in
  Unix.mkdir session_dir 0o755;
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> test ~base_path ~session_dir)
;;

let write path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)
;;

let history ~session_dir = Masc.Keeper_turn_fragments.path ~session_dir Main
let internal ~session_dir = Masc.Keeper_turn_fragments.path ~session_dir Internal
let chat ~base_path = Masc.Keeper_chat_store.chat_path ~base_dir:base_path ~keeper_name
let external_ ~base_path = Masc.Keeper_external_attention.attention_path ~base_path ~keeper_name

let ends_text ~base_path ~session_dir =
  match Ends.read ~session_dir ~base_path ~keeper_name with
  | Ok { history_bytes; internal_bytes; chat_bytes; external_rows } ->
    Printf.sprintf "history %d, internal %d, chat %d, external %d" history_bytes internal_bytes
      chat_bytes external_rows
  | Error { store; _ } -> "unread: " ^ Ends.store_to_string store
;;

let test_nothing_written =
  in_workspace
  @@ fun ~base_path ~session_dir ->
  check string "stores that are not there end at 0" "history 0, internal 0, chat 0, external 0"
    (ends_text ~base_path ~session_dir)
;;

let test_each_store_has_its_own_end =
  in_workspace
  @@ fun ~base_path ~session_dir ->
  write (history ~session_dir) "{\"a\":1}\n{\"a\":2}\n";
  write (internal ~session_dir) "{\"b\":1}\n";
  write (chat ~base_path) "{\"c\":1}\n{\"c\":2}\n{\"c\":3}\n";
  write (external_ ~base_path) "{\"d\":1}\n{\"d\":2}\n{\"d\":3}\n{\"d\":4}\n";
  check string "bytes of the three files, rows of the external one"
    "history 16, internal 8, chat 24, external 4"
    (ends_text ~base_path ~session_dir)
;;

(* A row caught half written is past the end. When the rest of it arrives the
   end moves over the whole row. *)
let test_half_written_row =
  in_workspace
  @@ fun ~base_path ~session_dir ->
  write (history ~session_dir) "{\"a\":1}\n{\"a\":";
  write (internal ~session_dir) "{\"b\":";
  write (chat ~base_path) "{\"c\":1}\n{\"c\":2}\n{\"c\"";
  write (external_ ~base_path) "{\"d\":1}\n{\"d\":2}\n{\"d\"";
  check string "each end stops after the last line break" "history 8, internal 0, chat 16, external 2"
    (ends_text ~base_path ~session_dir);
  write (history ~session_dir) "{\"a\":1}\n{\"a\":2}\n";
  write (external_ ~base_path) "{\"d\":1}\n{\"d\":2}\n{\"d\":3}\n";
  check string "the finished row is counted whole" "history 16, internal 0, chat 16, external 3"
    (ends_text ~base_path ~session_dir)
;;

(* A store that is there and is not a file is not an empty store. *)
let test_unreadable_store =
  in_workspace
  @@ fun ~base_path ~session_dir ->
  write (history ~session_dir) "{\"a\":1}\n";
  Fs_compat.mkdir_p (chat ~base_path);
  check string "the chat store is named" "unread: chat" (ends_text ~base_path ~session_dir);
  Unix.rmdir (chat ~base_path);
  Fs_compat.mkdir_p (external_ ~base_path);
  check string "the external store is named" "unread: external attention"
    (ends_text ~base_path ~session_dir)
;;

let () =
  run "keeper_turn_log_ends"
    [ ( "ends"
      , [ test_case "nothing written" `Quick test_nothing_written
        ; test_case "each store has its own end" `Quick test_each_store_has_its_own_end
        ; test_case "a half written row" `Quick test_half_written_row
        ; test_case "a store that cannot be read" `Quick test_unreadable_store
        ] )
    ]
;;
