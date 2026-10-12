open Masc_tui_keeper_config

let observed =
  Yojson.Safe.from_string
    {|{
      "config_revision": {
        "manifest": {"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        "runtime_assignment": {
          "state":"runtime_config_present",
          "source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}
        }
      },
      "activation_mode": "autonomous",
      "input_policy": "small",
      "max_context_override": null,
      "sandbox_profile": "docker",
      "network_mode": "none",
      "sandbox_roots": ["repo-a", ".masc/playground/alpha/"],
      "prompt": {"instructions": "be exact"},
      "execution": {"selected_runtime_id": "codex_subscription.gpt-5.6-sol"},
      "skills": {"names": null},
      "workspace": {"mention_targets": ["@alpha"], "board_interests": []},
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
    ; "board_interests"
    ; "activation_mode"
    ; "input_policy"
    ; "max_context_override"
    ; "sandbox_profile"
    ; "network_mode"
    ; "instructions"
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
               if String.equal key "activation_mode" then key, `String "manual"
               else key, value)
             fields)
    | _ -> assert false
  in
  match patch_of_edit ~before:observed ~after with
  | Error refusal -> Alcotest.fail (edit_refusal_to_string refusal)
  | Ok patch ->
      Alcotest.(check string) "one changed field"
        {|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"activation_mode":"manual"}|}
        (Yojson.Safe.to_string patch)

let test_input_policy_patch () =
  match patch_of_edit ~before:observed ~after:(`Assoc ["input_policy", `String "wide"]) with
  | Error refusal -> Alcotest.fail (edit_refusal_to_string refusal)
  | Ok patch ->
      Alcotest.(check string) "policy change is editable" "wide"
        (Yojson.Safe.Util.member "input_policy" patch |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "capacity remains unchanged" false
        (List.mem "max_context_override" (assoc_keys patch))

let test_deleted_field_means_unchanged () =
  match patch_of_edit ~before:observed ~after:(`Assoc []) with
  | Error refusal -> Alcotest.fail (edit_refusal_to_string refusal)
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
  | Error refusal -> Alcotest.fail (edit_refusal_to_string refusal)
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
    ~expected:{|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"skills":{"names":[]}}|};
  check_skill_patch ~label:"exact names" ~before:observed
    ~skills:(`Assoc [ "names", `List [ `String "review"; `String "research" ] ])
    ~expected:{|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"skills":{"names":["review","research"]}}|};
  let exact_before =
    with_observed_skill_names (`List [ `String "review" ])
  in
  check_skill_patch ~label:"all" ~before:exact_before ~skills:(`Assoc [])
    ~expected:{|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"skills":{}}|}

let contains haystack needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern haystack 0);
    true
  with Not_found -> false

let editable_glyph = "\xe2\x97\x8f"
let test_unknown_field_is_rejected () =
  match
    patch_of_edit ~before:observed ~after:(`Assoc [ "mystery", `Bool true ])
  with
  | Ok _ -> Alcotest.fail "unknown field was accepted"
  | Error (Cannot_send detail) -> Alcotest.fail ("not an editor refusal: " ^ detail)
  | Error (Fix_in_editor detail) ->
      Alcotest.(check string) "actionable error"
        "unknown keeper setting(s): mystery" detail

(* activation_mode is a closed set on the server. A value outside it used to
   travel to the server and come back as one status line; now it is refused
   before the request, as something the operator fixes in the editor, and the
   refusal names every value the set accepts. *)
let test_activation_outside_the_set_is_an_editor_refusal () =
  let edit value = `Assoc [ "activation_mode", value ] in
  List.iter
    (fun (label, value) ->
      match patch_of_edit ~before:observed ~after:(edit value) with
      | Ok patch ->
        Alcotest.fail (label ^ " reached a patch: " ^ Yojson.Safe.to_string patch)
      | Error (Cannot_send detail) -> Alcotest.fail (label ^ ": " ^ detail)
      | Error (Fix_in_editor reason) ->
        Alcotest.(check bool) (label ^ " names the set") true
          (contains reason "manual | on_demand | autonomous");
        Alcotest.(check bool) (label ^ " names the value") true
          (contains reason (Yojson.Safe.to_string value)))
    [ "alias", `String "auto"; "wrong case", `String "Autonomous"; "not a string", `Bool true ];
  match patch_of_edit ~before:observed ~after:(edit (`String "on_demand")) with
  | Error refusal -> Alcotest.fail (edit_refusal_to_string refusal)
  | Ok patch ->
    Alcotest.(check string) "a member of the set is sent" "on_demand"
      (Yojson.Safe.Util.member "activation_mode" patch |> Yojson.Safe.Util.to_string)

(* The reopened text has to parse as exactly what the operator left, and a
   second refusal replaces the first rather than stacking on it. *)
let test_reopened_stem_parses_and_replaces () =
  let edited = {|{
  "activation_mode": "auto"
}|} in
  let once = reopened_stem ~reason:"first\nreason" edited in
  let twice = reopened_stem ~reason:"second" once in
  Alcotest.(check string) "same JSON as the edit"
    (Yojson.Safe.to_string (Yojson.Safe.from_string edited))
    (Yojson.Safe.to_string (Yojson.Safe.from_string twice));
  Alcotest.(check (list string)) "one refusal line, the latest" [ "// second" ]
    (String.split_on_char '\n' twice
     |> List.filter (fun line -> String.starts_with ~prefix:"//" line));
  Alcotest.(check bool) "reason is kept on one line" true
    (String.starts_with ~prefix:"// first reason\n" once)

(* No revision to send against is not the operator's text to fix: reopening
   the editor over it would loop on something no edit can change. *)
let test_missing_revision_is_not_an_editor_refusal () =
  let before = `Assoc [ "activation_mode", `String "manual" ] in
  match
    patch_of_edit ~before ~after:(`Assoc [ "activation_mode", `String "autonomous" ])
  with
  | Error (Cannot_send _) -> ()
  | Error (Fix_in_editor reason) -> Alcotest.fail ("reopens over: " ^ reason)
  | Ok patch -> Alcotest.fail ("sent without a revision: " ^ Yojson.Safe.to_string patch)

(* The server refuses a patch that lowers [max_context_override] unless it
   carries [confirm_context_shrink], and says so in its refusal. The editor
   has to let the operator follow that instruction: the key is not a setting,
   so it never appears in the stem, but typing it must reach the patch. *)
let test_context_shrink_confirmation_reaches_the_patch () =
  let shrink =
    `Assoc
      [ "max_context_override", `Int 100_000
      ; "confirm_context_shrink", `Bool true
      ]
  in
  (match patch_of_edit ~before:observed ~after:shrink with
   | Error refusal ->
       Alcotest.fail
         ("shrink confirmation was refused: " ^ edit_refusal_to_string refusal)
   | Ok (`Assoc fields) ->
       Alcotest.(check bool) "carries the confirmation" true
         (List.assoc_opt "confirm_context_shrink" fields = Some (`Bool true));
       Alcotest.(check bool) "carries the new window" true
         (List.assoc_opt "max_context_override" fields = Some (`Int 100_000))
   | Ok _ -> Alcotest.fail "patch was not an object");
  (* On its own the flag changes nothing, so it must not post a patch. *)
  match
    patch_of_edit ~before:observed
      ~after:(`Assoc [ "confirm_context_shrink", `Bool true ])
  with
  | Ok (`Assoc []) -> ()
  | Ok _ -> Alcotest.fail "the bare confirmation posted a patch"
  | Error refusal ->
      Alcotest.fail ("bare confirmation errored: " ^ edit_refusal_to_string refusal)

let test_fetched_text_is_sanitized_but_the_frame_is_not () =
  let hostile =
    Yojson.Safe.from_string
      {|{"prompt": {"instructions": "before\u001b[31mafter"},
         "execution": {"selected_runtime_id": "ok"}}|}
  in
  let rendered =
    view_lines
      ~sanitize:(fun text -> String.concat "<esc>" (String.split_on_char '\027' text))
      hostile
    |> String.concat "\n"
  in
  Alcotest.(check bool)
    "fetched escape was handed to sanitize"
    true
    (contains rendered "before<esc>[31mafter");
  Alcotest.(check bool) "frame kept its own marker" true (contains rendered editable_glyph)

let test_invalid_mode_text_is_sanitized_at_the_row_boundary () =
  let hostile =
    Yojson.Safe.from_string
      {|{"activation_mode": "before\u001b]8;;https://example.invalid\u0007after"}|}
  in
  let rendered =
    view_lines
      ~sanitize:(fun text -> String.concat "<esc>" (String.split_on_char '\027' text))
      hostile
    |> String.concat "\n"
  in
  Alcotest.(check bool)
    "invalid mode text was sanitized"
    true
    (contains rendered "before<esc>]8;;https://example.invalid")

let with_config_revision revision =
  match observed with
  | `Assoc fields ->
    `Assoc (("config_revision", revision) :: List.remove_assoc "config_revision" fields)
  | _ -> Alcotest.fail "observed fixture must be an object"

let test_runtime_picker_refuses_unavailable_revision () =
  let unavailable =
    with_config_revision
      (`Assoc
         [ "state", `String "unavailable"
         ; "detail", `String "manifest store offline"
         ])
  in
  match expected_runtime_assignment_revision unavailable with
  | Error detail ->
    Alcotest.(check bool) "error names the server detail" true
      (contains detail "manifest store offline")
  | Ok revision ->
    Alcotest.failf "picker accepted an unavailable revision: %s"
      (Yojson.Safe.to_string revision)

let changed_proactive =
  `Assoc [ "activation_mode", `String "on_demand" ]

let check_revision_rejected label revision =
  let before = with_config_revision revision in
  match patch_of_edit ~before ~after:changed_proactive with
  | Error _ -> ()
  | Ok patch ->
    Alcotest.failf "%s accepted malformed revision: %s" label
      (Yojson.Safe.to_string patch)

let test_strict_config_revision_decoder () =
  check_revision_rejected "missing runtime authority"
    (`Assoc
       [ ( "manifest"
         , `Assoc
             [ "state", `String "sha256"
             ; "value", `String (String.make 64 'a')
             ] )
       ]);
  check_revision_rejected "arbitrary nested runtime object"
    (`Assoc
       [ "manifest", `Assoc [ "state", `String "missing" ]
       ; ( "runtime_assignment"
         , `Assoc
             [ "state", `String "runtime_config_present"
             ; "source_revision", `String (String.make 64 'b')
             ] )
       ]);
  check_revision_rejected "uppercase source revision"
    (`Assoc
       [ "manifest", `Assoc [ "state", `String "missing" ]
       ; ( "runtime_assignment"
         , `Assoc
             [ "state", `String "runtime_config_present"
             ; "source_revision", `String (String.make 64 'B')
             ; "assignment", `Assoc [ "state", `String "missing" ]
             ] )
       ])

let test_runtime_picker_revision_decoder () =
  let missing_runtime =
    with_config_revision
      (`Assoc
         [ "manifest", `Assoc [ "state", `String "missing" ]
         ; ( "runtime_assignment"
           , `Assoc [ "state", `String "runtime_config_missing" ] )
         ])
  in
  (match expected_runtime_assignment_revision missing_runtime with
   | Ok (`Assoc [ ("state", `String "runtime_config_missing") ]) -> ()
   | Ok revision ->
     Alcotest.failf "unexpected runtime revision: %s"
       (Yojson.Safe.to_string revision)
   | Error detail -> Alcotest.fail detail);
  let malformed =
    with_config_revision
      (`Assoc
         [ "manifest", `Assoc [ "state", `String "missing" ]
         ; "runtime_assignment", `Assoc [ "state", `String "assigned" ]
         ])
  in
  match expected_runtime_assignment_revision malformed with
  | Error _ -> ()
  | Ok revision ->
    Alcotest.failf "runtime picker accepted malformed revision: %s"
      (Yojson.Safe.to_string revision)

let test_unchanged_runtime_assignment_response_decoder () =
  let valid =
    `Assoc
      [ "ok", `Bool true
      ; "applied", `Bool false
      ; ( "assignment_revision"
        , `Assoc [ "state", `String "runtime_config_missing" ] )
      ; "warnings", `List []
      ]
  in
  (match decode_unchanged_runtime_assignment_response valid with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  List.iter
    (fun malformed ->
      match decode_unchanged_runtime_assignment_response malformed with
      | Error _ -> ()
      | Ok revision ->
        Alcotest.failf "accepted malformed unchanged revision: %s"
          (Yojson.Safe.to_string revision))
    [ `Assoc [ "ok", `Bool true; "applied", `Bool false ]
    ; `Assoc
        [ "ok", `Bool true
        ; "applied", `Bool false
        ; ( "assignment_revision"
          , `Assoc [ "state", `String "runtime_config_present" ] )
        ; "warnings", `List []
        ]
    ; `Assoc
        [ "ok", `Bool true
        ; "applied", `Bool false
        ; ( "assignment_revision"
          , `Assoc [ "state", `String "runtime_config_missing" ] )
        ; "warnings", `List [ `Assoc [ "code", `String "missing-detail" ] ]
        ]
    ; `Assoc
        [ "ok", `Bool true
        ; "applied", `Bool false
        ; ( "assignment_revision"
          , `Assoc [ "state", `String "runtime_config_missing" ] )
        ; "warnings", `List []
        ; "extra", `Bool true
        ]
    ]

let test_runtime_config_warning_names_its_authority () =
  let revision =
    match observed with
    | `Assoc fields -> List.assoc "config_revision" fields
    | _ -> Alcotest.fail "observed fixture must be an object"
  in
  let response =
    `Assoc
      [ "runtime_sync", `String "lane_restarted"
      ; ( "config_write"
        , `Assoc
            [ "revision", revision
            ; "applied", `Bool true
            ; ( "warnings"
              , `List
                  [ `Assoc
                      [ "code", `String "runtime_config_parent_sync_unconfirmed"
                      ; "detail", `String "runtime parent fsync failed"
                      ]
                  ] )
            ] )
      ]
  in
  let severity, message =
    match config_write_status_message ~keeper_name:"alpha" response with
    | Ok status -> status
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check string) "warning severity" "error" severity;
  Alcotest.(check bool) "authority-neutral config wording" true
    (String.starts_with
       ~prefix:"alpha: settings applied with 1 config durability warning(s)"
       message);
  Alcotest.(check bool) "exact runtime warning code is visible" true
    (String.ends_with
       ~suffix:"runtime_config_parent_sync_unconfirmed"
       message);
  let malformed =
    `Assoc
      [ "runtime_sync", `String "lane_restarted"
      ; ( "config_write"
        , `Assoc
            [ "revision", revision
            ; "applied", `Bool true
            ; ( "warnings"
              , `List
                  [ `Assoc
                      [ "code", `String "runtime_config_parent_sync_unconfirmed"
                      ]
                  ] )
            ] )
      ]
  in
  match config_write_status_message ~keeper_name:"alpha" malformed with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "malformed config warning became clean success"

let test_deferred_runtime_sync_is_named_in_the_status () =
  let revision =
    match observed with
    | `Assoc fields -> List.assoc "config_revision" fields
    | _ -> Alcotest.fail "observed fixture must be an object"
  in
  let response runtime_sync =
    `Assoc
      (runtime_sync
       @ [ ( "config_write"
           , `Assoc
               [ "revision", revision
               ; "applied", `Bool true
               ; "warnings", `List []
               ] )
         ])
  in
  (match
     config_write_status_message ~keeper_name:"alpha"
       (response [ "runtime_sync", `String "deferred_until_turn_end" ])
   with
   | Error detail -> Alcotest.fail detail
   | Ok (severity, message) ->
     Alcotest.(check string) "deferral is not an error" "system" severity;
     Alcotest.(check bool) "deferral says when the settings apply" true
       (String.ends_with
          ~suffix:"(a turn is running; the next turn uses the new settings)"
          message));
  (match
     config_write_status_message ~keeper_name:"alpha"
       (response [ "runtime_sync", `String "failed" ])
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a refusal state became a success status");
  match config_write_status_message ~keeper_name:"alpha" (response []) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a success without runtime_sync was accepted"

let () =
  Alcotest.run "tui keeper config"
    [ ( "projection"
      , [ Alcotest.test_case "input policy patch" `Quick test_input_policy_patch
        ; Alcotest.test_case "observed editor stem" `Quick
            test_editor_starts_from_observed_values
        ; Alcotest.test_case "changed-only patch" `Quick
            test_patch_contains_only_changed_fields
        ; Alcotest.test_case "deleted means unchanged" `Quick
            test_deleted_field_means_unchanged
        ; Alcotest.test_case "skill selection modes" `Quick
            test_skill_selection_patch_modes
        ; Alcotest.test_case "context shrink confirmation reaches the patch"
            `Quick test_context_shrink_confirmation_reaches_the_patch
        ; Alcotest.test_case "reject unknown" `Quick
            test_unknown_field_is_rejected
        ; Alcotest.test_case "activation outside the set is an editor refusal" `Quick
            test_activation_outside_the_set_is_an_editor_refusal
        ; Alcotest.test_case "reopened stem parses and replaces" `Quick
            test_reopened_stem_parses_and_replaces
        ; Alcotest.test_case "missing revision is not an editor refusal" `Quick
            test_missing_revision_is_not_an_editor_refusal
        ; Alcotest.test_case "fetched text sanitized, frame not" `Quick
            test_fetched_text_is_sanitized_but_the_frame_is_not
        ; Alcotest.test_case "wrong-typed scalar is sanitized" `Quick
            test_invalid_mode_text_is_sanitized_at_the_row_boundary
        ; Alcotest.test_case "runtime picker refuses an unavailable revision" `Quick
            test_runtime_picker_refuses_unavailable_revision
        ; Alcotest.test_case "strict composite revision" `Quick
            test_strict_config_revision_decoder
        ; Alcotest.test_case "strict runtime picker revision" `Quick
            test_runtime_picker_revision_decoder
        ; Alcotest.test_case "strict unchanged assignment revision" `Quick
            test_unchanged_runtime_assignment_response_decoder
        ; Alcotest.test_case "runtime config warning authority" `Quick
            test_runtime_config_warning_names_its_authority
        ; Alcotest.test_case "deferred runtime sync status" `Quick
            test_deferred_runtime_sync_is_named_in_the_status
        ] )
    ]
