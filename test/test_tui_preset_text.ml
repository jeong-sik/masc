(* The exact lines /preset leaves in the chat pane. *)

open Alcotest
module D = Masc.Tui_decode
module Text = Masc_tui_preset_text

let morning : D.preset_manifest =
  { D.pm_name = "morning"
  ; pm_description = "before the campaign"
  ; pm_created_at = "2026-09-03T10:26:08Z"
  ; pm_override_count = 1
  ; pm_keepers = [ "analyst"; "spruce" ]
  ; pm_assignment_count = 12
  ; pm_lane_count = 4
  }

let test_listing_names_counts_and_unreadable () =
  check (list string) "listing"
    [ "presets (1):"
    ; "  morning  overrides 1 · keepers 2 · assignments 12 · lanes 4 — before the campaign  (2026-09-03T10:26:08Z)"
    ; "  ! torn — manifest.json missing"
    ]
    (Text.listing_lines
       { D.pss_presets = [ morning ]; pss_unreadable = [ "torn", "manifest.json missing" ] });
  check (list string) "empty listing tells the operator how to save"
    [ "no presets yet — /preset save <name> [description] snapshots the live state" ]
    (Text.listing_lines { D.pss_presets = []; pss_unreadable = [] });
  check (list string) "unreadable rows are not an empty list"
    [ "읽을 수 있는 프리셋이 없습니다 — 아래 줄이 이유입니다"
    ; "  ! torn — manifest.json missing"
    ]
    (Text.listing_lines
       { D.pss_presets = []; pss_unreadable = [ "torn", "manifest.json missing" ] })

let test_saved_line_carries_the_counts () =
  check string "saved" "saved preset morning — overrides 1 · keepers 2 · assignments 12 · lanes 4"
    (Text.saved_line morning)

let report ~skipped ~runtime : D.preset_restore_report =
  { D.prr_restored = "morning"
  ; prr_autosave = "_autosave-20260903T103201Z"
  ; prr_prompt_overrides = { D.pp_effect = "immediate"; pp_applied = [ "keeper" ]; pp_skipped = skipped }
  ; prr_instructions = { D.pp_effect = "keeper_restart"; pp_applied = [ "analyst"; "spruce" ]; pp_skipped = [] }
  ; prr_runtime = runtime
  }

let test_restore_lines_show_skips_and_the_runtime_outcome () =
  let clean = report ~skipped:[] ~runtime:D.Preset_runtime_committed in
  check (list string) "clean restore"
    [ "restored preset morning (the state before it is _autosave-20260903T103201Z)"
    ; "prompt overrides (immediate): applied 1, skipped 0"
    ; "keeper instructions (keeper_restart): applied 2, skipped 0"
    ; "runtime: committed — runtime.toml rewritten, assignments and exact lanes live"
    ]
    (Text.restore_lines clean);
  check bool "clean is clean" true (Text.restore_is_clean clean);
  let dirty =
    report
      ~skipped:[ "stale", "contract revision mismatch" ]
      ~runtime:(D.Preset_runtime_failed "invalid runtime TOML")
  in
  check (list string) "a skip and a failed commit are each their own line"
    [ "restored preset morning (the state before it is _autosave-20260903T103201Z)"
    ; "prompt overrides (immediate): applied 1, skipped 1"
    ; "  - stale: contract revision mismatch"
    ; "keeper instructions (keeper_restart): applied 2, skipped 0"
    ; "runtime: failed — invalid runtime TOML"
    ]
    (Text.restore_lines dirty);
  check bool "dirty is not clean" false (Text.restore_is_clean dirty);
  check bool "unchanged runtime is clean" true
    (Text.restore_is_clean (report ~skipped:[] ~runtime:D.Preset_runtime_unchanged))

let test_pane_row_and_detail () =
  check string "pane row" "morning                      overrides 1 · keepers 2 · assignments 12 · lanes 4  2026-09-03T10:26:08Z"
    (Text.pane_row morning);
  check (list string) "detail without a report"
    [ "morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "지시문 analyst, spruce"
    ]
    (Text.detail_lines ~selected:(Some morning) ~report:None);
  check (list string) "no selection says so"
    [ "선택한 프리셋이 없습니다" ]
    (Text.detail_lines ~selected:None ~report:None);
  let with_report =
    Text.detail_lines ~selected:(Some morning)
      ~report:(Some (report ~skipped:[] ~runtime:D.Preset_runtime_committed))
  in
  check bool "the report follows the preset in the detail" true
    (List.exists (fun line -> line = "runtime: committed — runtime.toml rewritten, assignments and exact lanes live") with_report)

let () =
  run "Masc_tui_preset_text"
    [ ( "preset text"
      , [ test_case "listing names counts and unreadable rows" `Quick
            test_listing_names_counts_and_unreadable
        ; test_case "saved line carries the counts" `Quick test_saved_line_carries_the_counts
        ; test_case "restore lines show skips and the runtime outcome" `Quick
            test_restore_lines_show_skips_and_the_runtime_outcome
        ; test_case "pane row and detail lines" `Quick test_pane_row_and_detail
        ] )
    ]
