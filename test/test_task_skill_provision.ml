open Alcotest

let test_provision_skill () =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_provision_%d" (Random.int 1000000))
  in
  let skill_dir =
    Filename.concat (Filename.concat base_path ".masc/skills") "test-skill"
  in
  Fs_compat.mkdir_p skill_dir;
  let skill_file = Filename.concat skill_dir "SKILL.md" in
  Fs_compat.save_file skill_file "# Test Skill\n";
  let result =
    Task_skill_provision.provision_skills
      ~base_path
      ~keeper_name:"test-keeper"
      [ "test-skill" ]
  in
  check bool "provision succeeds" true (Result.is_ok result);
  let target_file =
    Filename.concat
      base_path
      ".masc/playground/test-keeper/.masc/skills/test-skill/SKILL.md"
  in
  check
    bool
    "target file exists"
    true
    (match Fs_compat.exact_path_kind target_file with
     | Fs_compat.Exact_kind Unix.S_REG -> true
     | _ -> false);
  let contents = Fs_compat.load_file target_file in
  check string "target content matches" "# Test Skill\n" contents
;;

let () =
  run
    "task_skill_provision"
    [ ( "provision"
      , [ test_case
            "provisions skill into keeper sandbox"
            `Quick
            test_provision_skill
        ] )
    ]
;;
