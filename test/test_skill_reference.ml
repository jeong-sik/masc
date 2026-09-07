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

let identity_json ?(source = "workspace") ?(package = "review") ?(name = "review") () =
  `Assoc
    [ "source_id", `String source; "package_id", `String package; "name", `String name ]
;;

(* Pinning and not pinning are different asks, and the decode says which. Folded
   into one -- an absent revision standing for some default -- the caller that
   spelled a revision out and the caller that left it open would arrive at the
   resolver as the same value, and only one of them may be answered with a
   revision it did not name. RFC-0411 §4.2. *)
let test_a_request_says_whether_it_pinned () =
  let pinned = reference ~revision:(String.make 64 'b') () in
  (match Reference.request_of_yojson (Reference.to_yojson pinned) with
   | Ok (Reference.Pinned decoded) -> check_reference "the pin survives" pinned decoded
   | Ok (Reference.By_identity _) -> fail "a spelled-out revision decoded as unpinned"
   | Error _ -> fail "a canonical reference stopped decoding");
  match
    Reference.request_of_yojson (`Assoc [ "identity", identity_json ~name:"review" () ])
  with
  | Ok (Reference.By_identity identity) ->
    check string "the identity is kept whole" "review"
      (Reference.identity_to_yojson identity
       |> Yojson.Safe.Util.member "name"
       |> Yojson.Safe.Util.to_string)
  | Ok (Reference.Pinned _) -> fail "an absent revision invented a pin"
  | Error _ -> fail "an identity-only request was rejected"
;;

(* The two ways a revision can be missing are not the same. Absent is a request
   this module forwards; present-and-wrong is a request it refuses. A decoder
   that treated a malformed revision as absent would resolve it against the
   snapshot and serve content the caller never asked for. *)
let test_an_omitted_revision_is_not_a_bad_one () =
  match
    Reference.request_of_yojson
      (`Assoc
        [ "identity", identity_json (); "content_revision", `String "not-a-revision" ])
  with
  | Error (Reference.Invalid_content_revision _) -> ()
  | Error _ -> fail "a malformed revision was rejected for the wrong reason"
  | Ok (Reference.By_identity _) -> fail "a malformed revision was read as absent"
  | Ok (Reference.Pinned _) -> fail "a malformed revision was accepted"
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
      , [ test_case "a request says whether it pinned" `Quick
            test_a_request_says_whether_it_pinned
        ; test_case "an omitted revision is not a bad one" `Quick
            test_an_omitted_revision_is_not_a_bad_one
        ; test_case "canonical round trip" `Quick test_canonical_round_trip
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
