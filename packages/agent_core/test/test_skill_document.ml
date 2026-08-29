open Agent_core

let document_exn = function
  | Skill_document.Loaded document -> document
  | Skill_document.Unloadable diagnostics ->
    Alcotest.fail
      (String.concat
         "; "
         (List.map Skill_document.diagnostic_to_string diagnostics))
;;

let expect_rejection ~label ~directory_name ~contents expected =
  let outcome = Skill_document.decode ~directory_name contents in
  match outcome with
  | Skill_document.Loaded _ -> Alcotest.fail (label ^ " was admitted")
  | Skill_document.Unloadable diagnostics ->
    Alcotest.(check bool) label true (List.exists expected diagnostics)
;;

let test_official_document () =
  let decoded =
    Skill_document.decode
      ~directory_name:"pdf-processing"
      "---\nname: pdf-processing\ndescription: Process PDF files when requested.\nlicense: Apache-2.0\ncompatibility: Requires pdftotext.\nmetadata:\n  author: example-org\n  version: \"1.0\"\nallowed-tools: Bash(jq:*) Read\n---\n# PDF\n\nUse references/spec.md.\n"
  in
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
  Alcotest.(check int) "metadata values" 2 (List.length document.metadata_values);
  Alcotest.(check string)
    "body stays byte-exact"
    "# PDF\n\nUse references/spec.md.\n"
    document.body;
  Alcotest.(check (list string)) "valid document has no diagnostics" []
    (List.map Skill_document.diagnostic_to_string (Skill_document.diagnostics decoded))
;;

let test_body_and_unicode_are_preserved () =
  let crlf =
    Skill_document.decode
      ~directory_name:"crlf-skill"
      "---\r\nname: crlf-skill\r\ndescription: Read CRLF.\r\n---\r\nLine one\r\nLine two\r\n"
    |> document_exn
  in
  Alcotest.(check string) "CRLF body" "Line one\r\nLine two\r\n" crlf.body;
  let korean_description = String.concat "" (List.init 1024 (fun _ -> "가")) in
  let korean =
    Skill_document.decode
      ~directory_name:"리뷰"
      (Printf.sprintf
         "---\nname: 리뷰\ndescription: %s\n---\nBody"
         korean_description)
    |> document_exn
  in
  Alcotest.(check string) "Unicode name" "리뷰" korean.name;
  let nfkc =
    Skill_document.decode
      ~directory_name:"ｐｄｆ"
      "---\nname: ｐｄｆ\ndescription: Normalize an internationalized name.\n---\nBody"
    |> document_exn
  in
  Alcotest.(check string) "NFKC effective name" "pdf" nfkc.name
;;

let test_official_frontmatter_violations_are_rejected () =
  let description = String.concat "" (List.init 1025 (fun _ -> "가")) in
  let cases =
    [ ( "missing name"
      , "directory-name"
      , "---\ndescription: Missing the required name.\n---\nBody"
      , (function Skill_document.Missing_name -> true | _ -> false) )
    ; ( "name-directory mismatch"
      , "directory-name"
      , "---\nname: declared-name\ndescription: The names disagree.\n---\nBody"
      , (function
          | Skill_document.Name_mismatch
              { declared = "declared-name"; directory = "directory-name" } ->
            true
          | _ -> false) )
    ; ( "description over 1024 characters"
      , "long-description"
      , Printf.sprintf
          "---\nname: long-description\ndescription: %s\n---\nBody"
          description
      , (function
          | Skill_document.Description_too_long { length = 1025 } -> true
          | _ -> false) )
    ; ( "unknown top-level field"
      , "closed-frontmatter"
      , "---\nname: closed-frontmatter\ndescription: Reject unknown policy.\ndisable-model-invocation: true\n---\nBody"
      , (function
          | Skill_document.Unexpected_frontmatter_field
              "disable-model-invocation" -> true
          | _ -> false) )
    ; ( "non-string metadata"
      , "metadata-type"
      , "---\nname: metadata-type\ndescription: Reject non-string metadata.\nmetadata:\n  version: 2\n---\nBody"
      , (function
          | Skill_document.Invalid_metadata_value { key = "version" } -> true
          | _ -> false) )
    ; ( "duplicate metadata"
      , "metadata-duplicate"
      , "---\nname: metadata-duplicate\ndescription: Reject duplicate metadata.\nmetadata:\n  author: first\n  author: second\n---\nBody"
      , (function
          | Skill_document.Duplicate_metadata_key "author" -> true
          | _ -> false) )
    ; ( "empty compatibility"
      , "empty-compatibility"
      , "---\nname: empty-compatibility\ndescription: Reject empty compatibility.\ncompatibility: \"\"\n---\nBody"
      , (function Skill_document.Compatibility_empty -> true | _ -> false) )
    ; ( "non-string allowed-tools"
      , "tool-hint"
      , "---\nname: tool-hint\ndescription: Reject a non-string tool hint.\nallowed-tools: [Read]\n---\nBody"
      , (function
          | Skill_document.Invalid_field_type
              { field =
                  Skill_document.Standard Skill_document.Allowed_tools_syntax_only
              ; expected = Skill_document.String_value
              } ->
            true
          | _ -> false) )
    ; ( "UTF-8 byte-order mark"
      , "bom-guide"
      , "\xEF\xBB\xBF---\nname: bom-guide\ndescription: Reject the byte-order mark.\n---\nBody"
      , (function Skill_document.Byte_order_mark -> true | _ -> false) )
    ]
  in
  List.iter
    (fun (label, directory_name, contents, expected) ->
       expect_rejection ~label ~directory_name ~contents expected)
    cases
;;

let test_structural_failures_are_rejected () =
  let cases =
    [ ( "malformed YAML"
      , "---\nname: [broken\ndescription: nope\n---\nBody"
      , (function Skill_document.Malformed_yaml _ -> true | _ -> false) )
    ; ( "duplicate description"
      , "---\nname: duplicate\ndescription: first\ndescription: second\n---\nBody"
      , (function
          | Skill_document.Duplicate_field
              (Skill_document.Standard Skill_document.Description) -> true
          | _ -> false) )
    ; ( "unterminated frontmatter"
      , "---\nname: duplicate\ndescription: missing close\nBody"
      , (function Skill_document.Unterminated_frontmatter -> true | _ -> false) )
    ; ( "missing frontmatter"
      , "name: duplicate\ndescription: not frontmatter\nBody"
      , (function Skill_document.Missing_frontmatter -> true | _ -> false) )
    ; ( "frontmatter root is not a mapping"
      , "---\n- name\n- description\n---\nBody"
      , (function Skill_document.Frontmatter_not_mapping -> true | _ -> false) )
    ]
  in
  List.iter
    (fun (label, contents, expected) ->
       expect_rejection ~label ~directory_name:"duplicate" ~contents expected)
    cases
;;

let () =
  Alcotest.run
    "skill_document"
    [ ( "Agent Skills document"
      , [ Alcotest.test_case "official document" `Quick test_official_document
        ; Alcotest.test_case
            "body and Unicode"
            `Quick
            test_body_and_unicode_are_preserved
        ; Alcotest.test_case
            "official frontmatter violations"
            `Quick
            test_official_frontmatter_violations_are_rejected
        ; Alcotest.test_case
            "structural failures"
            `Quick
            test_structural_failures_are_rejected
        ] ) ]
;;
