open Alcotest

module Snapshot = Skill_catalog_snapshot
module Reference = Skill_reference

let config_text ?(runtime = "one") ?(resource_read_max_bytes = 65536) sources =
  Printf.sprintf
    "[skills]\nresource-read-max-bytes = %d\n%s\n[runtime]\ndefault = %S\n"
    resource_read_max_bytes
    sources
    runtime
;;

let source_row ~id ~path =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = \"base-path\"\npath = %S\naccess = \"read-write\"\n"
    id
    path
;;

let parse_config text =
  match Skill_source_config.parse_text text with
  | Ok config -> config
  | Error diagnostics ->
    fail
      (String.concat
         "; "
         (List.map Skill_source_config.diagnostic_to_string diagnostics))
;;

let package directory =
  match Snapshot.package_id_of_directory directory with
  | Ok package_id -> package_id
  | Error _ -> failf "invalid package fixture %S" directory
;;

let document ~name ~description ~body =
  Printf.sprintf
    "---\nname: %s\ndescription: %s\n---\n%s"
    name
    description
    body
;;

let candidate ~directory source_text =
  Snapshot.Candidate_document { directory; source_text }
;;

let configured_snapshot ~config scans =
  match Snapshot.configured ~config scans with
  | Ok snapshot -> snapshot
  | Error _ -> fail "configured snapshot rejected matching source scans"
;;

let scans ~base_path config candidates_by_source =
  List.map2
    (fun source candidates ->
       let resolved =
         Skill_source_config.resolve ~base_path ~user_home:None source
       in
       let resolved_path =
         match resolved.resolution with
         | Resolved path -> path
         | _ -> fail "base-path source did not resolve"
       in
       { Snapshot.source = resolved
       ; observation =
           Source_ready { resolved_path; candidates = List.length candidates }
       ; candidates
       })
    config.Skill_source_config.sources
    candidates_by_source
;;

let two_sources =
  source_row ~id:"first" ~path:"first-skills"
  ^ source_row ~id:"second" ~path:"second-skills"
;;

let test_precedence_and_exact_identity () =
  let text = config_text two_sources in
  let config = parse_config text in
  let first = candidate ~directory:"review" (document ~name:"review" ~description:"First" ~body:"first body") in
  let second = candidate ~directory:"review" (document ~name:"review" ~description:"Second" ~body:"second body") in
  let snapshot =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ first ]; [ second ] ])
  in
  (match Snapshot.find_effective_by_name snapshot "review" with
   | Some entry -> check string "first source wins" "First" entry.document.description
   | None -> fail "effective review Skill missing");
  check int "both exact entries retained" 2 (List.length (Snapshot.entries snapshot));
  check int "one shadow" 1 (List.length (Snapshot.shadows snapshot));
  let source_ids = List.map (fun source -> source.Skill_source_config.id) config.sources in
  match source_ids with
  | [ first_id; second_id ] ->
    let first_identity =
      Snapshot.make_identity
        ~source_id:first_id
        ~package_id:(package "review")
        ~name:"review"
    in
    let second_identity =
      Snapshot.make_identity
        ~source_id:second_id
        ~package_id:(package "review")
        ~name:"review"
    in
    let first_entry =
      match Snapshot.find_exact snapshot first_identity with
      | Some entry -> entry
      | None -> fail "first exact entry missing"
    in
    let second_entry =
      match Snapshot.find_exact snapshot second_identity with
      | Some entry -> entry
      | None -> fail "second exact entry missing"
    in
    let first_reference = Snapshot.entry_reference first_entry in
    let second_reference = Snapshot.entry_reference second_entry in
    (match Snapshot.resolve_reference snapshot first_reference with
     | Ok resolved ->
       check string "first exact entry" "First" resolved.document.description
     | Error _ -> fail "first exact reference did not resolve");
    (match Snapshot.resolve_reference snapshot second_reference with
     | Ok resolved ->
       check string "shadow exact entry" "Second" resolved.document.description
     | Error _ -> fail "shadow exact reference did not resolve");
    let changed_revision =
      match Reference.content_revision_of_string (String.make 64 'f') with
      | Ok revision -> revision
      | Error _ -> fail "changed revision fixture was invalid"
    in
    let stale_reference =
      Reference.make ~identity:first_identity ~content_revision:changed_revision
    in
    (match Snapshot.resolve_reference snapshot stale_reference with
     | Error
         (Snapshot.Content_revision_mismatch
            { identity; requested; observed }) ->
       check bool
         "mismatch identity"
         true
         (Reference.equal_identity first_identity identity);
       check string
         "requested revision"
         (Reference.content_revision_to_string changed_revision)
         (Reference.content_revision_to_string requested);
       check string
         "observed revision"
         (Reference.content_revision_to_string first_reference.content_revision)
         (Reference.content_revision_to_string observed)
     | Error _ -> fail "revision mismatch returned the wrong typed error"
     | Ok _ -> fail "stale exact reference resolved");
    let missing_identity =
      Snapshot.make_identity
        ~source_id:first_id
        ~package_id:(package "absent")
        ~name:"absent"
    in
    let missing_reference =
      Reference.make
        ~identity:missing_identity
        ~content_revision:first_reference.content_revision
    in
    (match Snapshot.resolve_reference snapshot missing_reference with
     | Error (Snapshot.Identity_not_found identity) ->
       check bool
         "missing identity"
         true
         (Reference.equal_identity missing_identity identity)
     | Error _ -> fail "missing identity returned the wrong typed error"
     | Ok _ -> fail "missing exact identity resolved")
  | _ -> fail "expected two configured sources"
;;

let test_reversing_sources_reverses_winner () =
  let reversed_sources =
    source_row ~id:"second" ~path:"second-skills"
    ^ source_row ~id:"first" ~path:"first-skills"
  in
  let config = parse_config (config_text reversed_sources) in
  let second = candidate ~directory:"review" (document ~name:"review" ~description:"Second" ~body:"second") in
  let first = candidate ~directory:"review" (document ~name:"review" ~description:"First" ~body:"first") in
  let snapshot =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ second ]; [ first ] ])
  in
  match Snapshot.find_effective_by_name snapshot "review" with
  | Some entry -> check string "reversed winner" "Second" entry.document.description
  | None -> fail "effective review Skill missing"
;;

let test_scan_order_cannot_override_config () =
  let config = parse_config (config_text two_sources) in
  let first =
    candidate
      ~directory:"review"
      (document ~name:"review" ~description:"First" ~body:"first")
  in
  let second =
    candidate
      ~directory:"review"
      (document ~name:"review" ~description:"Second" ~body:"second")
  in
  let scans =
    scans ~base_path:"/workspace" config [ [ first ]; [ second ] ]
    |> List.rev
  in
  let snapshot = configured_snapshot ~config scans in
  match Snapshot.find_effective_by_name snapshot "review" with
  | Some entry ->
    check string "config order remains authoritative" "First" entry.document.description
  | None -> fail "effective review Skill missing"
;;

let test_missing_scan_is_typed_builder_error () =
  let config =
    parse_config (config_text (source_row ~id:"only" ~path:"skills"))
  in
  match Snapshot.configured ~config [] with
  | Error [ Snapshot.Missing_source_scan _ ] -> ()
  | Error _ -> fail "missing scan returned the wrong typed error"
  | Ok _ -> fail "snapshot accepted a missing configured source scan"
;;

let test_malformed_sibling_does_not_drop_valid () =
  let text = config_text (source_row ~id:"only" ~path:"skills") in
  let config = parse_config text in
  let malformed = candidate ~directory:"broken" "---\nname: broken\n---\nbody" in
  let valid = candidate ~directory:"valid" (document ~name:"valid" ~description:"Valid" ~body:"works") in
  let snapshot =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ malformed; valid ] ])
  in
  check int "valid entry survives" 1 (List.length (Snapshot.entries snapshot));
  check int "rejection retained" 1 (List.length (Snapshot.rejections snapshot));
  check bool "valid is effective" true (Option.is_some (Snapshot.find_effective_by_name snapshot "valid"))
;;

let test_revisions_track_only_skill_truth () =
  let sources = source_row ~id:"only" ~path:"skills" in
  let text_one = config_text ~runtime:"provider.one" sources in
  let text_two = config_text ~runtime:"provider.two" sources in
  let text_with_other_bound =
    config_text ~runtime:"provider.one" ~resource_read_max_bytes:131072 sources
  in
  let config_one = parse_config text_one in
  let config_two = parse_config text_two in
  let config_with_other_bound = parse_config text_with_other_bound in
  let original = candidate ~directory:"inspect" (document ~name:"inspect" ~description:"Inspect" ~body:"one") in
  let changed = candidate ~directory:"inspect" (document ~name:"inspect" ~description:"Inspect" ~body:"two") in
  let build config candidate =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ candidate ] ])
  in
  let first = build config_one original in
  let unrelated_runtime_change = build config_two original in
  let skill_change = build config_one changed in
  let resource_bound_change = build config_with_other_bound original in
  check
    string
    "unrelated runtime edit keeps config revision"
    (Snapshot.config_revision first |> Option.get |> Snapshot.config_revision_to_string)
    (Snapshot.config_revision unrelated_runtime_change
     |> Option.get
     |> Snapshot.config_revision_to_string);
  check
    string
    "unchanged catalog revision"
    (Snapshot.catalog_revision first |> Snapshot.catalog_revision_to_string)
    (Snapshot.catalog_revision unrelated_runtime_change
     |> Snapshot.catalog_revision_to_string);
  check bool
    "Skill bytes change catalog revision"
    true
    (Snapshot.catalog_revision_to_string (Snapshot.catalog_revision first)
     <> Snapshot.catalog_revision_to_string (Snapshot.catalog_revision skill_change));
  check bool
    "Skill bytes change snapshot revision"
    true
    (Snapshot.snapshot_revision_to_string (Snapshot.snapshot_revision first)
     <> Snapshot.snapshot_revision_to_string (Snapshot.snapshot_revision skill_change));
  check bool "resource bound changes config revision" true
    (Snapshot.config_revision first |> Option.get |> Snapshot.config_revision_to_string
     <> (Snapshot.config_revision resource_bound_change
         |> Option.get
         |> Snapshot.config_revision_to_string));
  check bool "resource bound changes snapshot revision" true
    (Snapshot.snapshot_revision_to_string (Snapshot.snapshot_revision first)
     <> Snapshot.snapshot_revision_to_string
          (Snapshot.snapshot_revision resource_bound_change))
;;

let test_exact_duplicate_is_rejected () =
  let config =
    parse_config (config_text (source_row ~id:"only" ~path:"skills"))
  in
  let duplicate = candidate ~directory:"same" (document ~name:"same" ~description:"Same" ~body:"body") in
  let snapshot =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ duplicate; duplicate ] ])
  in
  check int "one exact entry" 1 (List.length (Snapshot.entries snapshot));
  check int "one exact duplicate rejection" 1 (List.length (Snapshot.rejections snapshot))
;;

let test_public_projection_redacts_private_content () =
  let config =
    parse_config (config_text (source_row ~id:"only" ~path:"skills"))
  in
  let private_body = "PRIVATE_SKILL_BODY" in
  let entry = candidate ~directory:"private" (document ~name:"private" ~description:"Private" ~body:private_body) in
  let snapshot =
    configured_snapshot
      ~config
      (scans ~base_path:"/private/host/workspace" config [ [ entry ] ])
  in
  let public = Snapshot.to_public_yojson snapshot |> Yojson.Safe.to_string in
  check bool "body redacted" false (String_util.contains_substring public private_body);
  check bool
    "resolved host path redacted"
    false
    (String_util.contains_substring public "/private/host/workspace")
;;

let test_public_projection_exposes_document_rejection () =
  let config =
    parse_config (config_text (source_row ~id:"only" ~path:"skills"))
  in
  let mismatched =
    candidate
      ~directory:"directory-name"
      (document
         ~name:"declared-name"
         ~description:"Keep a mismatched skill usable."
         ~body:"body")
  in
  let public_json =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ mismatched ] ])
    |> Snapshot.to_public_yojson
  in
  let diagnostics =
    match public_json with
    | `Assoc fields ->
      (match List.assoc_opt "rejections" fields with
       | Some (`List [ `Assoc rejection_fields ]) ->
         (match List.assoc_opt "reason" rejection_fields with
          | Some (`Assoc reason_fields) ->
            (match List.assoc_opt "diagnostics" reason_fields with
             | Some (`List values) -> values
             | _ -> fail "public rejection has no diagnostics array")
          | _ -> fail "public rejection has no typed reason")
       | _ -> fail "public snapshot does not contain exactly one rejection")
    | _ -> fail "public snapshot is not an object"
  in
  check
    (list (testable Yojson.Safe.pp Yojson.Safe.equal))
    "the reason is public"
    [ `Assoc
        [ "code", `String "name_mismatch"
        ; ( "message"
          , `String
              "SKILL.md name \"declared-name\" does not match directory \"directory-name\"" )
        ; "declared", `String "declared-name"
        ; "directory", `String "directory-name"
        ]
    ]
    diagnostics
;;

let test_public_projection_redacts_absolute_config_path () =
  let text =
    config_text
      "[[skills.sources]]\nid = \"absolute\"\nanchor = \"absolute\"\npath = \"/private/host/skills\"\naccess = \"read-write\"\n"
  in
  let config = parse_config text in
  let source = List.hd config.Skill_source_config.sources in
  let resolved =
    Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
  in
  let scan =
    { Snapshot.source = resolved
    ; observation =
        Source_ready { resolved_path = "/private/host/skills"; candidates = 0 }
    ; candidates = []
    }
  in
  let public =
    configured_snapshot ~config [ scan ]
    |> Snapshot.to_public_yojson
    |> Yojson.Safe.to_string
  in
  check bool
    "absolute configured path redacted"
    false
    (String_util.contains_substring public "/private/host/skills")
;;

let test_package_id_is_one_path_segment () =
  check bool "plain package" true (Result.is_ok (Snapshot.package_id_of_directory "package"));
  check bool "parent rejected" true (Result.is_error (Snapshot.package_id_of_directory ".."));
  check bool "separator rejected" true (Result.is_error (Snapshot.package_id_of_directory "a/b"))
;;

(* entries keeps every exact identity, the shadowed one included; the
   effective list is what a reader resolving by name actually gets. Two
   sources declaring the same Skill name is the case that separates them, and
   the winner has to stay addressable by package id and content revision. *)
let test_effective_entries_drop_the_shadowed_one () =
  let config = parse_config (config_text two_sources) in
  let first =
    candidate
      ~directory:"review"
      (document ~name:"review" ~description:"First" ~body:"first body")
  in
  let second =
    candidate
      ~directory:"review"
      (document ~name:"review" ~description:"Second" ~body:"second body")
  in
  let snapshot =
    configured_snapshot
      ~config
      (scans ~base_path:"/workspace" config [ [ first ]; [ second ] ])
  in
  check int "both identities kept" 2 (List.length (Snapshot.entries snapshot));
  check int "one shadowed" 1 (List.length (Snapshot.shadows snapshot));
  match Snapshot.effective_entries snapshot with
  | [ entry ] ->
    check
      string
      "the winner is the effective entry"
      "First"
      entry.Snapshot.document.description;
    check
      string
      "its package id is addressable"
      "review"
      (Snapshot.package_id_to_string entry.Snapshot.identity.package_id);
    check
      bool
      "its content revision is named"
      true
      (String.length (Snapshot.content_revision_to_string entry.Snapshot.content_revision) > 0)
  | entries -> failf "expected one effective entry, got %d" (List.length entries)
;;

(* A Skill config that cannot be read still produces a snapshot. Without one
   the catalog reads as a workspace that has no Skills, which is a different
   fact from a workspace whose Skill config could not be opened. *)
let test_unreadable_config_still_produces_a_snapshot () =
  let snapshot = Snapshot.config_unreadable ~detail:"permission denied" in
  (match Snapshot.config_state snapshot with
   | Snapshot.Config_unreadable { detail } ->
     check string "the reason is kept" "permission denied" detail
   | Snapshot.Configured _ | Snapshot.Config_rejected _ ->
     fail "an unreadable config did not record itself as unreadable");
  check int "no entries" 0 (List.length (Snapshot.entries snapshot));
  check int "no effective entries" 0 (List.length (Snapshot.effective_entries snapshot))
;;

(* A rejected config keeps the diagnostics that rejected it, and names the
   source revision they were produced from: an operator reading the catalog
   has to be able to tell which text was refused. *)
let test_rejected_config_keeps_its_diagnostics () =
  let bad = "[skills]\nresource-read-max-bytes = \"lots\"\n" in
  let diagnostics =
    match Skill_source_config.parse_text bad with
    | Error diagnostics -> diagnostics
    | Ok _ -> fail "expected the sample config to be rejected"
  in
  let snapshot = Snapshot.config_rejected ~source_text:bad ~diagnostics in
  check int "no entries" 0 (List.length (Snapshot.entries snapshot));
  match Snapshot.config_state snapshot with
  | Snapshot.Config_rejected { source_revision; diagnostics = kept } ->
    check int "diagnostics kept" (List.length diagnostics) (List.length kept);
    check
      bool
      "the refused source is named by a revision"
      true
      (String.length (Snapshot.config_source_revision_to_string source_revision) > 0)
  | Snapshot.Configured _ | Snapshot.Config_unreadable _ ->
    fail "a rejected config did not record itself as rejected"
;;

(* An unreadable document and an unnameable directory are two different
   rejections, and the snapshot has to say which. Collapsing the name check to
   an option made [package_id = None] mean both "the directory is not a legal
   package id" and "it is a legal one we did not record", so a reader could not
   tell whether the skill had an identity at all.

   Only the second of these two catches that collapse -- an option built from a
   valid name carries the same [Some] either way, so the first passes against
   the erasing version too. It is here for the other half of the pair: that a
   file we could not open does not cost the skill its identity. *)
let test_unreadable_document_keeps_its_package_id () =
  let config = parse_config (config_text (source_row ~id:"first" ~path:"first-skills")) in
  let snapshot =
    configured_snapshot
      ~config
      (scans
         ~base_path:"/base"
         config
         [ [ Snapshot.Candidate_unreadable
               { directory = "release-checklist"
               ; path = "/base/first-skills/release-checklist/SKILL.md"
               ; detail = "permission denied"
               }
           ] ])
  in
  match Snapshot.rejections snapshot with
  | [ rejection ] ->
    check
      bool
      "the directory it could not read is still named"
      true
      (rejection.Snapshot.package_id <> None);
    (match rejection.Snapshot.reason with
     | Snapshot.Document_unreadable { detail; _ } ->
       check string "the reason is the unreadable file" "permission denied" detail
     | _ -> fail "an unreadable document was rejected for something else")
  | rejections -> failf "expected one rejection, got %d" (List.length rejections)
;;

let test_unnameable_directory_is_rejected_for_its_name () =
  let config = parse_config (config_text (source_row ~id:"first" ~path:"first-skills")) in
  let snapshot =
    configured_snapshot
      ~config
      (scans
         ~base_path:"/base"
         config
         [ [ Snapshot.Candidate_unreadable
               { directory = ".."
               ; path = "/base/first-skills/../SKILL.md"
               ; detail = "permission denied"
               }
           ] ])
  in
  match Snapshot.rejections snapshot with
  | [ rejection ] ->
    check
      bool
      "a directory that cannot be named has no identity"
      true
      (rejection.Snapshot.package_id = None);
    (match rejection.Snapshot.reason with
     | Snapshot.Invalid_package_id Snapshot.Parent_directory_package_id -> ()
     | _ -> fail "the name was not what the rejection blamed")
  | rejections -> failf "expected one rejection, got %d" (List.length rejections)
;;

let () =
  run
    "skill_catalog_snapshot"
    [ ( "snapshot"
      , [ test_case "precedence and exact identity" `Quick
            test_precedence_and_exact_identity
        ; test_case "reversed source order" `Quick
            test_reversing_sources_reverses_winner
        ; test_case "scan order cannot override config" `Quick
            test_scan_order_cannot_override_config
        ; test_case "missing scan is typed" `Quick
            test_missing_scan_is_typed_builder_error
        ; test_case "malformed sibling survives" `Quick
            test_malformed_sibling_does_not_drop_valid
        ; test_case "revision semantics" `Quick test_revisions_track_only_skill_truth
        ; test_case "exact duplicate" `Quick test_exact_duplicate_is_rejected
        ; test_case "public projection redaction" `Quick
            test_public_projection_redacts_private_content
        ; test_case "public document rejection" `Quick
            test_public_projection_exposes_document_rejection
        ; test_case "absolute path redaction" `Quick
            test_public_projection_redacts_absolute_config_path
        ; test_case "package id" `Quick test_package_id_is_one_path_segment
        ; test_case "effective entries drop the shadowed one" `Quick
            test_effective_entries_drop_the_shadowed_one
        ; test_case "unreadable config still snapshots" `Quick
            test_unreadable_config_still_produces_a_snapshot
        ; test_case "rejected config keeps diagnostics" `Quick
            test_rejected_config_keeps_its_diagnostics
        ; test_case "unreadable document keeps its id" `Quick
            test_unreadable_document_keeps_its_package_id
        ; test_case "unnameable directory blames the name" `Quick
            test_unnameable_directory_is_rejected_for_its_name
        ] )
    ]
;;
