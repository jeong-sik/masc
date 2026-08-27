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
      "---\nname: pdf-processing\ndescription: Process PDF files when requested.\nlicense: Apache-2.0\ncompatibility: Requires pdftotext.\nmetadata:\n  author: example-org\n  version: \"1.0\"\n---\n# PDF\n\nUse references/spec.md.\n"
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
  check_conformance "runtime_compatible" decoded;
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
    "boolean extension value survives"
    true
    (match List.assoc_opt "disable-model-invocation" document.extensions with
     | Some (Skill_document.Boolean true) -> true
     | Some _ | None -> false);
  Alcotest.(check bool)
    "top-level extension is not called conformant"
    true
    (List.exists
       (function
         | Skill_document.Unexpected_frontmatter_field
             "disable-model-invocation" -> true
         | _ -> false)
       (Skill_document.diagnostics decoded));
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

let test_unicode_and_nfkc_names () =
  let korean =
    Skill_document.decode
      ~directory_name:"리뷰"
      "---\nname: 리뷰\ndescription: 한국어 이름을 사용하는 스킬.\n---\nBody"
  in
  check_conformance "conformant" korean;
  Alcotest.(check string) "Unicode name" "리뷰" (document_exn korean).name;
  let nfkc =
    Skill_document.decode
      ~directory_name:"ｐｄｆ"
      "---\nname: ｐｄｆ\ndescription: Normalize an internationalized name.\n---\nBody"
  in
  check_conformance "conformant" nfkc;
  Alcotest.(check string) "NFKC effective name" "pdf" (document_exn nfkc).name
;;

let test_name_mismatch_is_visible_compatibility () =
  let decoded =
    Skill_document.decode
      ~directory_name:"directory-name"
      "---\nname: declared-name\ndescription: Keep a mismatched skill usable.\n---\nBody"
  in
  check_conformance "runtime_compatible" decoded;
  Alcotest.(check string)
    "directory remains the effective name"
    "directory-name"
    (document_exn decoded).name;
  Alcotest.(check bool)
    "mismatch diagnostic"
    true
    (List.exists
       (function
         | Skill_document.Name_mismatch
             { declared = "declared-name"; directory = "directory-name" } ->
           true
         | _ -> false)
       (Skill_document.diagnostics decoded))
;;

let test_invalid_optional_values_are_diagnostic () =
  let decoded =
    Skill_document.decode
      ~directory_name:"optional-values"
      "---\nname: optional-values\ndescription: Diagnose explicit invalid optional values.\nlicense: null\ncompatibility: \"\"\nmetadata: null\n---\nBody"
  in
  check_conformance "runtime_compatible" decoded;
  let diagnostics = Skill_document.diagnostics decoded in
  let has_invalid_type field expected =
    List.exists
      (function
        | Skill_document.Invalid_field_type
            { field = Skill_document.Standard actual_field
            ; expected = actual_expected
            } ->
          actual_field = field && actual_expected = expected
        | _ -> false)
      diagnostics
  in
  Alcotest.(check bool)
    "null license"
    true
    (has_invalid_type Skill_document.License Skill_document.String_value);
  Alcotest.(check bool)
    "null metadata"
    true
    (has_invalid_type Skill_document.Metadata Skill_document.String_mapping);
  Alcotest.(check bool)
    "empty compatibility"
    true
    (List.mem Skill_document.Compatibility_empty diagnostics);
  let null_compatibility =
    Skill_document.decode
      ~directory_name:"null-compatibility"
      "---\nname: null-compatibility\ndescription: Diagnose null compatibility.\ncompatibility: null\n---\nBody"
  in
  check_conformance "runtime_compatible" null_compatibility;
  Alcotest.(check bool)
    "null compatibility"
    true
    (List.exists
       (function
         | Skill_document.Invalid_field_type
             { field = Skill_document.Standard Skill_document.Compatibility
             ; expected = Skill_document.String_value
             } ->
           true
         | _ -> false)
       (Skill_document.diagnostics null_compatibility))
;;

let test_allowed_tools_is_validated_but_not_retained () =
  let valid =
    Skill_document.decode
      ~directory_name:"allowed-tools"
      "---\nname: allowed-tools\ndescription: Validate the official optional field.\nallowed-tools: Bash(git:*) Read\n---\nBody"
  in
  check_conformance "conformant" valid;
  Alcotest.(check (list (pair string string)))
    "not retained as metadata"
    []
    (document_exn valid).metadata;
  Alcotest.(check int)
    "not retained as an extension"
    0
    (List.length (document_exn valid).extensions);
  List.iter
    (fun (label, value) ->
       let decoded =
         Skill_document.decode
           ~directory_name:"allowed-tools"
           (Printf.sprintf
              "---\nname: allowed-tools\ndescription: Reject a non-string official field.\nallowed-tools: %s\n---\nBody"
              value)
       in
       check_conformance "runtime_compatible" decoded;
       Alcotest.(check bool)
         label
         true
         (List.exists
            (function
              | Skill_document.Invalid_field_type
                  { field = Skill_document.Standard Skill_document.Allowed_tools
                  ; expected = Skill_document.String_value
                  } ->
                true
              | _ -> false)
            (Skill_document.diagnostics decoded)))
    [ "null allowed-tools", "null"; "sequence allowed-tools", "[Read]" ]
;;

let test_foreign_and_duplicate_metadata_is_preserved_without_ambiguity () =
  let decoded =
    Skill_document.decode
      ~directory_name:"metadata-preservation"
      "---\nname: metadata-preservation\ndescription: Preserve foreign metadata without choosing a duplicate.\nmetadata:\n  author: somebody\n  hermes:\n    tags: [writing, review]\n  masc.composition: first.toml\n  masc.composition: second.toml\n---\nBody"
  in
  check_conformance "runtime_compatible" decoded;
  let document = document_exn decoded in
  Alcotest.(check (list (pair string string)))
    "only unique standard scalar metadata is selectable"
    [ "author", "somebody" ]
    document.metadata;
  Alcotest.(check int)
    "all metadata values are preserved"
    4
    (List.length document.metadata_values);
  Alcotest.(check bool)
    "foreign mapping survives"
    true
    (match List.assoc_opt "hermes" document.metadata_values with
     | Some (Skill_document.Mapping _) -> true
     | Some _ | None -> false);
  Alcotest.(check bool)
    "duplicate key diagnosed"
    true
    (List.mem
       (Skill_document.Duplicate_metadata_key "masc.composition")
       (Skill_document.diagnostics decoded));
  Alcotest.(check bool)
    "ambiguous composition has no scalar winner"
    true
    (Option.is_none (List.assoc_opt "masc.composition" document.metadata))
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
         | Skill_document.Duplicate_field
             (Skill_document.Standard Skill_document.Description) -> true
          | _ -> false) )
    ; ( "unterminated"
      , "---\nname: unterminated\ndescription: missing close\nBody"
      , (function
          | Skill_document.Unterminated_frontmatter -> true
          | _ -> false) )
    ; ( "missing frontmatter"
      , "name: plain\ndescription: not frontmatter\nBody"
      , (function
          | Skill_document.Missing_frontmatter -> true
          | _ -> false) )
    ; ( "frontmatter root is not a mapping"
      , "---\n- name\n- description\n---\nBody"
      , (function
          | Skill_document.Frontmatter_not_mapping -> true
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

(* An editor-added UTF-8 BOM used to reject the whole document as
   frontmatter-less with a message that never named the mark. The mark is
   parsing noise, not content: the document loads as runtime-compatible with a
   diagnostic that says exactly what to remove. *)
let test_byte_order_mark_is_stripped_and_named () =
  let decoded =
    Skill_document.decode
      ~directory_name:"bom-guide"
      "\xEF\xBB\xBF---\nname: bom-guide\ndescription: Loads despite the byte-order mark.\n---\nBody.\n"
  in
  let document = document_exn decoded in
  Alcotest.(check string) "name" "bom-guide" document.name;
  Alcotest.(check string) "body stays byte-exact" "Body.\n" document.body;
  (match Skill_document.diagnostics decoded with
   | [ Skill_document.Byte_order_mark ] -> ()
   | diagnostics ->
     Alcotest.failf
       "expected exactly the byte-order-mark diagnostic, got %d: %s"
       (List.length diagnostics)
       (String.concat "; "
          (List.map Skill_document.diagnostic_to_string diagnostics)));
  match
    Skill_document.decode ~directory_name:"bom-broken" "\xEF\xBB\xBFnot frontmatter"
  with
  | Skill_document.Unloadable
      [ Skill_document.Byte_order_mark; Skill_document.Missing_frontmatter ] -> ()
  | Skill_document.Unloadable diagnostics ->
    Alcotest.failf
      "expected the mark beside the structural rejection, got: %s"
      (String.concat "; "
         (List.map Skill_document.diagnostic_to_string diagnostics))
  | Skill_document.Loaded _ ->
    Alcotest.fail "a frontmatter-less document must stay unloadable"
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
        ; Alcotest.test_case "Unicode and NFKC names" `Quick test_unicode_and_nfkc_names
        ; Alcotest.test_case
            "name mismatch compatibility"
            `Quick
            test_name_mismatch_is_visible_compatibility
        ; Alcotest.test_case
            "invalid optional values"
            `Quick
            test_invalid_optional_values_are_diagnostic
        ; Alcotest.test_case
            "allowed-tools optional string"
            `Quick
            test_allowed_tools_is_validated_but_not_retained
        ; Alcotest.test_case
            "foreign and duplicate metadata"
            `Quick
            test_foreign_and_duplicate_metadata_is_preserved_without_ambiguity
        ; Alcotest.test_case
            "structural failures"
            `Quick
            test_structural_failures_are_unloadable
        ; Alcotest.test_case
            "byte-order mark is stripped and named"
            `Quick
            test_byte_order_mark_is_stripped_and_named
        ] ) ]
;;
