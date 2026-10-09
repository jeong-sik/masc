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
        ; test_case "restore lines show skips and the runtime outcome" `Quick
            test_restore_lines_show_skips_and_the_runtime_outcome
        ; test_case "saved comparison and current effective source decode independently" `Quick
            test_decode_saved_settings_and_effective_prompt_sources
        ] )
    ]
