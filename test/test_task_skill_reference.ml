open Alcotest
open Masc

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
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

let test_path_missing_mismatch_and_valid () =
  with_base @@ fun base ->
  expect_error "path traversal" base [ "../x" ] "one non-empty portable path segment";
  expect_error "missing skill" base [ "missing" ] "does not exist";
  write_skill base ~directory:"guide" ~declared_name:"other";
  expect_error "frontmatter mismatch" base [ "guide" ] "does not match directory";
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
      , [ test_case "path, existence, name agreement, valid" `Quick
            test_path_missing_mismatch_and_valid
        ] )
    ]
;;
