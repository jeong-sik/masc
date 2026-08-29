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
      "autoboot_enabled": true,
      "max_context_override": null,
      "sandbox_profile": "docker",
      "network_mode": "none",
      "sandbox_roots": ["repo-a", ".masc/playground/alpha/"],
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
        {|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"proactive_enabled":false}|}
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
    ~expected:{|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"skills":{"names":[]}}|};
  check_skill_patch ~label:"exact names" ~before:observed
    ~skills:(`Assoc [ "names", `List [ `String "review"; `String "research" ] ])
    ~expected:{|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"skills":{"names":["review","research"]}}|};
  let exact_before =
    with_observed_skill_names (`List [ `String "review" ])
  in
  check_skill_patch ~label:"all" ~before:exact_before ~skills:(`Assoc [])
    ~expected:{|{"expected_config_revision":{"manifest":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"runtime_assignment":{"state":"runtime_config_present","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","assignment":{"state":"assigned","runtime_id":"codex_subscription.gpt-5.6-sol"}}},"skills":{}}|}

let rendered_of json = view_lines ~sanitize:Fun.id json |> String.concat "\n"

let contains haystack needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern haystack 0);
    true
  with Not_found -> false

let editable_glyph = "\xe2\x97\x8f"
let read_only_glyph = "\xe2\x97\x8b"

let row_of json label =
  String.split_on_char '\n' (rendered_of json)
  (* The title is wrapped in its own styling, so a trailing space is not part
     of the match. First hit wins: every label is drawn before any free text. *)
  |> List.find_opt (fun line -> contains line label)
  |> function
  | None -> Alcotest.fail ("row not drawn: " ^ label)
  | Some line -> line

let test_skill_selection_view_modes () =
  (* The row now carries a marker and its own styling, so the assertion is on
     the value the Skills row shows rather than on the whole line. *)
  let check label expected json =
    Alcotest.(check bool) label true (contains (row_of json "Skills") expected)
  in
  check "all" "all published Skills" observed;
  check "none" "none" (with_observed_skill_names (`List []));
  check "exact names" "review, research"
    (with_observed_skill_names (`List [ `String "review"; `String "research" ]))

let test_unknown_field_is_rejected () =
  match
    patch_of_edit ~before:observed ~after:(`Assoc [ "mystery", `Bool true ])
  with
  | Ok _ -> Alcotest.fail "unknown field was accepted"
  | Error detail ->
      Alcotest.(check string) "actionable error"
        "unknown keeper setting(s): mystery" detail

let test_view_explains_effective_values_and_sources () =
  let rendered = rendered_of observed in
  List.iter
    (fun needle -> Alcotest.(check bool) needle true (contains rendered needle))
    [ "effective settings"
    ; "codex_subscription.gpt-5.6-sol"
    ; "docker / none"
    ; "provenance"
    ; "/config/keepers/alpha.toml"
    ; "Only changed fields are sent"
      (* the raw block the named provenance rows do not exhaust *)
    ; "\"live_meta_path\": \"/state/keepers/alpha.json\""
    ]

(* The pane's whole job is answering "will [e] change this?" per row. A row
   that loses its marker, or a derived value that gains an editable one, is
   the defect this fixes. *)
let test_every_row_says_whether_e_reaches_it () =
  let name = function `Editable -> "editable" | `Read_only -> "read-only" in
  List.iter
    (fun (label, expected) ->
      let line = row_of observed label in
      let actual =
        if contains line editable_glyph then `Editable
        else if contains line read_only_glyph then `Read_only
        else Alcotest.fail ("row carries no marker: " ^ label)
      in
      Alcotest.(check string) label (name expected) (name actual))
    [ "Runtime", `Editable
    ; "Autoboot", `Editable
    ; "Autonomous turns", `Editable
    ; "Context override", `Editable
    ; "Sandbox / network", `Editable
    ; "Mention targets", `Editable
    ; "Skills", `Editable
      (* the rows inside the settings block that [e] does not reach *)
    ; "Config revision", `Read_only
    ; "Sandbox roots", `Read_only
    ; "Live override", `Read_only
    ; "Override fields", `Read_only
    ; "Precedence", `Read_only
    ; "Default manifest", `Read_only
    ; "Live metadata", `Read_only
      (* the pair the operator could not tell apart before *)
    ; "instructions", `Editable
    ; "effective system prompt", `Read_only
    ]

(* The heading counts the editor stem, not the rows: two fields share the
   sandbox row and one row is derived, so a row count would disagree with
   what [e] opens. *)
let test_heading_counts_what_the_editor_opens () =
  let expected =
    match editable_snapshot observed with
    | `Assoc fields -> List.length fields
    | _ -> Alcotest.fail "expected object"
  in
  Alcotest.(check bool)
    (Printf.sprintf "heading says e opens %d fields" expected)
    true
    (contains (rendered_of observed) (Printf.sprintf "e opens %d fields" expected))

(* A stored field ends with a newline. Counting the empty line it splits into
   made the heading disagree with what the reader could see. *)
let test_line_count_matches_what_is_drawn () =
  let json = Yojson.Safe.from_string {|{"prompt": {"instructions": "one\ntwo\n"}}|} in
  let lines = view_lines ~sanitize:Fun.id json in
  Alcotest.(check bool)
    "heading says 2 lines"
    true
    (contains (String.concat "\n" lines) "editable \xc2\xb7 2 lines");
  Alcotest.(check bool)
    "no blank body line drawn"
    false
    (List.exists (fun line -> String.equal line "   ") lines)

(* Fetched text reaches the frame through the caller's sanitizer; the frame's
   own styling must not go through it. *)
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

let test_wrong_typed_scalar_is_sanitized_at_the_row_boundary () =
  let hostile =
    Yojson.Safe.from_string
      {|{"autoboot_enabled": "before\u001b]8;;https://example.invalid\u0007after"}|}
  in
  let rendered =
    view_lines
      ~sanitize:(fun text -> String.concat "<esc>" (String.split_on_char '\027' text))
      hostile
    |> String.concat "\n"
  in
  Alcotest.(check bool)
    "wrong-typed fallback was sanitized"
    true
    (contains rendered "before<esc>]8;;https://example.invalid")

let with_config_revision revision =
  match observed with
  | `Assoc fields ->
    `Assoc (("config_revision", revision) :: List.remove_assoc "config_revision" fields)
  | _ -> Alcotest.fail "observed fixture must be an object"

let test_config_revision_projection_assigned () =
  let row = row_of observed "Config revision" in
  List.iter
    (fun expected ->
      Alcotest.(check bool) expected true (contains row expected))
    [ "manifest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ; "runtime=present"
    ; "source=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ; "assignment=assigned:codex_subscription.gpt-5.6-sol"
    ]

let test_config_revision_projection_assignment_missing () =
  let revision =
    `Assoc
      [ ( "manifest"
        , `Assoc
            [ "state", `String "sha256"
            ; "value", `String (String.make 64 'a')
            ] )
      ; ( "runtime_assignment"
        , `Assoc
            [ "state", `String "runtime_config_present"
            ; "source_revision", `String (String.make 64 'b')
            ; "assignment", `Assoc [ "state", `String "missing" ]
            ] )
      ]
  in
  let row = row_of (with_config_revision revision) "Config revision" in
  Alcotest.(check bool) "runtime source is present" true
    (contains row "runtime=present source=sha256:");
  Alcotest.(check bool) "assignment is explicitly missing" true
    (contains row "assignment=missing")

(* The server answers {state:"unavailable", detail} in place of the revision
   pair when it could not read it. The pane shows the server's own detail,
   and the CAS picker refuses to post the marker as an expected value. *)
let test_config_revision_projection_unavailable_shows_detail () =
  let revision =
    `Assoc
      [ "state", `String "unavailable"
      ; "detail", `String "manifest store offline"
      ]
  in
  let row = row_of (with_config_revision revision) "Config revision" in
  Alcotest.(check bool) "server detail is on the row" true
    (contains row "revision unavailable: manifest store offline")

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

let test_config_revision_projection_runtime_missing () =
  let revision =
    `Assoc
      [ "manifest", `Assoc [ "state", `String "missing" ]
      ; ( "runtime_assignment"
        , `Assoc [ "state", `String "runtime_config_missing" ] )
      ]
  in
  let row = row_of (with_config_revision revision) "Config revision" in
  Alcotest.(check bool) "manifest is explicitly missing" true
    (contains row "manifest=missing");
  Alcotest.(check bool) "runtime config is explicitly missing" true
    (contains row "runtime=missing")

let test_config_revision_projection_rejects_malformed_runtime () =
  let revision =
    `Assoc
      [ "manifest", `Assoc [ "state", `String "missing" ]
      ; ( "runtime_assignment"
        , `Assoc
            [ "state", `String "runtime_config_present"
            ; "source_revision", `String (String.make 64 'B')
            ; "assignment", `Assoc [ "state", `String "missing" ]
            ] )
      ]
  in
  let row = row_of (with_config_revision revision) "Config revision" in
  Alcotest.(check bool) "malformed runtime invalidates the full product" true
    (contains row "invalid composite config revision");
  Alcotest.(check bool) "manifest-only success is not rendered" false
    (contains row "manifest=missing")

let changed_proactive =
  `Assoc [ "proactive_enabled", `Bool false ]

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
      [ ( "config_write"
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
      [ ( "config_write"
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
        ; Alcotest.test_case "every row marks editability" `Quick
            test_every_row_says_whether_e_reaches_it
        ; Alcotest.test_case "heading counts the editor stem" `Quick
            test_heading_counts_what_the_editor_opens
        ; Alcotest.test_case "line count matches what is drawn" `Quick
            test_line_count_matches_what_is_drawn
        ; Alcotest.test_case "fetched text sanitized, frame not" `Quick
            test_fetched_text_is_sanitized_but_the_frame_is_not
        ; Alcotest.test_case "wrong-typed scalar is sanitized" `Quick
            test_wrong_typed_scalar_is_sanitized_at_the_row_boundary
        ; Alcotest.test_case "composite revision assigned" `Quick
            test_config_revision_projection_assigned
        ; Alcotest.test_case "composite revision assignment missing" `Quick
            test_config_revision_projection_assignment_missing
        ; Alcotest.test_case "composite revision runtime missing" `Quick
            test_config_revision_projection_runtime_missing
        ; Alcotest.test_case "unavailable revision shows the server detail" `Quick
            test_config_revision_projection_unavailable_shows_detail
        ; Alcotest.test_case "runtime picker refuses an unavailable revision" `Quick
            test_runtime_picker_refuses_unavailable_revision
        ; Alcotest.test_case "composite revision malformed runtime" `Quick
            test_config_revision_projection_rejects_malformed_runtime
        ; Alcotest.test_case "strict composite revision" `Quick
            test_strict_config_revision_decoder
        ; Alcotest.test_case "strict runtime picker revision" `Quick
            test_runtime_picker_revision_decoder
        ; Alcotest.test_case "strict unchanged assignment revision" `Quick
            test_unchanged_runtime_assignment_response_decoder
        ; Alcotest.test_case "runtime config warning authority" `Quick
            test_runtime_config_warning_names_its_authority
        ] )
    ]
