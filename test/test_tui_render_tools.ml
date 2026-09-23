(* The Tools pane strip says which pane is open. The key that changes it is the
   footer's, which draws from the key table. The strip said it too, and said it
   in the other language the screen uses: "p:다음 탭" under a footer reading
   "p:section". One key, two labels, one screen. *)

open Masc_tui_types

let contains needle haystack =
  let n = String.length needle in
  let rec seek i =
    i + n <= String.length haystack
    && (String.equal (String.sub haystack i n) needle || seek (i + 1))
  in
  seek 0

let make_state () =
  create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

let test_the_strip_names_panes_and_leaves_the_key_to_the_footer () =
  let strip = Masc_tui_render_tools.tools_pane_strip ~cols:120 (make_state ()) in
  List.iter
    (fun pane ->
      Alcotest.(check bool)
        (Printf.sprintf "the strip names the %s pane" pane)
        true (contains pane strip))
    [ "호출 범위"; "비동기 작업"; "Skill 기록"; "사용 집계"; "전체 도구" ];
  Alcotest.(check bool) "and advertises no key of its own" false
    (contains "p:" strip);
  Alcotest.(check bool) "which the footer does instead" true
    (contains "p:section" (Masc_tui_keys.footer_hints Tools))

(* The strip is the shared in-screen drawing: the open pane marked, two cells
   between names. It kept a bar between them after every other strip dropped
   it. *)
let test_the_strip_is_the_shared_drawing () =
  Alcotest.(check string) "the open pane marked, two cells apart"
    "\xe2\x96\xb8호출 범위  비동기 작업  Skill 기록  Skill 사용 집계  전체 도구"
    (Masc_tui_theme.strip_sgr
       (Masc_tui_render_tools.tools_pane_strip ~cols:120 (make_state ())))

(* The Keeper surface line says which of the two missing readings it is. It
   said "not loaded" under a failed inventory read. *)
let test_the_surface_line_tells_a_failed_read_from_an_unread_one () =
  let surface_line state =
    Masc_tui_render_tools.tools_display_lines state
    |> List.map snd
    |> List.find_opt (contains "Effective Keeper Surface")
    |> Option.value ~default:""
  in
  let unread = make_state () in
  Alcotest.(check string) "unread" " Effective Keeper Surface (not loaded)"
    (surface_line unread);
  let failed = make_state () in
  failed.tools_error <- Some "tool inventory load failed: HTTP 503";
  Alcotest.(check string) "failed" " Effective Keeper Surface (load failed)"
    (surface_line failed)

(* A Skill name the profile selected that the turn catalog does not hold is a
   different fact from a document that failed to read: nothing was read badly,
   the selection simply matched nothing. The producer sends it as its own list
   (`unavailable_skill_names`, Keeper_effective_tool_surface.to_yojson) and the
   dashboard draws it under "Unavailable Skills"
   (dashboard/src/components/tools/skill-activation-panel.ts) -- this screen
   said nothing, so the two renderers of one surface disagreed about whether
   the operator is told. The JSON below is the wire shape, run through the
   decoder the live loader uses, so the test fails if either end moves. *)
let surface_with ~unavailable_skill_names =
  `Assoc
    [ "status", `String "available"
    ; "keeper_name", `String "surface-fixture-keeper"
    ; "runtime_id", `String "runtime-fixture"
    ; "official_client_kind", `String "none"
    ; "tool_delivery", `Assoc [ "status", `String "delivered" ]
    ; "skill_snapshot_revision", `String "rev-1"
    ; "skill_discovery_bytes", `Int 0
    ; "skill_eager_body_bytes", `Int 0
    ; "skills_left_out", `List []
    ; "instruction_skills", `List []
    ; "composition_skills", `List []
    ; "unavailable_skill_names", `List unavailable_skill_names
    ; "tools", `List []
    ]

let tools_snapshot ~effective =
  `Assoc
    [ "generated_at", `String "2026-09-23T11:00:00Z"
    ; "config_resolution", `Assoc []
    ; "runtime_resolution", `Assoc []
    ; ( "tool_inventory"
      , `Assoc
          [ "count", `Int 0
          ; "tools", `List []
          ; "surface_summary", `Assoc []
          ] )
    ; "tool_usage", `Assoc []
    ; "effective_keeper_surface", effective
    ; "skill_activations", `Null
    ]

let state_showing ~unavailable_skill_names =
  let state = make_state () in
  (match
     Masc.Tui_decode.decode_tool_snapshot
       (tools_snapshot ~effective:(surface_with ~unavailable_skill_names))
   with
   | Ok snapshot -> state.tools_inventory <- Some snapshot
   | Error detail -> Alcotest.failf "decode failed: %s" detail);
  state

let surface_text state =
  Masc_tui_render_tools.tools_display_lines state
  |> List.map snd
  |> String.concat "\n"

let test_the_screen_names_a_configured_skill_that_is_not_there () =
  let shown =
    surface_text
      (state_showing
         ~unavailable_skill_names:
           [ `Assoc
               [ "name", `String "browser-lanes"
               ; "reason", `String "not_in_turn_skill_catalog"
               ] ])
  in
  Alcotest.(check bool) "the selected name is on the screen" true
    (contains "browser-lanes" shown);
  Alcotest.(check bool) "with the producer's reason beside it" true
    (contains "not_in_turn_skill_catalog" shown);
  (* A reader that fills in a reason speaks for a producer that said nothing,
     so an entry without one draws the name alone rather than a guess. *)
  let reasonless =
    surface_text
      (state_showing
         ~unavailable_skill_names:[ `Assoc [ "name", `String "solo-name" ] ])
  in
  Alcotest.(check bool) "a reasonless entry still names the skill" true
    (contains "solo-name" reasonless);
  Alcotest.(check bool) "and invents no reason for it" false
    (contains "not_in_turn_skill_catalog" reasonless);
  (* Without this the block could be drawn unconditionally and both checks
     above would still pass, so a healthy surface would gain a heading that
     claims something it has no entry for. *)
  let healthy = surface_text (state_showing ~unavailable_skill_names:[]) in
  Alcotest.(check bool) "a healthy surface gains no row" false
    (contains "not in the turn catalog" healthy)

(* When two sources declare one name the earlier one wins, and the later
   package is published but listed to no Keeper turn by that name (RFC
   keeper-self-authored-skills). The Skill usage pane draws the catalog's
   rejections; the shadows beside them in the same snapshot were decoded and
   dropped, so the operator the RFC leaves to settle a shadow could not see
   one. The payload is the server's snapshot shape, run through the decoder
   the live loader uses. *)
let skill_identity ~source_id name =
  `Assoc
    [ "source_id", `String source_id
    ; "package_id", `String name
    ; "name", `String name
    ]

let skills_catalog_with ~shadows =
  `Assoc
    [ "schema", `String "masc.skill-snapshot/v1"
    ; "state", `String "ready"
    ; "usage_coverage", `Assoc [ "ledgers_loaded", `Int 0; "unavailable", `List [] ]
    ; ( "snapshot"
      , `Assoc
          [ "snapshot_revision", `String "snapshot-rev"
          ; "catalog_revision", `String "catalog-rev"
          ; "config", `Assoc [ "kind", `String "unreadable" ]
          ; "sources", `List []
          ; "skills", `List []
          ; "effective_skills", `List []
          ; "shadows", `List shadows
          ; "rejections", `List []
          ] )
    ; "surfaces", `List []
    ]

let usage_pane_lines ~shadows =
  let state = make_state () in
  (match Masc.Tui_decode.decode_skills_catalog (skills_catalog_with ~shadows) with
   | Ok catalog -> state.skills_catalog <- Some catalog
   | Error detail -> Alcotest.failf "decode failed: %s" detail);
  state.tools_pane <- Tools_usage;
  Masc_tui_render_tools.tools_display_lines state |> List.map snd

let index_of needle haystack =
  let n = String.length needle in
  let rec seek i =
    if i + n > String.length haystack then None
    else if String.equal (String.sub haystack i n) needle then Some i
    else seek (i + 1)
  in
  seek 0

let test_the_usage_pane_names_both_sides_of_a_shadow () =
  let winner = "project-masc/shared" and shadowed = "project-agents/shared" in
  let lines =
    usage_pane_lines
      ~shadows:
        [ `Assoc
            [ "winner", skill_identity ~source_id:"project-masc" "shared"
            ; "shadowed", skill_identity ~source_id:"project-agents" "shared"
            ] ]
  in
  (match List.filter (contains shadowed) lines with
   | [ row ] ->
     (* The row reads like a rejection row: the package that is out first,
        then the one Keepers see instead. *)
     (match index_of shadowed row, index_of winner row with
      | Some shadowed_at, Some winner_at ->
        Alcotest.(check bool) "the winner follows the shadowed package" true
          (shadowed_at < winner_at)
      | None, _ | _, None -> Alcotest.failf "the row does not name both: %S" row)
   | rows ->
     Alcotest.failf "expected one row naming the shadowed package, got %d"
       (List.length rows));
  (* The pane scrolls, so a shadow costs rows only there: its heading and
     one line, and a catalog without shadows gains nothing. *)
  let healthy = usage_pane_lines ~shadows:[] in
  Alcotest.(check int) "one heading and one row per shadow"
    (List.length healthy + 2) (List.length lines)

let () =
  Alcotest.run "masc_tui_render_tools"
    [ ( "pane strip"
      , [ Alcotest.test_case "panes here, the key in the footer" `Quick
            test_the_strip_names_panes_and_leaves_the_key_to_the_footer
        ; Alcotest.test_case "the surface line tells failed from unread" `Quick
            test_the_surface_line_tells_a_failed_read_from_an_unread_one
        ; Alcotest.test_case "the shared strip drawing" `Quick
            test_the_strip_is_the_shared_drawing
        ; Alcotest.test_case
            "the screen names a configured skill that is not there" `Quick
            test_the_screen_names_a_configured_skill_that_is_not_there
        ; Alcotest.test_case "the usage pane names both sides of a shadow" `Quick
            test_the_usage_pane_names_both_sides_of_a_shadow
        ] )
    ]
