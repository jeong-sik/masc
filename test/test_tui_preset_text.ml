(* The exact lines /preset leaves in the chat pane. *)

open Alcotest
module D = Masc.Tui_decode
module Text = Masc_tui_preset_text

let morning : D.preset_manifest =
  { D.pm_name = "morning"
  ; pm_description = "before the campaign"
  ; pm_created_at = "2026-09-03T10:26:08Z"
  ; pm_override_count = 1
  ; pm_override_keys = [ "keeper" ]
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

(* The Config → Presets pane gives each detail row [cols - 6] cells. The
   older-format reason ends in what to do, so the pane must fold it rather
   than cut it: at 100 and 140 columns every row fits and the whole reason,
   recovery step included, is still on screen. *)
let test_unreadable_reason_is_folded_not_cut () =
  let name = "after-restart-20260903" in
  let reason =
    "prompt_overrides.json has schema_version 1 and this build reads only schema_version 2, so \
     this preset cannot be restored; set its prompts again and save them as a new preset"
  in
  let words s = String.split_on_char ' ' s |> List.filter (fun w -> w <> "") in
  List.iter
    (fun cols ->
      let max_cells = cols - 6 in
      let rows = Text.unreadable_rows ~max_cells [ name, reason ] in
      check bool (Printf.sprintf "%d cols: more than one row" cols) true (List.length rows > 1);
      List.iter
        (fun row ->
          check string
            (Printf.sprintf "%d cols: row fits in %d cells" cols max_cells)
            row
            (Masc_tui_message_layout.take_cells row max_cells))
        rows;
      check (list string)
        (Printf.sprintf "%d cols: every word of the reason is shown" cols)
        (words (Printf.sprintf "! %s — %s" name reason))
        (List.concat_map words rows))
    [ 100; 140 ]

let test_saved_line_carries_the_counts () =
  check string "saved" "saved preset morning — overrides 1 · keepers 2 · assignments 12 · lanes 4"
    (Text.saved_line morning)

let report ~skipped ~runtime : D.preset_restore_report =
  { D.prr_restored = "morning"
  ; prr_autosave = "_autosave"
  ; prr_prompt_overrides = { D.pp_effect = "immediate"; pp_applied = [ "keeper" ]; pp_skipped = skipped }
  ; prr_instructions = { D.pp_effect = "keeper_restart"; pp_applied = [ "analyst"; "spruce" ]; pp_skipped = [] }
  ; prr_runtime = runtime
  ; prr_default_prompts = Masc.Prompt_preset.Defaults_unknown
  }

let test_restore_lines_show_skips_and_the_runtime_outcome () =
  let clean = report ~skipped:[] ~runtime:D.Preset_runtime_committed in
  check (list string) "clean restore"
    [ "restored preset morning (the state before it is _autosave)"
    ; "prompt overrides (immediate): applied 1, skipped 0"
    ; "keeper instructions (keeper_restart): applied 2, skipped 0"
    ; "runtime: committed — runtime.toml rewritten, assignments and exact lanes live"
    ; "기본 프롬프트 · 저장된 비교 기준 없음"
    ]
    (Text.restore_lines clean);
  check bool "clean is clean" true (Text.restore_is_clean clean);
  let dirty =
    report
      ~skipped:[ "stale", "contract revision mismatch" ]
      ~runtime:(D.Preset_runtime_failed "invalid runtime TOML")
  in
  check (list string) "a skip and a failed commit are each their own line"
    [ "restored preset morning (the state before it is _autosave)"
    ; "prompt overrides (immediate): applied 1, skipped 1"
    ; "  - stale: contract revision mismatch"
    ; "keeper instructions (keeper_restart): applied 2, skipped 0"
    ; "runtime: failed — invalid runtime TOML"
    ; "기본 프롬프트 · 저장된 비교 기준 없음"
    ]
    (Text.restore_lines dirty);
  check bool "dirty is not clean" false (Text.restore_is_clean dirty);
  check bool "unchanged runtime is clean" true
    (Text.restore_is_clean (report ~skipped:[] ~runtime:D.Preset_runtime_unchanged))

let test_pane_row_and_detail () =
  check string "pane row" "morning                      overrides 1 · keepers 2 · assignments 12 · lanes 4  2026-09-03T10:26:08Z"
    (Text.pane_row morning);
  check (list string) "detail without a report"
    [ "Selected: morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
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
    [ "Selected: morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ; ""
    ; "내용을 읽는 중…"
    ]
    (Text.detail_lines ~selected:(Some morning) ~detail:Masc_tui_fetched.Loading
       ~report:None);
  check (list string) "a preset that overrides nothing says that"
    [ "Selected: morning · overrides 0 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override 없음"
    ; "지시문 analyst, spruce"
    ]
    (Text.detail_lines
       ~selected:
         (Some { morning with D.pm_override_keys = []; pm_override_count = 0 })
       ~detail:Masc_tui_fetched.Absent ~report:None);
  (* Once the server answers, the pane says what applying this would touch.
     Sizes, because the point is the decision and a 4 KB prompt does not fit
     in a pane. *)
  let contents : D.preset_detail =
    { D.pd_name = "morning"
    ; pd_directory = "/fixture/presets/morning"
    ; pd_settings_match = D.Preset_settings_match
    ; pd_default_prompts = Masc.Prompt_preset.Defaults_match
    ; pd_prompt_files = ["keeper", Some "/fixture/prompts/keeper.md", D.Prompt_override]
    ; pd_overrides = [ "keeper", 4431 ]
    ; pd_instructions = [ "analyst.toml", 812; "spruce.toml", 640 ]
    ; pd_assignments = [ "analyst", "glm-coding.glm-5.3" ]
    ; pd_lanes = [ "verifier_exact" ]
    }
  in
  check (list string) "the contents follow the manifest lines"
    [ "Selected: morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
    ; "before the campaign"
    ; "저장 시각 2026-09-03T10:26:08Z"
    ; "프롬프트 override keeper"
    ; "지시문 analyst, spruce"
    ; ""
    ; "설정 상태 · 저장 당시와 동일"
    ; "기본 프롬프트 · 저장 당시와 동일"
    ; ""
    ; "저장된 설정"
    ; "프롬프트 keeper(4431B)"
    ; "지시문 analyst.toml(812B), spruce.toml(640B)"
    ; "배정 analyst→glm-coding.glm-5.3"
    ; "레인 verifier_exact"
    ; ""
    ; "현재 프롬프트"
    ; "keeper · 사용자 설정"
    ; "  /fixture/prompts/keeper.md"
    ; ""
    ; "저장 위치"
    ; "  /fixture/presets/morning"
    ]
    (Text.detail_lines ~selected:(Some morning) ~detail:(Masc_tui_fetched.Ready contents) ~report:None);
  (* Matching the answer to the selection is the fetch type's job now, so
     what reaches here for a preset still in flight is simply Loading. *)
  check (list string) "a selection still in flight says so"
    [ "Selected: morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
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
    [ "Selected: morning · overrides 1 · keepers 2 · assignments 12 · lanes 4"
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

let test_decode_saved_settings_and_effective_prompt_sources () =
  let payload saved_settings = `Assoc
    [ "preset", `Assoc
        [ "name", `String "morning"; "prompt_overrides", `List []
        ; "instructions", `List []; "assignments", `List []; "lanes", `List [] ]
    ; "directory", `String "/fixture/presets/morning"
    ; "saved_settings", saved_settings
    ; "prompt_files", `List [`Assoc
        [ "key", `String "keeper"; "path", `String "/fixture/prompts/keeper.md"
        ; "source", `String "override" ]]
    ]
  in
  List.iter (fun (status, extra, expected) ->
    match D.decode_preset_detail (payload (`Assoc (("status", `String status) :: extra))) with
    | Error detail -> fail detail
    | Ok detail ->
        check string "saved directory" "/fixture/presets/morning" detail.pd_directory;
        check bool "comparison verdict is typed" true (detail.pd_settings_match = expected);
        check bool "live prompt source is separate from the comparison" true
          (detail.pd_prompt_files = ["keeper", Some "/fixture/prompts/keeper.md", D.Prompt_override]))
    [ "matches", [], D.Preset_settings_match
    ; "differs", [], D.Preset_settings_differ
    ; "unavailable", ["reason", `String "broken.toml"], D.Preset_settings_unavailable "broken.toml"
    ];
  check bool "an unavailable comparison must explain why" true
    (Result.is_error (D.decode_preset_detail (payload (`Assoc ["status", `String "unavailable"]))));
  check bool "unknown comparison status is rejected" true
    (Result.is_error (D.decode_preset_detail (payload (`Assoc ["status", `String "unknown"]))))

(* The pane's row where an empty list would be. It named [s], which on Config
   opens Resources, and it called a store of unreadable presets empty. *)
let test_pane_empty_line_names_the_save_key () =
  let empty = { D.pss_presets = []; pss_unreadable = [] } in
  let footer = Masc_tui_keys.footer_hints_config ~pane:Masc_tui_types.Config_presets in
  let has needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  check bool "the footer's save key is n" true (has "n:" footer);
  (match Text.pane_empty_line empty with
   | None -> fail "an empty store draws a row"
   | Some line ->
       check bool "the row names n" true (has "n 으로" line);
       check bool "and not s" false (has "s 로" line));
  check (option string) "unreadable presets are not an empty store"
    (Some "읽을 수 있는 프리셋이 없습니다 — 아래 줄이 이유입니다")
    (Text.pane_empty_line { D.pss_presets = []; pss_unreadable = [ "torn", "manifest.json missing" ] });
  check (option string) "a list draws no empty row" None
    (Text.pane_empty_line { D.pss_presets = [ morning ]; pss_unreadable = [] })

let test_default_drift_is_visible_without_failing_restore () =
  let before = String.make 64 'a' and after = String.make 64 'b' in
  let changes = ["keeper", Some before, Some after; "judge", None, Some after;
                 "removed", Some before, None] in
  let report = { (report ~skipped:[] ~runtime:D.Preset_runtime_unchanged) with
    D.prr_default_prompts = Masc.Prompt_preset.Defaults_differ changes } in
  check bool "default drift leaves restore successful" true (Text.restore_is_clean report);
  let lines = Text.restore_lines report in
  List.iter (fun line -> check bool "changed prompt is visible" true (List.mem line lines))
    ["기본 프롬프트 · 차이 3건"; "  변경 · keeper"; "  추가 · judge"; "  없음 · removed"];
  let part = `Assoc ["effect", `String "immediate"; "applied", `List []; "skipped", `List []] in
  let comparison = Masc.Prompt_preset.default_comparison_to_json report.D.prr_default_prompts in
  let payload defaults = `Assoc ["ok", `Bool true; "report", `Assoc
    ["restored", `String "morning"; "autosave", `String "_autosave";
     "prompt_overrides", part; "instructions", part;
     "runtime", `Assoc ["status", `String "unchanged"];
     "default_prompts", defaults]] in
  (match D.decode_preset_restore (payload comparison) with
   | Error message -> fail message
   | Ok decoded -> check bool "restore decodes default drift" true
       (decoded.D.prr_default_prompts = report.D.prr_default_prompts));
  let detail = `Assoc ["preset", `Assoc ["name", `String "morning"];
    "directory", `String "/fixture/presets/morning";
    "saved_settings", `Assoc ["status", `String "matches"];
    "prompt_files", `List []; "default_prompts", comparison] in
  (match D.decode_preset_detail detail with
   | Error message -> fail message
   | Ok decoded -> check bool "detail decodes the same drift" true
       (decoded.D.pd_default_prompts = report.D.prr_default_prompts));
  List.iter (fun malformed ->
    check bool "malformed comparison is refused" true
      (Result.is_error (D.decode_preset_restore (payload malformed))))
    [`Assoc ["status", `String "future"; "changes", `List []];
     `Assoc ["status", `String "differs"; "changes", `List []];
     `Assoc ["status", `String "matches"; "changes", `List [`Assoc
       ["key", `String "keeper"; "saved_sha256", `String before; "current_sha256", `String after]]]]

let () =
  run "Masc_tui_preset_text"
    [ ( "preset text"
      , [ test_case "default drift is visible and does not fail restoration" `Quick
            test_default_drift_is_visible_without_failing_restore
        ; test_case "listing names counts and unreadable rows" `Quick
            test_listing_names_counts_and_unreadable
        ; test_case "an unreadable reason is folded, not cut" `Quick
            test_unreadable_reason_is_folded_not_cut
        ; test_case "saved line carries the counts" `Quick test_saved_line_carries_the_counts
        ; test_case "restore lines show skips and the runtime outcome" `Quick
            test_restore_lines_show_skips_and_the_runtime_outcome
        ; test_case "pane row and detail lines" `Quick test_pane_row_and_detail
        ; test_case "pane empty line names the save key" `Quick
            test_pane_empty_line_names_the_save_key
        ; test_case "saved comparison and current effective source decode independently" `Quick
            test_decode_saved_settings_and_effective_prompt_sources
        ] )
    ]
