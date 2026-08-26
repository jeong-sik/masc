open Alcotest

module Reference = Skill_reference

let source_id value =
  match Skill_source_config.source_id_of_string value with
  | Ok source_id -> source_id
  | Error detail -> fail detail
;;

let package_id value =
  match Reference.package_id_of_directory value with
  | Ok package_id -> package_id
  | Error _ -> failf "invalid package fixture %S" value
;;

let content_revision character =
  match Reference.content_revision_of_string (String.make 64 character) with
  | Ok revision -> revision
  | Error _ -> fail "invalid content revision fixture"
;;

let reference ?(source = "project-masc") ?(package = "review")
      ?(name = "review") ?(revision = 'a') () =
  Reference.make
    ~identity:
      (Reference.make_identity
         ~source_id:(source_id source)
         ~package_id:(package_id package)
         ~name)
    ~content_revision:(content_revision revision)
;;

let task skills : Masc_domain.task =
  { id = "task-001"
  ; title = "Exact Skill task"
  ; description = ""
  ; task_status = Todo
  ; priority = 3
  ; files = []
  ; created_at = "2026-08-26T00:00:00Z"
  ; created_by = Some "operator"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  ; skills
  }
;;

let references_json references =
  Reference.list_to_yojson references |> Yojson.Safe.to_string
;;

let check_references label expected actual =
  check string label (references_json expected) (references_json actual)
;;

let set_skills value = function
  | `Assoc fields -> `Assoc (("skills", value) :: List.remove_assoc "skills" fields)
  | json -> json
;;

let test_canonical_task_round_trip () =
  let expected = [ reference (); reference ~package:"verify" ~name:"verify" ~revision:'b' () ] in
  let json = Masc_domain.task_to_yojson (task expected) in
  (match json with
   | `Assoc fields ->
     check string
       "canonical skills field"
       (references_json expected)
       (List.assoc "skills" fields |> Yojson.Safe.to_string)
   | _ -> fail "task projection was not an object");
  match Masc_domain.task_of_yojson json with
  | Ok decoded -> check_references "exact references" expected decoded.skills
  | Error detail -> fail detail
;;

let test_absent_skills_is_empty () =
  let json = Masc_domain.task_to_yojson (task []) in
  (match json with
   | `Assoc fields -> check bool "empty field omitted" false (List.mem_assoc "skills" fields)
   | _ -> fail "task projection was not an object");
  match Masc_domain.task_of_yojson json with
  | Ok decoded -> check int "absent means none" 0 (List.length decoded.skills)
  | Error detail -> fail detail
;;

let expect_skills_decode_error label expected value =
  match Masc_domain.task_to_yojson (task []) |> set_skills value |> Masc_domain.task_of_yojson with
  | Error detail -> check string label expected detail
  | Ok decoded ->
    failf
      "%s silently decoded as %s"
      label
      (references_json decoded.skills)
;;

let test_present_invalid_skills_are_rejected () =
  let row = Reference.to_yojson (reference ()) in
  let partial =
    `Assoc
      [ ( "identity"
        , Reference.identity_to_yojson (reference ()).identity )
      ]
  in
  let unknown =
    match row with
    | `Assoc fields -> `Assoc (("path", `String "review/SKILL.md") :: fields)
    | _ -> fail "reference projection was not an object"
  in
  List.iter
    (fun (label, expected, value) -> expect_skills_decode_error label expected value)
    [ ( "legacy string"
      , "task.skills corrupt: skill_reference must be an object"
      , `List [ `String "review" ] )
    ; ( "partial reference"
      , "task.skills corrupt: skill_reference.content_revision is required"
      , `List [ partial ] )
    ; ( "unknown reference field"
      , "task.skills corrupt: skill_reference.path is unexpected"
      , `List [ unknown ] )
    ; ( "duplicate exact reference"
      , ( "task.skills corrupt: exact reference is duplicated: "
          ^ Yojson.Safe.to_string row )
      , `List [ row; row ] )
    ; "null skills", "task.skills corrupt: skills must be a list", `Null
    ]
;;

let () =
  run
    "Task exact Skill references"
    [ ( "codec"
      , [ test_case "canonical exact references round-trip" `Quick test_canonical_task_round_trip
        ; test_case "absent skills means none" `Quick test_absent_skills_is_empty
        ; test_case
            "present malformed shapes fail closed"
            `Quick
            test_present_invalid_skills_are_rejected
        ] )
    ]
;;
