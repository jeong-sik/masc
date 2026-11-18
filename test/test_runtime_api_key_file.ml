(* The key file of a key account, on real files (RFC
   a-persons-api-key-is-their-own-provider-account 3.2 and 5, "file"). A file
   of another user needs another user, so the owner half of the check is not
   here: the same comparison refuses the permissions, which are. *)

open Authz_types
module K = Runtime_api_key_file
module Layout = Runtime_account_home_layout

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "a fixture value was refused"
;;

let account = get (Provider_account_id.of_string "account-1")
let namespace = get (Account_home_namespace.of_string "namespace-1")
let generation = Key_generation.first

let key text =
  match K.key_of_string text with
  | Some key -> key
  | None -> Alcotest.fail "a fixture key was refused"
;;

let first_key = "sk-test-first"
let second_key = "sk-test-second"

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* A base path with the runtime root of one person made, as a login makes it. *)
let with_root work () =
  Eio_main.run (fun _env ->
    let base_path = Unix.realpath (Filename.temp_dir "api-key-file-" "") in
    Fun.protect
      ~finally:(fun () -> remove_tree base_path)
      (fun () ->
        let runtime_root = Layout.person_runtime_root ~base_path ~namespace in
        let rec make path =
          if not (Sys.file_exists path)
          then (
            make (Filename.dirname path);
            Unix.mkdir path 0o700)
        in
        make runtime_root;
        work ~base_path ~runtime_root))
;;

let file_of ~runtime_root =
  match Layout.key_file ~runtime_root ~account_id:account ~generation with
  | Ok file -> file
  | Error detail -> Alcotest.failf "the layout spelled no key file: %s" detail
;;

let mode path = (Unix.lstat path).Unix.st_perm

let write_error_name = function
  | K.Root_unavailable _ -> "root_unavailable"
  | K.Folder_not_private _ -> "folder_not_private"
  | K.Generation_taken -> "generation_taken"
  | K.Not_written _ -> "not_written"
;;

let written ~runtime_root text =
  match K.write ~runtime_root ~account_id:account ~generation (key text) with
  | Ok () -> ()
  | Error error -> Alcotest.failf "the key was not written: %s" (write_error_name error)
;;

let not_written label ~runtime_root text expected =
  match K.write ~runtime_root ~account_id:account ~generation (key text) with
  | Ok () -> Alcotest.failf "%s: written" label
  | Error error -> Alcotest.(check string) label expected (write_error_name error)
;;

(* What a read gave, with the key as its characters: the keys of this file are
   made up. *)
let read_name = function
  | Ok key -> "key:" ^ K.value key
  | Error K.Key_missing -> "key_missing"
  | Error (K.Key_unreadable K.Path_not_absolute) -> "key_unreadable:path_not_absolute"
  | Error (K.Key_unreadable K.Not_a_regular_file) -> "key_unreadable:not_a_regular_file"
  | Error (K.Key_unreadable K.Open_to_others) -> "key_unreadable:open_to_others"
  | Error (K.Key_unreadable K.Not_a_key) -> "key_unreadable:not_a_key"
;;

let reads label path expected = Alcotest.(check string) label expected (read_name (K.read path))

let test_written =
  with_root (fun ~base_path ~runtime_root ->
    let file = file_of ~runtime_root in
    reads "before the write" file "key_missing";
    written ~runtime_root ("  " ^ first_key ^ "\n");
    let dir = Filename.dirname file in
    Alcotest.(check string)
      "the file is under the runtime root of the person, by the layout"
      (List.fold_left
         Filename.concat
         runtime_root
         [ Layout.api_keys_dir; Provider_account_id.to_string account; "1" ])
      file;
    Alcotest.(check bool)
      "which is under the persons of the base path"
      true
      (Layout.under_persons ~base_path file);
    Alcotest.(check int) "the file is 0600" 0o600 (mode file);
    Alcotest.(check int) "the folder of the account is 0700" 0o700 (mode dir);
    Alcotest.(check int) "the folder of the keys is 0700" 0o700 (mode (Filename.dirname dir));
    Alcotest.(check (list string))
      "the folder holds the key file and nothing else"
      [ "1" ]
      (Array.to_list (Sys.readdir dir));
    reads "the key reads back without the blanks around it" file ("key:" ^ first_key))
;;

let test_once =
  with_root (fun ~base_path:_ ~runtime_root ->
    let file = file_of ~runtime_root in
    written ~runtime_root first_key;
    not_written "a second write of the generation" ~runtime_root second_key "generation_taken";
    reads "the first key is the one in place" file ("key:" ^ first_key);
    Alcotest.(check (list string))
      "the refused write left no file"
      [ "1" ]
      (Array.to_list (Sys.readdir (Filename.dirname file))))
;;

(* A process that died while it wrote leaves the file it had not put in place.
   The generation is taken: no write of it follows, and no key is read. *)
let test_unplaced =
  with_root (fun ~base_path:_ ~runtime_root ->
    let file = file_of ~runtime_root in
    let dir = Filename.dirname file in
    Unix.mkdir (Filename.dirname dir) 0o700;
    Unix.mkdir dir 0o700;
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_excl ]
      0o600
      (file ^ ".tmp")
      (fun channel -> Out_channel.output_string channel "sk-te");
    not_written "a write after an unfinished one" ~runtime_root first_key "generation_taken";
    reads "the unfinished file is not the key" file "key_missing")
;;

let test_not_read =
  with_root (fun ~base_path:_ ~runtime_root ->
    let file = file_of ~runtime_root in
    written ~runtime_root first_key;
    Unix.chmod file 0o640;
    reads "a file its group reads" file "key_unreadable:open_to_others";
    Unix.chmod file 0o604;
    reads "a file others read" file "key_unreadable:open_to_others";
    Unix.chmod file 0o600;
    reads "the file closed again" file ("key:" ^ first_key);
    (* A link to a private file of this user is no key file. *)
    let target = Filename.concat runtime_root "elsewhere" in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 target (fun channel ->
      Out_channel.output_string channel second_key);
    Sys.remove file;
    Unix.symlink target file;
    reads "a link" file "key_unreadable:not_a_regular_file";
    Sys.remove file;
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 file (fun channel ->
      Out_channel.output_string channel {|{"api_key":"sk-test-first"}|});
    reads "a credential document" file "key_unreadable:not_a_key";
    reads "a relative path" "api-keys/account-1/1" "key_unreadable:path_not_absolute")
;;

let test_open_folder =
  with_root (fun ~base_path:_ ~runtime_root ->
    let file = file_of ~runtime_root in
    let keys = Filename.dirname (Filename.dirname file) in
    Unix.mkdir keys 0o750;
    not_written "under a folder its group reads" ~runtime_root first_key "folder_not_private";
    reads "no key was put there" file "key_missing";
    Alcotest.(check bool)
      "and no folder of the account was made"
      false
      (Sys.file_exists (Filename.dirname file)))
;;

let test_no_root () =
  Eio_main.run (fun _env ->
    not_written
      "under a runtime root that is not there"
      ~runtime_root:"/nonexistent-api-key-file-root"
      first_key
      "root_unavailable")
;;

let test_key_of_string () =
  let refused label text =
    Alcotest.(check bool) label true (Option.is_none (K.key_of_string text))
  in
  refused "nothing" "";
  refused "blanks" " \n\t ";
  refused "a control character inside" "sk-\ttest";
  refused "a JSON object" {|{"api_key":"sk-test"}|};
  refused "a JSON array" {|["sk-test"]|};
  Alcotest.(check string) "a key, without the blanks around it" "sk-test" (K.value (key " sk-test\n"));
  Alcotest.(check string) "a number is one value" "12345" (K.value (key "12345"))
;;

let () =
  Alcotest.run
    "runtime_api_key_file"
    [ ( "write"
      , [ Alcotest.test_case "0600 under the person, in 0700 folders" `Quick test_written
        ; Alcotest.test_case "a generation is written once" `Quick test_once
        ; Alcotest.test_case "an unfinished write takes the generation" `Quick test_unplaced
        ; Alcotest.test_case "not under a folder open to others" `Quick test_open_folder
        ; Alcotest.test_case "not without the runtime root" `Quick test_no_root
        ] )
    ; ( "read"
      , [ Alcotest.test_case "only a private regular file that holds a key" `Quick test_not_read
        ; Alcotest.test_case "what a key is" `Quick test_key_of_string
        ] )
    ]
;;
