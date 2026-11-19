(** [File_system_named]: one entry for each file, found by the name the file
    system gives it.

    Each test makes its own directory. The entries are fresh [ref]s, so two
    answers are one entry exactly when they are physically equal.

    What is pinned:

    1. Two spellings of one file reach one entry, whether the file exists or
       is made later.
    2. A spelling whose file does not exist is asked again each time.
    3. A spelling whose file existed is remembered until a removal is told.
    4. After a change, [another_entry_now] gives the entry the path has now
       when the file came to exist under another name, or when a removal was
       told and the path is another file. *)

open Alcotest

let with_directory f =
  let directory = Unix.realpath (Filename.temp_dir "file_system_named_" "") in
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove directory) (fun () -> f directory)
;;

let registry () = File_system_named.create (fun () -> ref ())
let write path = Out_channel.with_open_text path (fun channel -> output_string channel "row\n")
let entry registry path = (File_system_named.resolve registry path).File_system_named.entry

let check_one_entry label left right =
  check bool label true (left == right)
;;

let check_two_entries label left right =
  check bool label true (left != right)
;;

let name_testable =
  testable
    (fun formatter -> function
      | File_system_named.Existing name -> Format.fprintf formatter "Existing %s" name
      | File_system_named.Not_yet name -> Format.fprintf formatter "Not_yet %s" name)
    ( = )
;;

(* [name] follows a symbolic link for a file that exists, and names the part
   of the path that exists for a file that does not. *)
let test_the_name_the_file_system_gives () =
  with_directory (fun directory ->
    let real = Filename.concat directory "real" in
    let link = Filename.concat directory "link" in
    Unix.mkdir real 0o755;
    Unix.symlink real link;
    write (Filename.concat real "log");
    check
      name_testable
      "a file that exists, through a link"
      (File_system_named.Existing (Filename.concat real "log"))
      (File_system_named.name (Filename.concat link "log"));
    check
      name_testable
      "a file that does not exist, through a link"
      (File_system_named.Not_yet (Filename.concat real "other"))
      (File_system_named.name (Filename.concat link "other"));
    check
      name_testable
      "nothing of the last two pieces exists"
      (File_system_named.Not_yet
         (Filename.concat (Filename.concat directory "missing") "log"))
      (File_system_named.name
         (Filename.concat (Filename.concat directory "missing") "log")))
;;

let test_two_spellings_of_a_file_are_one_entry () =
  with_directory (fun directory ->
    let registry = registry () in
    let real = Filename.concat directory "real" in
    let link = Filename.concat directory "link" in
    Unix.mkdir real 0o755;
    Unix.symlink real link;
    let spelled = Filename.concat real "log" in
    let through_link = Filename.concat link "log" in
    write spelled;
    let resolved = File_system_named.resolve registry spelled in
    check bool "the file existed" true resolved.File_system_named.existed;
    check_one_entry
      "the link's spelling"
      resolved.File_system_named.entry
      (entry registry through_link);
    check_two_entries
      "another file"
      resolved.File_system_named.entry
      (entry registry (Filename.concat real "other"));
    check bool "has an entry" true (File_system_named.has_entry registry through_link);
    check
      bool
      "a file never asked about has none"
      false
      (File_system_named.has_entry registry (Filename.concat real "unasked"));
    check int "two entries were made" 2 (List.length (File_system_named.entries registry)))
;;

(* The two spellings are asked before the file is there, and both are asked
   again once it is. *)
let test_a_file_made_later_is_one_entry () =
  with_directory (fun directory ->
    let registry = registry () in
    let real = Filename.concat directory "real" in
    let link = Filename.concat directory "link" in
    Unix.mkdir real 0o755;
    Unix.symlink real link;
    let spelled = Filename.concat real "log" in
    let through_link = Filename.concat link "log" in
    let before = File_system_named.resolve registry spelled in
    check bool "the file did not exist" false before.File_system_named.existed;
    check_one_entry
      "the link's spelling, before the file"
      before.File_system_named.entry
      (entry registry through_link);
    write through_link;
    check_one_entry
      "the same entry once the file is there"
      before.File_system_named.entry
      (entry registry spelled);
    check_one_entry
      "and through the link"
      before.File_system_named.entry
      (entry registry through_link);
    check
      (option reject)
      "the change made the file under the entry it was chosen by"
      None
      (File_system_named.another_entry_now registry before spelled))
;;

(* [log] is spelled through a piece that does not exist yet. The change makes
   the piece a link to another directory, so the file comes to exist under
   another name than the one its entry was chosen by. *)
let test_a_file_made_under_another_name () =
  with_directory (fun directory ->
    let registry = registry () in
    let real = Filename.concat directory "real" in
    let later = Filename.concat directory "later" in
    Unix.mkdir real 0o755;
    let spelled = Filename.concat later "log" in
    let before = File_system_named.resolve registry spelled in
    check bool "the file did not exist" false before.File_system_named.existed;
    Unix.symlink real later;
    write spelled;
    let named = entry registry (Filename.concat real "log") in
    check_two_entries
      "the entry of the name the file has"
      before.File_system_named.entry
      named;
    (match File_system_named.another_entry_now registry before spelled with
     | Some now -> check_one_entry "the entry the path has now" named now
     | None -> fail "the path kept the entry of a name the file does not have"))
;;

(* A spelling whose file existed costs the system calls once. The file is
   renamed away and the spelling made a link to another file: the remembered
   answer stands until the removal is told. *)
let test_a_removal_forgets_the_remembered_names () =
  with_directory (fun directory ->
    let registry = registry () in
    let spelled = Filename.concat directory "log" in
    let other = Filename.concat directory "other" in
    write spelled;
    write other;
    let before = File_system_named.resolve registry spelled in
    let of_other = entry registry other in
    check_two_entries "two files" before.File_system_named.entry of_other;
    Unix.rename spelled (Filename.concat directory "log.1");
    Unix.symlink other spelled;
    check_one_entry
      "the remembered entry, with the removal untold"
      before.File_system_named.entry
      (entry registry spelled);
    check
      (option reject)
      "and no other entry is reported"
      None
      (File_system_named.another_entry_now registry before spelled);
    File_system_named.removed registry;
    check_one_entry "the other file's entry once it is told" of_other (entry registry spelled);
    (match File_system_named.another_entry_now registry before spelled with
     | Some now -> check_one_entry "reported to whoever chose the old entry" of_other now
     | None -> fail "the removal was told and the old entry was kept");
    check int "the entries stay" 2 (List.length (File_system_named.entries registry)))
;;

(* What a file system that folds letter case answers is taken as it is. *)
let test_letter_case_follows_the_file_system () =
  with_directory (fun directory ->
    let registry = registry () in
    let spelled = Filename.concat directory "Alpha" in
    let folded = Filename.concat directory "alpha" in
    write spelled;
    let one_file = Sys.file_exists folded in
    check
      bool
      (if one_file then "one file, one entry" else "two names, two entries")
      one_file
      (entry registry spelled == entry registry folded))
;;

let () =
  run
    "file_system_named"
    [ ( "entries by the file system's name"
      , [ test_case "the name the file system gives" `Quick test_the_name_the_file_system_gives
        ; test_case
            "two spellings of a file are one entry"
            `Quick
            test_two_spellings_of_a_file_are_one_entry
        ; test_case "a file made later is one entry" `Quick test_a_file_made_later_is_one_entry
        ; test_case "a file made under another name" `Quick test_a_file_made_under_another_name
        ; test_case
            "a removal forgets the remembered names"
            `Quick
            test_a_removal_forgets_the_remembered_names
        ; test_case
            "letter case follows the file system"
            `Quick
            test_letter_case_follows_the_file_system
        ] )
    ]
;;
