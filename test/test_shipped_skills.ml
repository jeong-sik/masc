(* The first-party Skills under skills/ are embedded in the binary and installed
   into every new workspace, so each one has to be admitted by the same parser a
   Keeper turn uses. A composition the parser refuses does not disappear: it is
   projected as an instruction Skill with a diagnostic, and the Keeper silently
   loses the tool. These tests read the shipped files, not copies of them. *)

open Alcotest
module Skills = Masc.Keeper_skill_catalog

let skills_root = "../skills"
let skill_path name = Filename.concat (Filename.concat skills_root name) "SKILL.md"

let shipped_packages () =
  Sys.readdir skills_root
  |> Array.to_list
  |> List.filter (fun name -> Sys.file_exists (skill_path name))
  |> List.sort String.compare
;;

let parsed name =
  let document = In_channel.with_open_bin (skill_path name) In_channel.input_all in
  match Skills.parse_skill ~directory:name document with
  | Ok skill -> skill
  | Error error -> fail (name ^ ": " ^ Skills.error_to_string error)
;;

let test_every_shipped_skill_is_admitted () =
  let packages = shipped_packages () in
  check bool "skills/ holds at least one package" true (packages <> []);
  List.iter (fun name -> ignore (parsed name : Skills.skill)) packages
;;

let () =
  run
    "shipped skills"
    [ ( "admission"
      , [ test_case
            "every shipped skill is admitted"
            `Quick
            test_every_shipped_skill_is_admitted
        ] )
    ]
;;
