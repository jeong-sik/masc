open Agent_core

let check_conformance expected = function
  | Skill_document.Loaded { conformance; _ } ->
    Alcotest.(check string)
      "conformance"
      expected
      (Skill_document.conformance_to_string conformance)
  | Skill_document.Unloadable _ -> Alcotest.(check string) "conformance" expected "unloadable"
;;

let document_exn = function
  | Skill_document.Loaded { document; _ } -> document
  | Skill_document.Unloadable _ -> Alcotest.fail "expected a loadable skill document"
;;

let test_official_document () =
  let decoded =
    Skill_document.decode
      ~directory_name:"pdf-processing"
      "---\nname: pdf-processing\ndescription: Process PDF files when requested.\nlicense: Apache-2.0\ncompatibility: Requires pdftotext.\nmetadata:\n  author: example-org\n  version: \"1.0\"\nallowed-tools: Read Bash(pdftotext:*)\n---\n# PDF\n\nUse references/spec.md.\n"
  in
  check_conformance "conformant" decoded;
  let document = document_exn decoded in
  Alcotest.(check string) "name" "pdf-processing" document.name;
  Alcotest.(check string)
    "description"
    "Process PDF files when requested."
    document.description;
  Alcotest.(check (list (pair string string)))
    "metadata"
    [ "author", "example-org"; "version", "1.0" ]
    document.metadata;
  Alcotest.(check string)
    "body stays byte-exact"
    "# PDF\n\nUse references/spec.md.\n"
    document.body
;;

let test_missing_name_is_visible_compatibility () =
  let decoded =
    Skill_document.decode
      ~directory_name:"directory-name"
      "---\ndescription: A portable skill with a recoverable missing name.\n---\nBody"
  in
  check_conformance "runtime_compatible" decoded;
  let document = document_exn decoded in
  Alcotest.(check string) "directory fallback" "directory-name" document.name;
  Alcotest.(check bool)
    "missing name diagnostic"
    true
    (List.mem Skill_document.Missing_name (Skill_document.diagnostics decoded))
;;

let test_missing_description_is_unloadable () =
  let decoded =
    Skill_document.decode ~directory_name:"missing-description" "---\nname: missing-description\n---\nBody"
  in
  check_conformance "unloadable" decoded;
  Alcotest.(check bool)
    "no document"
    true
    (match decoded with
     | Skill_document.Unloadable _ -> true
     | Skill_document.Loaded _ -> false)
;;

let test_real_yaml_and_extensions () =
  let decoded =
    Skill_document.decode
      ~directory_name:"yaml-values"
      "---\nname: yaml-values\ndescription: >-\n  Use this skill when: the input contains YAML.\nmetadata:\n  masc.composition: composition.toml\ndisable-model-invocation: true\n---\n```toml composition\nexample = true\n```\n"
  in
  check_conformance "conformant" decoded;
  let document = document_exn decoded in
  Alcotest.(check string)
    "folded description"
    "Use this skill when: the input contains YAML."
    document.description;
  Alcotest.(check (list (pair string string)))
    "metadata extension pointer"
    [ "masc.composition", "composition.toml" ]
    document.metadata;
  Alcotest.(check int) "one top-level extension" 1 (List.length document.extensions);
  Alcotest.(check bool)
    "markdown fence remains instructions"
    true
    (String.starts_with ~prefix:"```toml composition" document.body)
;;

let test_invalid_metadata_is_diagnostic_not_loss () =
  let decoded =
    Skill_document.decode
      ~directory_name:"metadata-types"
      "---\nname: metadata-types\ndescription: Preserve usable instructions.\nmetadata:\n  version: 2\n  author: somebody\n---\nBody"
  in
  check_conformance "runtime_compatible" decoded;
  let document = document_exn decoded in
  Alcotest.(check (list (pair string string)))
    "valid metadata survives"
    [ "author", "somebody" ]
    document.metadata;
  Alcotest.(check bool)
    "invalid entry diagnosed"
    true
    (List.exists
       (function
         | Skill_document.Invalid_metadata_value { key = "version" } -> true
         | _ -> false)
       (Skill_document.diagnostics decoded))
;;

let test_crlf_body_is_preserved () =
  let decoded =
    Skill_document.decode
      ~directory_name:"crlf-skill"
      "---\r\nname: crlf-skill\r\ndescription: Read CRLF.\r\n---\r\nLine one\r\nLine two\r\n"
  in
  check_conformance "conformant" decoded;
  Alcotest.(check string)
    "body"
    "Line one\r\nLine two\r\n"
    (document_exn decoded).body
;;

let test_unicode_length_counts_scalars () =
  let description = String.concat "" (List.init 1024 (fun _ -> "가")) in
  let decoded =
    Skill_document.decode
      ~directory_name:"unicode-length"
      (Printf.sprintf
         "---\nname: unicode-length\ndescription: %s\n---\nBody"
         description)
  in
  check_conformance "conformant" decoded;
  let too_long =
    Skill_document.decode
      ~directory_name:"unicode-length"
      (Printf.sprintf
         "---\nname: unicode-length\ndescription: %s가\n---\nBody"
         description)
  in
  check_conformance "runtime_compatible" too_long;
  Alcotest.(check bool)
    "reported scalar length"
    true
    (List.exists
       (function
         | Skill_document.Description_too_long { length = 1025 } -> true
         | _ -> false)
       (Skill_document.diagnostics too_long))
;;

let test_structural_failures_are_unloadable () =
  let cases =
    [ ( "malformed YAML"
      , "---\nname: [broken\ndescription: nope\n---\nBody"
      , (function
          | Skill_document.Malformed_yaml _ -> true
          | _ -> false) )
    ; ( "duplicate description"
      , "---\nname: duplicate\ndescription: first\ndescription: second\n---\nBody"
      , (function
          | Skill_document.Duplicate_field "description" -> true
          | _ -> false) )
    ; ( "unterminated"
      , "---\nname: unterminated\ndescription: missing close\nBody"
      , (function
          | Skill_document.Unterminated_frontmatter -> true
          | _ -> false) )
    ]
  in
  List.iter
    (fun (label, contents, expected) ->
       let outcome = Skill_document.decode ~directory_name:"duplicate" contents in
       check_conformance "unloadable" outcome;
       Alcotest.(check bool)
         label
         true
         (List.exists expected (Skill_document.diagnostics outcome)))
    cases
;;

let () =
  Alcotest.run
    "skill_document"
    [ ( "Agent Skills document"
      , [ Alcotest.test_case "official document" `Quick test_official_document
        ; Alcotest.test_case
            "missing name compatibility"
            `Quick
            test_missing_name_is_visible_compatibility
        ; Alcotest.test_case
            "missing description"
            `Quick
            test_missing_description_is_unloadable
        ; Alcotest.test_case "real YAML and extensions" `Quick test_real_yaml_and_extensions
        ; Alcotest.test_case
            "metadata diagnostics"
            `Quick
            test_invalid_metadata_is_diagnostic_not_loss
        ; Alcotest.test_case "CRLF" `Quick test_crlf_body_is_preserved
        ; Alcotest.test_case
            "Unicode scalar length"
            `Quick
            test_unicode_length_counts_scalars
        ; Alcotest.test_case
            "structural failures"
            `Quick
            test_structural_failures_are_unloadable
        ] ) ]
;;
