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
    ]
    (assoc_keys projected);
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
        ; Alcotest.test_case "reject unknown" `Quick
            test_unknown_field_is_rejected
        ; Alcotest.test_case "view meaning" `Quick
            test_view_explains_effective_values_and_sources
        ] )
    ]
