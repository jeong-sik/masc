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

let content_revision value =
  match Reference.content_revision_of_string value with
  | Ok revision -> revision
  | Error _ -> fail "invalid content revision fixture"
;;

let reference ?(source = "workspace") ?(package = "review") ?(name = "review")
      ?(revision = String.make 64 'a') () =
  Reference.make
    ~identity:
      (Reference.make_identity
         ~source_id:(source_id source)
         ~package_id:(package_id package)
         ~name)
    ~content_revision:(content_revision revision)
;;

let reference_json reference =
  Reference.to_yojson reference |> Yojson.Safe.to_string
;;

let check_reference label expected actual =
  check string label (reference_json expected) (reference_json actual)
;;

let test_canonical_round_trip () =
  let expected = reference () in
  match Reference.of_yojson (Reference.to_yojson expected) with
  | Ok actual -> check_reference "exact reference" expected actual
  | Error _ -> fail "canonical exact reference was rejected"
;;

let test_content_revision_is_domain_separated_skill_digest () =
  let first = Reference.content_revision_of_source_text "first" in
  let first_again = Reference.content_revision_of_source_text "first" in
  let second = Reference.content_revision_of_source_text "second" in
  check string
    "stable digest"
    (Reference.content_revision_to_string first)
    (Reference.content_revision_to_string first_again);
  check int
    "sha256 hex width"
    64
    (String.length (Reference.content_revision_to_string first));
  check bool
    "different bytes"
    true
    (not (Reference.equal_content_revision first second))
;;

let canonical_fields () =
  match Reference.to_yojson (reference ()) with
  | `Assoc fields -> fields
  | _ -> fail "reference projection was not an object"
;;

let identity_fields () =
  match List.assoc_opt "identity" (canonical_fields ()) with
  | Some (`Assoc fields) -> fields
  | _ -> fail "reference identity projection was not an object"
;;

let test_legacy_string_is_rejected () =
  match Reference.of_yojson (`String "review") with
  | Error (Reference.Expected_object { field = "skill_reference" }) -> ()
  | Error _ -> fail "legacy string returned the wrong typed error"
  | Ok _ -> fail "legacy string reference was accepted"
;;

let test_unknown_and_duplicate_fields_are_rejected () =
  let fields = canonical_fields () in
  let identity = `Assoc (identity_fields ()) in
  (match Reference.of_yojson (`Assoc (("path", `String "skills/review") :: fields)) with
   | Error (Reference.Unexpected_field { object_name = "skill_reference"; field = "path" }) -> ()
   | Error _ -> fail "unknown reference field returned the wrong error"
   | Ok _ -> fail "unknown reference field was accepted");
  (match Reference.of_yojson (`Assoc (("identity", identity) :: fields)) with
   | Error (Reference.Duplicate_field { object_name = "skill_reference"; field = "identity" }) -> ()
   | Error _ -> fail "duplicate reference field returned the wrong error"
   | Ok _ -> fail "duplicate reference field was accepted");
  let nested = `Assoc (("directory", `String "review") :: identity_fields ()) in
  let nested_reference =
    `Assoc
      [ "identity", nested
      ; "content_revision", `String (String.make 64 'a')
      ]
  in
  match Reference.of_yojson nested_reference with
  | Error (Reference.Unexpected_field { object_name = "identity"; field = "directory" }) -> ()
  | Error _ -> fail "unknown identity field returned the wrong error"
  | Ok _ -> fail "unknown identity field was accepted"
;;

let test_duplicate_exact_reference_is_rejected () =
  let row = Reference.to_yojson (reference ()) in
  match Reference.list_of_yojson (`List [ row; row ]) with
  | Error (Reference.Duplicate_reference duplicate) ->
    check_reference "reported duplicate" (reference ()) duplicate
  | Error _ -> fail "duplicate exact reference returned the wrong typed error"
  | Ok _ -> fail "duplicate exact reference was accepted"
;;

let test_invalid_coordinates_are_typed () =
  (match Reference.package_id_of_directory "parent\\child" with
   | Error Reference.Package_id_contains_separator -> ()
   | Error _ -> fail "Windows package separator returned the wrong typed error"
   | Ok _ -> fail "Windows package separator was accepted");
  let invalid_source =
    `Assoc
      [ ( "identity"
        , `Assoc
            [ "source_id", `String "../source"
            ; "package_id", `String "review"
            ; "name", `String "review"
            ] )
      ; "content_revision", `String (String.make 64 'a')
      ]
  in
  (match Reference.of_yojson invalid_source with
   | Error (Reference.Invalid_source_id "../source") -> ()
   | Error _ -> fail "invalid source returned the wrong typed error"
   | Ok _ -> fail "invalid source was accepted");
  let invalid_revision =
    `Assoc
      [ "identity", `Assoc (identity_fields ())
      ; "content_revision", `String "not-a-revision"
      ]
  in
  match Reference.of_yojson invalid_revision with
  | Error (Reference.Invalid_content_revision (Invalid_revision_length _)) -> ()
  | Error _ -> fail "invalid revision returned the wrong typed error"
  | Ok _ -> fail "invalid revision was accepted"
;;

let () =
  run
    "skill exact reference"
    [ ( "wire"
      , [ test_case "canonical round trip" `Quick test_canonical_round_trip
        ; test_case
            "content revision is a domain-separated Skill digest"
            `Quick
            test_content_revision_is_domain_separated_skill_digest
        ; test_case "legacy string is rejected" `Quick test_legacy_string_is_rejected
        ; test_case
            "unknown and duplicate fields are rejected"
            `Quick
            test_unknown_and_duplicate_fields_are_rejected
        ; test_case
            "duplicate exact reference is rejected"
            `Quick
            test_duplicate_exact_reference_is_rejected
        ; test_case
            "invalid coordinates are typed"
            `Quick
            test_invalid_coordinates_are_typed
        ] )
    ]
;;
