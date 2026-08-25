open Alcotest
open Masc

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_base f =
  let base = Filename.temp_file "task-skill-reference-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> f base)
;;

let write_skill base ~directory ~declared_name =
  let skill_dir =
    Filename.concat
      (Filename.concat (Filename.concat base ".masc") "skills")
      directory
  in
  Fs_compat.mkdir_p skill_dir;
  Fs_compat.save_file
    (Filename.concat skill_dir "SKILL.md")
    (Printf.sprintf
       "---\nname: %s\ndescription: fixture\n---\n\nRead all instructions.\n"
       declared_name)
;;

let expect_error label base names expected =
  match Masc_task_handlers.Task_skill_reference.validate_all ~base_path:base names with
  | Ok () -> failf "%s was accepted" label
  | Error detail ->
    check bool label true (String_util.contains_substring detail expected)
;;

let test_path_missing_compatible_mismatch_and_valid () =
  with_base @@ fun base ->
  expect_error "path traversal" base [ "../x" ] "one non-empty portable path segment";
  expect_error "missing skill" base [ "missing" ] "does not exist";
  write_skill base ~directory:"guide" ~declared_name:"other";
  (match
     Masc_task_handlers.Task_skill_reference.validate_all ~base_path:base [ "guide" ]
   with
   | Ok () -> ()
   | Error detail -> failf "compatible name mismatch was rejected: %s" detail);
  let linked_dir =
    Filename.concat
      (Filename.concat (Filename.concat base ".masc") "skills")
      "linked"
  in
  Fs_compat.mkdir_p linked_dir;
  let outside = Filename.concat base "outside-skill.md" in
  Fs_compat.save_file outside
    "---\nname: linked\ndescription: fixture\n---\n\nexternal\n";
  Unix.symlink outside (Filename.concat linked_dir "SKILL.md");
  expect_error "symlinked SKILL.md" base [ "linked" ] "must not be a symlink";
  write_skill base ~directory:"valid" ~declared_name:"valid";
  match
    Masc_task_handlers.Task_skill_reference.validate_all
      ~base_path:base
      [ "valid" ]
  with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let () =
  Alcotest.run
    "task skill reference"
    [ ( "authoring"
      , [ test_case "path, existence, compatibility, valid" `Quick
            test_path_missing_compatible_mismatch_and_valid
        ] )
    ]
;;
