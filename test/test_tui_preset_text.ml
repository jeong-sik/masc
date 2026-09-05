(* The exact lines /preset leaves in the chat pane. *)

open Alcotest
module D = Masc.Tui_decode
module Text = Masc_tui_preset_text

let morning : D.preset_manifest =
  { D.pm_name = "morning"
  ; pm_description = "before the campaign"
  ; pm_created_at = "2026-09-03T10:26:08Z"
  ; pm_override_count = 1
  ; pm_override_keys = Some [ "keeper" ]
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
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ]
    (Text.detail_lines ~selected:(Some morning) ~detail:Masc_tui_fetched.Absent ~report:None);
  (* Selected and asked for. Saying so beats a pane that looks complete while
     the interesting half is still in flight -- and this is the state the old
     option pair had no way to reach. *)
  check (list string) "a selection being read says so"
    [ "morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ; ""
    ; "내용을 읽는 중…"
    ]
    (Text.detail_lines ~selected:(Some morning) ~detail:Masc_tui_fetched.Loading
       ~report:None);
  (* A preset saved before the server named its overrides must not read as
     one that overrides nothing. *)
  check (list string) "an older preset says the keys are unknown"
    [ "morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override 1개 — 어느 것인지는 이 프리셋에 적혀 있지 않습니다"
    ; "지시문 analyst, spruce"
    ]
    (Text.detail_lines
       ~selected:(Some { morning with D.pm_override_keys = None })
       ~detail:Masc_tui_fetched.Absent ~report:None);
  check (list string) "and one that truly overrides nothing says that"
    [ "morning · overrides 0 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override 없음"
    ; "지시문 analyst, spruce"
    ]
    (Text.detail_lines
       ~selected:
         (Some { morning with D.pm_override_keys = Some []; pm_override_count = 0 })
       ~detail:Masc_tui_fetched.Absent ~report:None);
  (* Once the server answers, the pane says what applying this would touch.
     Sizes, because the point is the decision and a 4 KB prompt does not fit
     in a pane. *)
  let contents : D.preset_detail =
    { D.pd_name = "morning"
    ; pd_overrides = [ "keeper", 4431 ]
    ; pd_instructions = [ "analyst.toml", 812; "spruce.toml", 640 ]
    ; pd_assignments = [ "analyst", "glm-coding.glm-5.3" ]
    ; pd_lanes = [ "verifier_exact" ]
    }
  in
  check (list string) "the contents follow the manifest lines"
    [ "morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ; ""
    ; "override keeper(4431B)"
    ; "지시문 analyst.toml(812B), spruce.toml(640B)"
    ; "배정 analyst→glm-coding.glm-5.3"
    ; "레인 verifier_exact"
    ]
    (Text.detail_lines ~selected:(Some morning) ~detail:(Masc_tui_fetched.Ready contents) ~report:None);
  (* Matching the answer to the selection is the fetch type's job now, so
     what reaches here for a preset still in flight is simply Loading. *)
  check (list string) "a selection still in flight says so"
    [ "morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ; ""
    ; "내용을 읽는 중…"
    ]
    (Text.detail_lines
       ~selected:(Some morning)
       ~detail:Masc_tui_fetched.Loading
       ~report:None);
  (* The state that did not exist before: the pane could say nothing when a
     read failed, so a failure looked the same as a preset with no contents. *)
  check (list string) "a failed read says why"
    [ "morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ; ""
    ; "내용을 읽지 못했습니다 — preset detail load failed: connection refused"
    ]
    (Text.detail_lines
       ~selected:(Some morning)
       ~detail:
         (Masc_tui_fetched.Failed "preset detail load failed: connection refused")
       ~report:None);
  check (list string) "no selection says so"
    [ "선택한 프리셋이 없습니다" ]
    (Text.detail_lines ~selected:None ~detail:Masc_tui_fetched.Absent ~report:None);
  let with_report =
    Text.detail_lines ~selected:(Some morning) ~detail:Masc_tui_fetched.Absent
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
