(* keeper_skill's [file] argument resolves under the skill directory, or not
   at all. The path is model-supplied, so these are the cases that matter. *)

open Masc

let resolved = Alcotest.(check (option string))

let path file =
  match
    Keeper_tool_composition_surface.bundled_file_path
      ~skills_dir:"/base/.masc/skills"
      ~skill:"deep-review"
      ~file
  with
  | Ok p -> Some p
  | Error _ -> None
;;

let test_a_relative_file_resolves_under_the_skill () =
  resolved
    "the path the body spells"
    (Some "/base/.masc/skills/deep-review/references/RUBRIC.md")
    (path "references/RUBRIC.md");
  resolved
    "a file at the skill root"
    (Some "/base/.masc/skills/deep-review/NOTES.md")
    (path "NOTES.md")
;;

let test_nothing_escapes_the_skill_directory () =
  resolved "a parent segment" None (path "../other-skill/SKILL.md");
  resolved "a parent segment deeper in" None (path "references/../../escape.md");
  resolved "an absolute path" None (path "/etc/passwd");
  resolved "an empty segment" None (path "references//RUBRIC.md");
  resolved "a trailing separator" None (path "references/")
;;

let () =
  Alcotest.run
    "keeper-skill-bundled-file"
    [ ( "bundled_file_path"
      , [ Alcotest.test_case "a relative file resolves under the skill" `Quick
            test_a_relative_file_resolves_under_the_skill
        ; Alcotest.test_case "nothing escapes the skill directory" `Quick
            test_nothing_escapes_the_skill_directory
        ] )
    ]
;;
