open Masc_tui_keeper_config

let observed =
  Yojson.Safe.from_string
    {|{
      "manifest_revision": {"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
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
        {|{"expected_manifest_revision":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"proactive_enabled":false}|}
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
    ~expected:{|{"expected_manifest_revision":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"skills":{"names":[]}}|};
  check_skill_patch ~label:"exact names" ~before:observed
    ~skills:(`Assoc [ "names", `List [ `String "review"; `String "research" ] ])
    ~expected:{|{"expected_manifest_revision":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"skills":{"names":["review","research"]}}|};
  let exact_before =
    with_observed_skill_names (`List [ `String "review" ])
  in
  check_skill_patch ~label:"all" ~before:exact_before ~skills:(`Assoc [])
    ~expected:{|{"expected_manifest_revision":{"state":"sha256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"skills":{}}|}

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
    ; "Wake prompt override", `Editable
    ; "Sandbox / network", `Editable
    ; "Allowed paths", `Editable
    ; "Mention targets", `Editable
    ; "Skills", `Editable
      (* the one row inside the settings block that [e] does not reach *)
    ; "Effective paths", `Read_only
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
        ] )
    ]
