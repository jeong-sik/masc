open Masc_tui_keeper_config

let observed =
  Yojson.Safe.from_string
    {|{
      "autoboot_enabled": true,
      "max_context_override": null,
      "autonomous_wake_prompt": null,
      "sandbox_profile": "docker",
      "network_mode": "none",
      "allowed_paths": ["repo-a"],
      "effective_allowed_paths": ["repo-a", ".masc/playground/alpha/"],
      "prompt": {"instructions": "be exact"},
      "execution": {"selected_runtime_id": "codex_subscription.gpt-5.6-sol"},
      "proactive": {"enabled": true},
      "skills": {"names": null},
      "workspace": {"mention_targets": ["@alpha"]},
      "sources": {
        "has_live_override": true,
        "override_fields": ["runtime_id"],
        "precedence": ["live", "keeper.toml"],
        "default_manifest_path": "/config/keepers/alpha.toml",
        "live_meta_path": "/state/keepers/alpha.json"
      }
    }|}

let assoc_keys = function
  | `Assoc fields -> List.map fst fields
  | _ -> Alcotest.fail "expected object"

let test_editor_starts_from_observed_values () =
  let projected = editable_snapshot observed in
  Alcotest.(check (list string)) "editable keys"
    [ "runtime_id"
    ; "mention_targets"
    ; "autoboot_enabled"
    ; "max_context_override"
    ; "autonomous_wake_prompt"
    ; "allowed_paths"
    ; "sandbox_profile"
    ; "network_mode"
    ; "instructions"
    ; "proactive_enabled"
    ; "skills"
    ]
    (assoc_keys projected);
  Alcotest.(check string) "all Skills use the write contract" "{}"
    (projected |> Yojson.Safe.Util.member "skills" |> Yojson.Safe.to_string);
  Alcotest.(check string) "stem round-trips observed projection"
    (Yojson.Safe.to_string projected)
    (editor_stem observed |> Yojson.Safe.from_string |> Yojson.Safe.to_string)

let test_patch_contains_only_changed_fields () =
  let after =
    match editable_snapshot observed with
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
               if String.equal key "proactive_enabled" then key, `Bool false
               else key, value)
             fields)
    | _ -> assert false
  in
  match patch_of_edit ~before:observed ~after with
  | Error detail -> Alcotest.fail detail
  | Ok patch ->
      Alcotest.(check string) "one changed field"
        {|{"proactive_enabled":false}|}
        (Yojson.Safe.to_string patch)

let test_deleted_field_means_unchanged () =
  match patch_of_edit ~before:observed ~after:(`Assoc []) with
  | Error detail -> Alcotest.fail detail
  | Ok patch ->
      Alcotest.(check string) "empty patch" "{}" (Yojson.Safe.to_string patch)

let with_edited_skills before skills =
  match editable_snapshot before with
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if String.equal key "skills" then key, skills else key, value)
           fields)
  | _ -> assert false

let check_skill_patch ~label ~before ~skills ~expected =
  let after = with_edited_skills before skills in
  match patch_of_edit ~before ~after with
  | Error detail -> Alcotest.fail detail
  | Ok patch ->
      Alcotest.(check string) label expected (Yojson.Safe.to_string patch)

let with_observed_skill_names names =
  match observed with
  | `Assoc fields ->
      `Assoc
        (("skills", `Assoc [ "names", names ])
        :: List.remove_assoc "skills" fields)
  | _ -> assert false

let test_skill_selection_patch_modes () =
  check_skill_patch ~label:"none" ~before:observed
    ~skills:(`Assoc [ "names", `List [] ])
    ~expected:{|{"skills":{"names":[]}}|};
  check_skill_patch ~label:"exact names" ~before:observed
    ~skills:(`Assoc [ "names", `List [ `String "review"; `String "research" ] ])
    ~expected:{|{"skills":{"names":["review","research"]}}|};
  let exact_before =
    with_observed_skill_names (`List [ `String "review" ])
  in
  check_skill_patch ~label:"all" ~before:exact_before ~skills:(`Assoc [])
    ~expected:{|{"skills":{}}|}

let test_skill_selection_view_modes () =
  let check label expected json =
    Alcotest.(check bool) label true (List.mem expected (view_lines json))
  in
  check "all" "Skills                 all published Skills" observed;
  check "none" "Skills                 none"
    (with_observed_skill_names (`List []));
  check "exact names" "Skills                 review, research"
    (with_observed_skill_names
       (`List [ `String "review"; `String "research" ]))

let test_unknown_field_is_rejected () =
  match
    patch_of_edit ~before:observed ~after:(`Assoc [ "mystery", `Bool true ])
  with
  | Ok _ -> Alcotest.fail "unknown field was accepted"
  | Error detail ->
      Alcotest.(check string) "actionable error"
        "unknown keeper setting(s): mystery" detail

let test_view_explains_effective_values_and_sources () =
  let rendered = view_lines observed |> String.concat "\n" in
  let contains needle =
    let pattern = Str.regexp_string needle in
    try
      ignore (Str.search_forward pattern rendered 0);
      true
    with Not_found -> false
  in
  List.iter
    (fun needle -> Alcotest.(check bool) needle true (contains needle))
    [ "# effective settings"
    ; "codex_subscription.gpt-5.6-sol"
    ; "docker / none"
    ; "Skills                 all published Skills"
    ; "# provenance"
    ; "/config/keepers/alpha.toml"
    ; "Only changed fields are sent"
    ]

let () =
  Alcotest.run "tui keeper config"
    [ ( "projection"
      , [ Alcotest.test_case "observed editor stem" `Quick
            test_editor_starts_from_observed_values
        ; Alcotest.test_case "changed-only patch" `Quick
            test_patch_contains_only_changed_fields
        ; Alcotest.test_case "deleted means unchanged" `Quick
            test_deleted_field_means_unchanged
        ; Alcotest.test_case "skill selection modes" `Quick
            test_skill_selection_patch_modes
        ; Alcotest.test_case "skill selection view modes" `Quick
            test_skill_selection_view_modes
        ; Alcotest.test_case "reject unknown" `Quick
            test_unknown_field_is_rejected
        ; Alcotest.test_case "view meaning" `Quick
            test_view_explains_effective_values_and_sources
        ] )
    ]
