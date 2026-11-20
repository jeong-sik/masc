(* The files of a key account, on real files (RFC
   a-persons-api-key-is-their-own-provider-account 3.3, 3.6 and 5, "removal"):
   where a registration puts them, and what a removal takes and in which
   order. *)

open Authz_types
module F = Runtime_key_account_files
module K = Runtime_api_key_file
module Layout = Runtime_account_home_layout

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "a fixture value was refused"
;;

let get_text = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "a fixture path was not spelled: %s" detail
;;

let account = get (Provider_account_id.of_string "account-1")
let other_account = get (Provider_account_id.of_string "account-2")
let namespace = get (Account_home_namespace.of_string "namespace-1")
let generation = Key_generation.first

let key text =
  match K.key_of_string text with
  | Some key -> key
  | None -> Alcotest.fail "a fixture key was refused"
;;

let the_key = "sk-test-the-key"

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

(* A base path with the runtime root of one person made, as a login makes it.
   The umask is 0 while a case runs, so a mode a case reads is the mode that
   was asked for. *)
let with_root work () =
  Eio_main.run (fun _env ->
    let base_path = Unix.realpath (Filename.temp_dir "key-account-files-" "") in
    let umask = Unix.umask 0 in
    Fun.protect
      ~finally:(fun () ->
        ignore (Unix.umask umask : int);
        (* A tree that was not removed is said, and does not take the place
           of the failure of the case. *)
        try remove_tree base_path with
        | Unix.Unix_error (error, call, path) ->
          Printf.eprintf "the tree of the case stays: %s %s: %s\n" call path (Unix.error_message error)
        | Sys_error detail -> Printf.eprintf "the tree of the case stays: %s\n" detail)
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

let home_of ~runtime_root id =
  get_text (Layout.home ~runtime_root Layout.Claude_home ~account_id:(Provider_account_id.to_string id))
;;

let keys_of ~runtime_root id = get_text (Layout.key_dir ~runtime_root ~account_id:id)
let key_file_of ~runtime_root id = get_text (Layout.key_file ~runtime_root ~account_id:id ~generation)
let there path = Sys.file_exists path
let mode path = (Unix.lstat path).Unix.st_perm

let make_name = function
  | Ok () -> "made"
  | Error (F.Home_not_made _) -> "home_not_made"
  | Error (F.Key_not_written K.Generation_taken) -> "key_not_written:generation_taken"
  | Error (F.Key_not_written (K.Root_unavailable _)) -> "key_not_written:root_unavailable"
  | Error (F.Key_not_written (K.Folder_not_private _)) -> "key_not_written:folder_not_private"
  | Error (F.Key_not_written (K.Not_written _)) -> "key_not_written:not_written"
;;

let remove_name = function
  | Ok () -> "removed"
  | Error (F.Key_not_removed _) -> "key_not_removed"
  | Error (F.Home_not_removed _) -> "home_not_removed"
;;

let made label ~runtime_root id text expected =
  Alcotest.(check string)
    label
    expected
    (make_name (F.make ~runtime_root ~account_id:id ~generation (key text)))
;;

let removed label ~runtime_root id expected =
  Alcotest.(check string) label expected (remove_name (F.remove ~runtime_root ~account_id:id))
;;

let present label ~runtime_root id expected =
  match F.present ~runtime_root ~account_id:id with
  | Ok there -> Alcotest.(check bool) label expected there
  | Error detail -> Alcotest.failf "%s: not looked at: %s" label detail
;;

(* What a list says of the key of the account. *)
let key_state_name ~runtime_root id =
  match F.key_state ~runtime_root ~account_id:id ~generation with
  | F.Key_readable -> "readable"
  | F.Key_not_read error -> K.read_error_code error
  | F.Key_not_looked_at (_ : string) -> "not_looked_at"
;;

let key_state label ~runtime_root id expected =
  Alcotest.(check string) label expected (key_state_name ~runtime_root id)
;;

(* What a read of the key file gave, with the key as its characters: the keys
   of this file are made up. *)
let read_name path =
  match K.read path with
  | Ok key -> "key:" ^ K.value key
  | Error error -> K.read_error_code error
;;

let test_made =
  with_root (fun ~base_path ~runtime_root ->
    made "the files of an account" ~runtime_root account the_key "made";
    let home = home_of ~runtime_root account in
    Alcotest.(check bool) "the home the layout spells is there" true (there home);
    Alcotest.(check int) "the home is 0700" 0o700 (mode home);
    Alcotest.(check bool) "it is under the persons of the base path" true (Layout.under_persons ~base_path home);
    Alcotest.(check string)
      "the key reads back from the file of its generation"
      ("key:" ^ the_key)
      (read_name (key_file_of ~runtime_root account));
    (* A second making of an account that has its files: the place of its
       key is taken. The call wrote no key and changed nothing that was
       there, so nothing is to be removed after it. *)
    made "the same account again" ~runtime_root account "sk-test-another" "key_not_written:generation_taken";
    let key_file = key_file_of ~runtime_root account in
    Alcotest.(check string) "the first key is the one in place" ("key:" ^ the_key) (read_name key_file);
    Alcotest.(check (list string))
      "the folder of the key holds the file of the generation and nothing the refused call left"
      [ Filename.basename key_file ]
      (Array.to_list (Sys.readdir (Filename.dirname key_file)));
    Alcotest.(check int) "the home is as it was" 0o700 (mode home);
    key_state "a list reads the key of the account" ~runtime_root account "readable")
;;

let test_no_root () =
  Eio_main.run (fun _env ->
    made
      "under a runtime root that is not there"
      ~runtime_root:"/nonexistent-key-account-files-root"
      account
      the_key
      "home_not_made")
;;

(* A home whose place another user reaches is no home of an account, and no
   key is written beside it. *)
let test_open_home =
  with_root (fun ~base_path:_ ~runtime_root ->
    Unix.mkdir (Filename.concat runtime_root Layout.clients_dir) 0o750;
    made "under a folder of homes its group reads" ~runtime_root account the_key "home_not_made";
    Alcotest.(check bool) "no key folder was made" false (there (keys_of ~runtime_root account)))
;;

let test_removed =
  with_root (fun ~base_path:_ ~runtime_root ->
    present "an account before its files" ~runtime_root account false;
    made "the account" ~runtime_root account the_key "made";
    made "another account of the person" ~runtime_root other_account "sk-test-the-other-key" "made";
    present "an account with its files" ~runtime_root account true;
    let home = home_of ~runtime_root account in
    let keys = keys_of ~runtime_root account in
    (* What a client and a write that stopped leave in the two folders. *)
    Out_channel.with_open_bin (Filename.concat home "history.jsonl") (fun channel ->
      Out_channel.output_string channel "{}\n");
    Unix.mkdir (Filename.concat home "projects") 0o700;
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 (Filename.concat keys "2.tmp")
      (fun channel -> Out_channel.output_string channel "sk-te");
    removed "the account" ~runtime_root account "removed";
    Alcotest.(check bool) "the folder of its keys is gone" false (there keys);
    Alcotest.(check bool) "its home is gone" false (there home);
    present "the account after its removal" ~runtime_root account false;
    present "the other account" ~runtime_root other_account true;
    (* What a restore of a backup brings back, one folder at a time. *)
    Unix.mkdir home 0o700;
    present "an account whose home came back" ~runtime_root account true;
    Unix.rmdir home;
    Unix.mkdir keys 0o700;
    present "an account whose key folder came back" ~runtime_root account true;
    removed "the account whose key folder came back" ~runtime_root account "removed";
    Alcotest.(check string)
      "the key of the other account is in place"
      "key:sk-test-the-other-key"
      (read_name (key_file_of ~runtime_root other_account));
    Alcotest.(check bool) "the home of the other account is there" true (there (home_of ~runtime_root other_account));
    removed "the same account again" ~runtime_root account "removed")
;;

(* What a list says of the key of an account, without making anything. *)
let test_key_state =
  with_root (fun ~base_path:_ ~runtime_root ->
    key_state "an account before its files" ~runtime_root account "key_missing";
    made "the account" ~runtime_root account the_key "made";
    key_state "an account with its files" ~runtime_root account "readable";
    key_state "another account of the person" ~runtime_root other_account "key_missing";
    let file = key_file_of ~runtime_root account in
    Unix.chmod file 0o640;
    key_state "a key file its group reads" ~runtime_root account "key_unreadable";
    Unix.chmod file 0o600;
    key_state "the file closed again" ~runtime_root account "readable";
    (* A person no login and no registration made a runtime root for: the
       reading finds no file, and makes no folder. *)
    let no_root = Filename.concat (Filename.dirname runtime_root) "namespace-of-nobody" in
    key_state "under a runtime root that is not there" ~runtime_root:no_root account "key_missing";
    Alcotest.(check bool) "the reading made no runtime root" false (there no_root))
;;

(* ---- the replacement of a key (the same RFC, 3.7) ---- *)

let second = Key_generation.next generation
let third = Key_generation.next second

let key_file_at ~runtime_root id generation =
  get_text (Layout.key_file ~runtime_root ~account_id:id ~generation)
;;

let put path text =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 path (fun channel ->
    Out_channel.output_string channel text)
;;

let names_of folder = List.sort String.compare (Array.to_list (Sys.readdir folder))

let replaced label ~runtime_root id generation text expected =
  Alcotest.(check string)
    label
    expected
    (match F.replace ~runtime_root ~account_id:id ~generation (key text) with
     | Ok F.Other_keys_removed -> "replaced"
     | Ok (F.Other_keys_left (_ : string)) -> "replaced, other keys left"
     | Error error -> make_name (Error error))
;;

let other_keys label ~runtime_root id generation expected =
  Alcotest.(check string)
    label
    expected
    (match F.remove_other_keys ~runtime_root ~account_id:id ~generation with
     | Ok { F.gone; stayed = None } -> Printf.sprintf "removed %d" gone
     | Ok { F.gone; stayed = Some (_ : string) } -> Printf.sprintf "removed %d, one stays" gone
     | Error (_ : string) -> "not looked at")
;;

(* The new key is in the file of the generation named, and the folder of the
   keys then holds that file alone. *)
let test_replaced =
  with_root (fun ~base_path:_ ~runtime_root ->
    made "the account" ~runtime_root account the_key "made";
    made "another account of the person" ~runtime_root other_account "sk-test-the-other-key" "made";
    let keys = keys_of ~runtime_root account in
    let home = home_of ~runtime_root account in
    put (Filename.concat home "history.jsonl") "{}\n";
    (* What a write that stopped, a restore and a hand leave in the folder. *)
    put (Filename.concat keys "7.tmp") "sk-te";
    Unix.mkdir (Filename.concat keys "older") 0o700;
    put (Filename.concat (Filename.concat keys "older") "1") "sk-test-an-older-key";
    Unix.symlink (key_file_of ~runtime_root other_account) (Filename.concat keys "link");
    replaced "the key of the account" ~runtime_root account second "sk-test-the-second-key" "replaced";
    let in_place = key_file_at ~runtime_root account second in
    Alcotest.(check (list string))
      "the folder of the keys holds the file of the new generation alone"
      [ Filename.basename in_place ]
      (names_of keys);
    Alcotest.(check string) "the new key reads back" "key:sk-test-the-second-key" (read_name in_place);
    Alcotest.(check string)
      "what the link in the folder led to is in place"
      "key:sk-test-the-other-key"
      (read_name (key_file_of ~runtime_root other_account));
    Alcotest.(check bool) "the home keeps what was in it" true (there (Filename.concat home "history.jsonl"));
    (* A generation is written once: the call puts nothing in place and
       removes nothing. *)
    put (Filename.concat keys "7.tmp") "sk-te";
    replaced
      "the same generation again"
      ~runtime_root
      account
      second
      "sk-test-a-third-key"
      "key_not_written:generation_taken";
    Alcotest.(check string) "the key in place is the one that was there" "key:sk-test-the-second-key" (read_name in_place);
    Alcotest.(check bool) "nothing was removed after the refusal" true (there (Filename.concat keys "7.tmp")))
;;

(* An account whose record was written and whose files were not: the
   replacement makes its home and puts its key in place. *)
let test_replaced_with_no_files =
  with_root (fun ~base_path:_ ~runtime_root ->
    replaced "an account with no files" ~runtime_root account second "sk-test-the-second-key" "replaced";
    Alcotest.(check int) "its home is there, 0700" 0o700 (mode (home_of ~runtime_root account));
    Alcotest.(check string)
      "its key reads back"
      "key:sk-test-the-second-key"
      (read_name (key_file_at ~runtime_root account second)))
;;

(* What a replacement whose key was not stored asks: the folder of the keys
   goes with everything in it, the home stays, and the next write makes the
   folder again. *)
let test_keys_alone =
  with_root (fun ~base_path:_ ~runtime_root ->
    made "the account" ~runtime_root account the_key "made";
    let keys = keys_of ~runtime_root account in
    let home = home_of ~runtime_root account in
    put (Filename.concat home "history.jsonl") "{}\n";
    put (key_file_at ~runtime_root account second) "sk-test-a-key-no-record-names";
    (match F.remove_keys ~runtime_root ~account_id:account with
     | Ok () -> ()
     | Error detail -> Alcotest.failf "the folder of the keys stays: %s" detail);
    Alcotest.(check bool) "the folder of the keys is gone" false (there keys);
    Alcotest.(check bool) "the home keeps what was in it" true (there (Filename.concat home "history.jsonl"));
    key_state "a list reads no key" ~runtime_root account "key_missing";
    replaced "the next key" ~runtime_root account second "sk-test-the-second-key" "replaced";
    Alcotest.(check string)
      "it reads back"
      "key:sk-test-the-second-key"
      (read_name (key_file_at ~runtime_root account second));
    let no_root = Filename.concat (Filename.dirname runtime_root) "namespace-of-nobody" in
    (match F.remove_keys ~runtime_root:no_root ~account_id:account with
     | Ok () -> ()
     | Error detail -> Alcotest.failf "under a runtime root that is not there: %s" detail);
    Alcotest.(check bool) "no runtime root was made" false (there no_root))
;;

(* What the start of the server asks of a key account: the files of the
   generations its record does not name go. *)
let test_other_keys =
  with_root (fun ~base_path:_ ~runtime_root ->
    other_keys "an account with no files" ~runtime_root account generation "removed 0";
    Alcotest.(check bool) "it made no folder" false (there (keys_of ~runtime_root account));
    made "the account" ~runtime_root account the_key "made";
    (* A replacement that put its key in place and went no further. *)
    (match K.write ~runtime_root ~account_id:account ~generation:second (key "sk-test-the-second-key") with
     | Ok () -> ()
     | Error (_ : K.write_error) -> Alcotest.fail "the key of the second generation was not written");
    let keys = keys_of ~runtime_root account in
    let in_place = key_file_at ~runtime_root account second in
    other_keys "the files of the other generations" ~runtime_root account second "removed 1";
    Alcotest.(check (list string)) "the file of the generation named is left alone" [ Filename.basename in_place ] (names_of keys);
    Alcotest.(check string) "and its key reads back" "key:sk-test-the-second-key" (read_name in_place);
    other_keys "the same again" ~runtime_root account second "removed 0";
    Alcotest.(check (list string)) "nothing more went" [ Filename.basename in_place ] (names_of keys);
    (* A record that names a generation whose file was never put in place:
       no file of the folder is the key of the account. *)
    other_keys "for a generation with no file" ~runtime_root account third "removed 1";
    Alcotest.(check (list string)) "the folder is empty" [] (names_of keys);
    let no_root = Filename.concat (Filename.dirname runtime_root) "namespace-of-nobody" in
    other_keys "under a runtime root that is not there" ~runtime_root:no_root account generation "removed 0";
    Alcotest.(check bool) "it made no runtime root" false (there no_root))
;;

(* A link in the place of the folder of the keys is not read: what it leads
   to is the folder of another account. *)
let test_other_keys_link =
  with_root (fun ~base_path:_ ~runtime_root ->
    made "the other account" ~runtime_root other_account "sk-test-the-other-key" "made";
    let link = keys_of ~runtime_root account in
    Unix.symlink (keys_of ~runtime_root other_account) link;
    other_keys "an account whose key folder is a link" ~runtime_root account second "not looked at";
    Alcotest.(check string)
      "what the link led to is in place"
      "key:sk-test-the-other-key"
      (read_name (key_file_of ~runtime_root other_account));
    (* A replacement writes no key through the link either. *)
    replaced
      "a replacement of that account"
      ~runtime_root
      account
      second
      "sk-test-the-second-key"
      "key_not_written:folder_not_private";
    Alcotest.(check (list string))
      "the folder the link led to holds its own key alone"
      [ Filename.basename (key_file_of ~runtime_root other_account) ]
      (names_of (keys_of ~runtime_root other_account));
    (match (Unix.lstat link).Unix.st_kind with
     | Unix.S_LNK -> ()
     | Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
       Alcotest.fail "the link was replaced"))
;;

(* An account whose record was written and whose files were not, as a process
   that died between the two leaves it: a removal finds nothing and ends. *)
let test_nothing_made =
  with_root (fun ~base_path:_ ~runtime_root ->
    removed "an account with no files" ~runtime_root account "removed";
    (* A person no login and no registration made a runtime root for. *)
    let no_root = Filename.concat (Filename.dirname runtime_root) "namespace-of-nobody" in
    removed "an account under a runtime root that is not there" ~runtime_root:no_root account "removed";
    present "and nothing of it is there" ~runtime_root:no_root account false;
    Alcotest.(check bool) "the removal made no runtime root" false (there no_root))
;;

(* A link in the place of the folder of the keys is removed and not followed. *)
let test_link =
  with_root (fun ~base_path:_ ~runtime_root ->
    made "the other account" ~runtime_root other_account "sk-test-the-other-key" "made";
    Unix.symlink (keys_of ~runtime_root other_account) (keys_of ~runtime_root account);
    removed "an account whose key folder is a link" ~runtime_root account "removed";
    (match Unix.lstat (keys_of ~runtime_root account) with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
     | (_ : Unix.stats) -> Alcotest.fail "the link is still there");
    Alcotest.(check string)
      "what the link led to is in place"
      "key:sk-test-the-other-key"
      (read_name (key_file_of ~runtime_root other_account)))
;;

(* How often the case of the FIFO looks whether the removal waits on it. *)
let fifo_watch_s = 0.005

(* A file where the folder of the keys would be holds no key of any account.
   The removal ends there, as the reading of what is present does: were it to
   fail, no later removal would end either. *)
let test_not_a_folder =
  with_root (fun ~base_path:_ ~runtime_root ->
    let keys = Filename.dirname (keys_of ~runtime_root account) in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 keys (fun (_ : out_channel) -> ());
    removed "an account under a file in place of the folder of the keys" ~runtime_root account "removed";
    Alcotest.(check bool) "the file is left" true (Sys.file_exists keys))
;;

(* A FIFO where the folder of the keys would be holds no key either, and the
   removal does not open it. An open of a FIFO for reading waits until
   something opens it for writing, and an open for writing that does not
   wait succeeds only while one waits to read: so the watcher learns whether
   the removal opened the FIFO, and lets it go on if it did. *)
let test_a_fifo =
  with_root (fun ~base_path:_ ~runtime_root ->
    let keys = Filename.dirname (keys_of ~runtime_root account) in
    Unix.mkfifo keys 0o600;
    let opened = ref false in
    let ended = ref false in
    let rec watch () =
      if not !ended
      then (
        (match Unix.openfile keys [ Unix.O_WRONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
         | fd ->
           opened := true;
           Unix.close fd
         | exception Unix.Unix_error (Unix.ENXIO, _, _) -> ());
        Eio_unix.sleep fifo_watch_s;
        watch ())
    in
    Eio.Fiber.both
      (fun () ->
        Fun.protect
          ~finally:(fun () -> ended := true)
          (fun () -> removed "an account under a FIFO in place of the folder of the keys" ~runtime_root account "removed"))
      watch;
    Alcotest.(check bool) "the removal did not open the FIFO" false !opened)
;;

(* The modes that keep a folder from being removed do not keep the superuser
   from it, so the cases that rest on them are skipped when the superuser
   runs them. *)
let unless_superuser work ~base_path ~runtime_root =
  if Unix.geteuid () <> 0 then work ~base_path ~runtime_root else Alcotest.skip ()
;;

(* The key goes first. When it does not go, the stage says so, and the home
   was not touched. *)
let test_key_stays =
  with_root
    (unless_superuser (fun ~base_path:_ ~runtime_root ->
       made "the account" ~runtime_root account the_key "made";
       let keys = keys_of ~runtime_root account in
       let home = home_of ~runtime_root account in
       Unix.chmod keys 0o500;
       removed "an account whose key folder is not written" ~runtime_root account "key_not_removed";
       Alcotest.(check string)
         "the key is still in place"
         ("key:" ^ the_key)
         (read_name (key_file_of ~runtime_root account));
       Alcotest.(check bool) "the home was not touched" true (there home);
       Unix.chmod keys 0o700;
       removed "the same account, its folder written again" ~runtime_root account "removed";
       Alcotest.(check bool) "the folder of its keys is gone" false (there keys);
       Alcotest.(check bool) "its home is gone" false (there home)))
;;

(* The key is gone and the home is not: the stage says the home. *)
let test_home_stays =
  with_root
    (unless_superuser (fun ~base_path:_ ~runtime_root ->
       made "the account" ~runtime_root account the_key "made";
       let keys = keys_of ~runtime_root account in
       let home = home_of ~runtime_root account in
       let homes = Filename.dirname home in
       Unix.chmod homes 0o500;
       removed "an account whose home cannot be taken out of its folder" ~runtime_root account "home_not_removed";
       Alcotest.(check bool) "the folder of its keys is gone" false (there keys);
       Alcotest.(check bool) "its home is still there" true (there home);
       Unix.chmod homes 0o700;
       removed "the same account, the folder written again" ~runtime_root account "removed";
       Alcotest.(check bool) "its home is gone" false (there home)))
;;

(* The new key is in place whatever becomes of the others, and each of the
   others is tried: the one that does not go sorts before the key of the
   generation before, which goes. *)
let test_other_keys_stay =
  with_root
    (unless_superuser (fun ~base_path:_ ~runtime_root ->
       made "the account" ~runtime_root account the_key "made";
       let keys = keys_of ~runtime_root account in
       let stuck = Filename.concat keys "0-stuck" in
       Unix.mkdir stuck 0o700;
       put (Filename.concat stuck "1") "sk-test-an-older-key";
       Unix.chmod stuck 0o500;
       replaced
         "an account one of whose other files does not go"
         ~runtime_root
         account
         second
         "sk-test-the-second-key"
         "replaced, other keys left";
       let in_place = key_file_at ~runtime_root account second in
       Alcotest.(check string) "the new key is in place" "key:sk-test-the-second-key" (read_name in_place);
       Alcotest.(check (list string))
         "the key of the generation before went, after the one that did not"
         [ Filename.basename stuck; Filename.basename in_place ]
         (names_of keys);
       (* What went and what stays are said of the same look. *)
       put (Filename.concat keys "9-left") "sk-test-a-key-a-write-left";
       other_keys "asked while one of them does not go" ~runtime_root account second "removed 1, one stays";
       Alcotest.(check (list string))
         "the one that goes went"
         [ Filename.basename stuck; Filename.basename in_place ]
         (names_of keys);
       Unix.chmod stuck 0o700;
       other_keys "asked again, the folder written again" ~runtime_root account second "removed 1";
       Alcotest.(check (list string)) "the new key alone is left" [ Filename.basename in_place ] (names_of keys)))
;;

(* HTTP provider key accounts (stage 2, RFC 3.9) have no CLI account home. *)
let test_no_home =
  with_root (fun ~base_path:_ ~runtime_root ->
    Alcotest.(check (result bool string))
      "present is false before any HTTP key file"
      (Ok false)
      (F.present_for ~home:F.No_home ~runtime_root ~account_id:account);
    Alcotest.(check string)
      "HTTP key files make no CLI home"
      "made"
      (make_name (F.make_for ~home:F.No_home ~runtime_root ~account_id:account ~generation (key the_key)));
    let home = home_of ~runtime_root account in
    let keys = keys_of ~runtime_root account in
    Alcotest.(check bool) "no Claude Code home was created" false (there home);
    Alcotest.(check bool) "no clients directory was created" false (there (Filename.concat runtime_root "clients"));
    Alcotest.(check bool) "the key folder was created" true (there keys);
    Alcotest.(check string) "the HTTP key reads back" ("key:" ^ the_key) (read_name (key_file_of ~runtime_root account));
    Alcotest.(check (result bool string))
      "present sees the HTTP key folder"
      (Ok true)
      (F.present_for ~home:F.No_home ~runtime_root ~account_id:account);
    Alcotest.(check string)
      "HTTP key rotation keeps no CLI home"
      "replaced"
      (match F.replace_for ~home:F.No_home ~runtime_root ~account_id:account ~generation:second (key "sk-test-http-2") with
       | Ok F.Other_keys_removed -> "replaced"
       | Ok (F.Other_keys_left (_ : string)) -> "replaced, other keys left"
       | Error error -> make_name (Error error));
    Alcotest.(check bool) "rotation still makes no Claude Code home" false (there home);
    Alcotest.(check (list string))
      "only the rotated key file remains"
      [ Filename.basename (key_file_at ~runtime_root account second) ]
      (names_of keys);
    Alcotest.(check string)
      "HTTP key removal removes the keys cleanly"
      "removed"
      (remove_name (F.remove_for ~home:F.No_home ~runtime_root ~account_id:account));
    Alcotest.(check bool) "the HTTP key folder is gone" false (there keys);
    Alcotest.(check (result bool string))
      "present is false after removal"
      (Ok false)
      (F.present_for ~home:F.No_home ~runtime_root ~account_id:account);
    let missing_root = Filename.concat (Filename.dirname runtime_root) "missing-root" in
    Alcotest.(check string)
      "No_home make_home refuses a missing runtime root"
      "home_not_made"
      (make_name (F.make_for ~home:F.No_home ~runtime_root:missing_root ~account_id:account ~generation (key the_key))))
;;

let () =
  Alcotest.run
    "runtime_key_account_files"
    [ ( "make"
      , [ Alcotest.test_case "the home and then the key" `Quick test_made
        ; Alcotest.test_case "HTTP provider keys take No_home" `Quick test_no_home
        ; Alcotest.test_case "not without the runtime root" `Quick test_no_root
        ; Alcotest.test_case "not under a folder of homes open to others" `Quick test_open_home
        ] )
    ; ( "remove"
      , [ Alcotest.test_case "the keys and the home of the account alone" `Quick test_removed
        ; Alcotest.test_case "an account with no files" `Quick test_nothing_made
        ; Alcotest.test_case "a link is not followed" `Quick test_link
        ; Alcotest.test_case "a file in place of the folder of the keys" `Quick test_not_a_folder
        ; Alcotest.test_case "a FIFO in place of the folder of the keys" `Quick test_a_fifo
        ; Alcotest.test_case "the key that does not go" `Quick test_key_stays
        ; Alcotest.test_case "the home that does not go" `Quick test_home_stays
        ; Alcotest.test_case "the folder of the keys alone" `Quick test_keys_alone
        ] )
    ; "list", [ Alcotest.test_case "what is said of the key" `Quick test_key_state ]
    ; ( "replace"
      , [ Alcotest.test_case "the new key, and the folder of the keys with it alone" `Quick test_replaced
        ; Alcotest.test_case "an account with no files" `Quick test_replaced_with_no_files
        ; Alcotest.test_case "the files of the other generations" `Quick test_other_keys
        ; Alcotest.test_case "a link in place of the folder is not read" `Quick test_other_keys_link
        ; Alcotest.test_case "another file that does not go" `Quick test_other_keys_stay
        ] )
    ]
;;
