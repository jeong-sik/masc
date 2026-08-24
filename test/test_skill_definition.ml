(** What a SKILL.md has to carry for masc to use it, and what it is allowed to
    carry that masc ignores.

    The second half is the point. Agent Skills is an open standard and the same
    file is expected to load in Claude Code, OpenClaw, Hermes, and pi at once,
    each reading its own [metadata.*] block. A loader that rejected a file for
    carrying a block it did not recognise would take masc out of that
    ecosystem, and would do it quietly — the skill would simply never appear.
    The [foreign metadata] cases below fail if that regression is ever made. *)

open Alcotest

module SD = Masc.Skill_definition

let ok_exn ~directory_name contents =
  match SD.load ~directory_name ~contents with
  | Ok skill -> skill
  | Error e ->
    failf "expected a loadable skill, got: %s" (SD.load_error_to_string e)
;;

let error_exn ~directory_name contents =
  match SD.load ~directory_name ~contents with
  | Error e -> e
  | Ok skill -> failf "expected a load error, got a skill named %S" skill.name
;;

(* A minimal skill: the two required fields and a body. *)
let minimal =
  {|---
name: humanize-korean
description: 한국어 문장의 AI 티를 제거한다
---

본문 첫 줄.
|}
;;

let test_required_fields_are_read () =
  let skill = ok_exn ~directory_name:"humanize-korean" minimal in
  check string "name" "humanize-korean" skill.SD.name;
  check
    string
    "description"
    "한국어 문장의 AI 티를 제거한다"
    skill.SD.description
;;

let test_body_is_kept_whole () =
  let skill = ok_exn ~directory_name:"humanize-korean" minimal in
  (* A task that names a skill has already chosen it, so the keeper gets the
     instruction rather than a summary it would have to open. *)
  check
    bool
    "the body after the frontmatter survives"
    true
    (String.trim skill.SD.body = "본문 첫 줄.")
;;

let test_missing_name_is_an_error () =
  let contents = {|---
description: 설명만 있다
---

본문.
|} in
  match error_exn ~directory_name:"nameless" contents with
  | SD.Missing_name -> ()
  | other ->
    failf "expected Missing_name, got: %s" (SD.load_error_to_string other)
;;

let test_missing_description_is_an_error () =
  (* A skill with no description tells a keeper nothing about when it applies.
     Loading it as a blank would surface later as an empty prompt block. *)
  let contents = {|---
name: silent
---

본문.
|} in
  match error_exn ~directory_name:"silent" contents with
  | SD.Missing_description -> ()
  | other ->
    failf
      "expected Missing_description, got: %s"
      (SD.load_error_to_string other)
;;

let test_name_must_match_its_directory () =
  (* Tasks reference skills by the directory name they see on disk. A file that
     renames itself would answer to a name no task can write. *)
  match error_exn ~directory_name:"on-disk" minimal with
  | SD.Name_mismatch { declared; directory } ->
    check string "declared" "humanize-korean" declared;
    check string "directory" "on-disk" directory
  | other ->
    failf "expected Name_mismatch, got: %s" (SD.load_error_to_string other)
;;

let test_no_frontmatter_is_missing_name () =
  (* Frontmatter.parse hands back an unread document when there is no opening
     delimiter, so both required fields read empty and name is reported first. *)
  match error_exn ~directory_name:"plain" "본문만 있는 파일.\n" with
  | SD.Missing_name -> ()
  | other ->
    failf "expected Missing_name, got: %s" (SD.load_error_to_string other)
;;

(* Frontmatter written for other runtimes. Shape taken from a published skill
   (im-ai-copyeditor), which carries both an openclaw and a hermes block. *)
let foreign_metadata =
  {|---
name: im-ai-copyeditor-grammar
description: 한국어 맞춤법과 문체를 문장 단위로 교정한다
compatibility: 문장 분절 스크립트 실행에 python3 필요
metadata:
  version: "0.3.0"
  openclaw:
    requires:
      anyBins: [python3, python]
  hermes:
    category: writing
    tags: [korean, proofreading, grammar]
---

본문.
|}
;;

let test_foreign_metadata_loads () =
  let skill = ok_exn ~directory_name:"im-ai-copyeditor-grammar" foreign_metadata in
  check string "name" "im-ai-copyeditor-grammar" skill.SD.name;
  check
    bool
    "description is read past the foreign blocks"
    true
    (String.length skill.SD.description > 0)
;;

let test_foreign_metadata_does_not_leak_into_the_body () =
  (* The frontmatter block ends at its closing delimiter whatever it contained,
     so a keeper never reads another runtime's requirements as instructions.
     Comparing the whole body says that exactly: anything left over from the
     nested blocks would make this string longer. *)
  let skill = ok_exn ~directory_name:"im-ai-copyeditor-grammar" foreign_metadata in
  check string "the body is what followed the delimiter" "본문." (String.trim skill.SD.body)
;;

let () =
  run
    "skill_definition"
    [ ( "required fields"
      , [ test_case "name and description are read" `Quick test_required_fields_are_read
        ; test_case "the body is kept whole" `Quick test_body_is_kept_whole
        ; test_case "a missing name is an error" `Quick test_missing_name_is_an_error
        ; test_case
            "a missing description is an error"
            `Quick
            test_missing_description_is_an_error
        ; test_case
            "the name must match its directory"
            `Quick
            test_name_must_match_its_directory
        ; test_case
            "a file with no frontmatter is missing a name"
            `Quick
            test_no_frontmatter_is_missing_name
        ] )
    ; ( "foreign metadata"
      , [ test_case
            "another runtime's blocks do not stop the load"
            `Quick
            test_foreign_metadata_loads
        ; test_case
            "another runtime's blocks stay out of the body"
            `Quick
            test_foreign_metadata_does_not_leak_into_the_body
        ] )
    ]
;;
