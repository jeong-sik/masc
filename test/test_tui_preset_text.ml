(* The exact lines /preset leaves in the chat pane. *)

open Alcotest
module D = Masc.Tui_decode
module Text = Masc_tui_preset_text
module Types = Masc_tui_types

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
  ; prr_preserved_lane_settings = []
  ; prr_skipped_lanes = []
  ; prr_skipped_assignments = []
  }

let test_restore_classifies_commit_warnings () =
  let commit : D.preset_runtime_commit =
    { prc_source_revision = String.make 64 'a'; prc_order = "1"
    ; prc_durability = Runtime.Durable; prc_lock_warnings = []
    ; prc_registry = D.Preset_registry_applied D.Preset_registry_runtime_bindings }
  in
  let committed commit = report ~skipped:[] ~runtime:(D.Preset_runtime_committed commit) in
  check bool "fully applied durable restore is clean" true
    (Text.restore_is_clean (committed commit));
  List.iter (fun warning ->
    check bool "committed warning requires attention" false (Text.restore_is_clean (committed warning)))
    [ { commit with prc_durability = Runtime.Durability_unconfirmed {detail="fsync EIO"} }
    ; { commit with prc_lock_warnings = [Runtime.Config_lock_release_unconfirmed "unlock EIO"] }
    ; { commit with prc_registry = D.Preset_registry_unpublished }
    ; { commit with prc_registry = D.Preset_registry_kept "invalid target" }
    ];
  check bool "a skipped surface requires attention" false
    (Text.restore_is_clean (report ~skipped:["keeper", "invalid override"]
      ~runtime:(D.Preset_runtime_committed commit)));
  check bool "failed runtime is not clean" false
    (Text.restore_is_clean (report ~skipped:[] ~runtime:(D.Preset_runtime_failed "invalid TOML")));
  check bool "unchanged runtime is clean" true
    (Text.restore_is_clean (report ~skipped:[] ~runtime:D.Preset_runtime_unchanged));
  check bool "a refused assignment requires attention even without a runtime write" false
    (Text.restore_is_clean { (report ~skipped:[] ~runtime:D.Preset_runtime_unchanged) with
      prr_skipped_assignments = ["analyst", "unknown Runtime"] })

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

let test_decode_preserved_and_skipped_lanes () =
  let preserved = `List [`Assoc ["lane", `String "verifier_exact"; "setting", `String "thinking"]] in
  let skipped = `List [`Assoc ["lane", `String "unconfigured_exact"; "reason", `String "not registered"]] in
  let part = `Assoc ["effect", `String "immediate"; "applied", `List []; "skipped", `List []] in
  let payload preserved = `Assoc ["ok", `Bool true; "report", `Assoc
    ["restored", `String "morning"; "autosave", `String "_autosave";
     "prompt_overrides", part; "instructions", part;
     "runtime", `Assoc ["effect", `String "runtime_commit"; "status", `String "unchanged"];
     "preserved_lane_settings", preserved; "skipped_lanes", skipped;
     "skipped_assignments", `List [`Assoc ["keeper", `String "analyst"; "reason", `String "unknown Runtime"]]]] in
  (match D.decode_preset_restore (payload preserved) with
   | Error message -> fail message
   | Ok decoded ->
      check bool "unrecorded settings are typed" true
        (decoded.D.prr_preserved_lane_settings = ["verifier_exact", D.Preset_thinking]);
      check bool "unavailable lanes keep their reason" true
        (decoded.D.prr_skipped_lanes = ["unconfigured_exact", "not registered"]);
      check bool "unavailable assignments keep their reason" true
        (decoded.D.prr_skipped_assignments = ["analyst", "unknown Runtime"]);
      check bool "a skipped lane requires attention" false (Text.restore_is_clean decoded));
  List.iter (fun invalid ->
    check bool "malformed preservation evidence is not dropped" true
      (Result.is_error (D.decode_preset_restore (payload invalid))))
    [`Null; `List [`Assoc ["lane", `String "verifier_exact"; "setting", `String "future_setting"]]]

let test_default_drift_is_visible_without_failing_restore () =
  let before = String.make 64 'a' and after = String.make 64 'b' in
  let changes = ["keeper", Some before, Some after; "judge", None, Some after;
                 "removed", Some before, None] in
  let report = { (report ~skipped:[] ~runtime:D.Preset_runtime_unchanged) with
    D.prr_default_prompts = Masc.Prompt_preset.Defaults_differ changes } in
  check bool "default drift leaves restore successful" true (Text.restore_is_clean report);
  let lines = Text.restore_lines ~ko:true report in
  List.iter (fun line -> check bool "changed prompt is visible" true (List.mem line lines))
    ["기본 프롬프트 · 차이 3건"; "  변경 · keeper"; "  추가 · judge"; "  없음 · removed"];
  let part = `Assoc ["effect", `String "immediate"; "applied", `List []; "skipped", `List []] in
  let comparison = Masc.Prompt_preset.default_comparison_to_json report.D.prr_default_prompts in
  let payload defaults = `Assoc ["ok", `Bool true; "report", `Assoc
    ["restored", `String "morning"; "autosave", `String "_autosave";
     "prompt_overrides", part; "instructions", part;
     "runtime", `Assoc ["effect", `String "runtime_commit"; "status", `String "unchanged"];
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

let preset_identity base : D.server_identity =
  { sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None
  ; sid_base_path = D.Canonical_path.of_path base
  ; sid_masc_root = D.Canonical_path.of_path (base ^ "/.masc")
  ; sid_executable_in_worktree = None; sid_state_ready = Some true
  ; sid_uptime = None; sid_sse_clients = None; sid_gc = None; sid_scheduler = None
  }

let preset_state () =
  Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()

let preset_pending (state : Types.state) identity ?chat_input name : Types.preset_save_pending =
  { psp_token = ref ()
  ; psp_workspace = Types.workspace_input_identity_of_server (Some identity)
  ; psp_name = name; psp_description = "description"; psp_chat_input = chat_input
  ; psp_authority = state.workspace_authority; psp_reading = state.workspace_read_authority
  ; psp_host = "localhost"; psp_port = state.port
  ; psp_phase = Atomic.make Types.Preset_save_preparing
  ; psp_pane_observer = None; psp_chat_observers = []
  }

let test_save_receipts_remain_with_their_workspace () =
  let state = preset_state () in
  let a = preset_identity "/fixture/preset-a" and b = preset_identity "/fixture/preset-b" in
  let command_a = "/preset save Long " ^ String.make 9000 'a' in
  let command_b = "/preset save Other other workspace" in
  let unknown_a = preset_pending state a ~chat_input:"/preset save Foo earlier" "Foo" in
  let unsent_a = preset_pending state a ~chat_input:command_a "Long" in
  let unsent_b = preset_pending state b ~chat_input:command_b "Other" in
  state.server_identity <- Some a;
  state.preset_save_receipts <-
    [ { Types.psr_request = unknown_a; psr_result = Error (Types.Preset_save_unconfirmed "timeout"); psr_visible = true }
    ; { Types.psr_request = unsent_a; psr_result = Error (Types.Preset_save_not_sent "offline"); psr_visible = true }
    ; { Types.psr_request = unsent_b; psr_result = Error (Types.Preset_save_auth_retry_not_sent "offline"); psr_visible = false }
    ];
  Types.dismiss_latest_preset_save_receipt state;
  Types.dismiss_latest_preset_save_receipt state;
  check int "A's notices can be hidden" 0 (List.length (Types.visible_preset_save_receipts state));
  check bool "hiding does not remove the case-alias overwrite guard" true
    (Types.preset_save_is_unconfirmed state " foo ");
  check (list (pair string string)) "A's hidden, definitely unsent command remains recoverable"
    ["Long", command_a] (Types.recoverable_preset_save_commands state);
  state.server_identity <- Some b;
  check bool "A's unknown save does not guard B" false
    (Types.preset_save_is_unconfirmed state "foo");
  check (list (pair string string)) "B sees only its own unsent command"
    ["Other", command_b] (Types.recoverable_preset_save_commands state);
  state.server_identity <- Some a;
  Types.reveal_unsent_preset_save_receipts state;
  check int "A can reopen its hidden unsent receipt" 1
    (List.length (Types.visible_preset_save_receipts state));
  Types.reveal_unconfirmed_preset_save state "FOO";
  check int "A can reopen its unknown receipt by case alias" 2
    (List.length (Types.visible_preset_save_receipts state));
  state.server_identity <- Some b;
  check int "reopening A's notices does not reveal B's" 0
    (List.length (Types.visible_preset_save_receipts state));
  Types.reveal_unsent_preset_save_receipts state;
  check int "B can independently reopen its unsent receipt" 1
    (List.length (Types.visible_preset_save_receipts state))

let test_pending_saves_follow_workspace_and_name () =
  let state = preset_state () in
  let a = preset_identity "/fixture/preset-a" and b = preset_identity "/fixture/preset-b" in
  state.preset_save_pending <- [preset_pending state a "Foo"; preset_pending state b "Bar"];
  state.server_identity <- Some a;
  check bool "A finds its pending case alias" true (Types.preset_save_is_pending state "foo");
  check bool "A does not acquire B's pending save" false (Types.preset_save_is_pending state "bar");
  state.server_identity <- Some b;
  check bool "B does not acquire A's pending save" false (Types.preset_save_is_pending state "foo");
  check bool "B finds its own pending case alias" true (Types.preset_save_is_pending state "BAR");
  state.server_identity <- Some a;
  check bool "A's pending save is still guarded on return" true
    (Types.preset_save_is_pending state "FOO")

let test_confirmation_requires_contiguous_current_frames () =
  let state = preset_state () in
  let a = preset_identity "/fixture/preset-a" and b = preset_identity "/fixture/preset-b" in
  let token = ref () in
  let arm = Types.Save_armed "Foo" in
  state.view <- Types.Config;
  state.config_pane <- Types.Config_presets;
  state.server_identity <- Some a;
  state.preset_save_draft <- Some "Foo";
  state.preset_armed <- Some arm;
  state.preset_confirmation_token <- Some token;
  let frame : Types.preset_confirmation_frame =
    { pcf_token = token; pcf_arm = arm; pcf_cols = 80; pcf_language = state.ui_language
    ; pcf_description = ""; pcf_source = Types.Preset_form_local
    ; pcf_authority = state.workspace_authority; pcf_reading = state.workspace_read_authority
    ; pcf_workspace = Types.workspace_input_identity_of_server state.server_identity
    ; pcf_count = 9; pcf_first = 0; pcf_last = 3 }
  in
  let seen () = match state.preset_confirmation_presented with
    | Some progress -> progress.pcp_seen_through
    | None -> fail "no confirmation frame was recorded" in
  check bool "the first frame must be presented" true
    (Types.preset_confirmation_needs_present state frame);
  Types.record_preset_confirmation_frame state frame;
  check int "first rows recorded" 3 (seen ());
  check bool "the same range does not need another presentation" false
    (Types.preset_confirmation_needs_present state frame);
  let tail = { frame with pcf_first = 6; pcf_last = 9 } in
  check bool "a changed range needs presentation" true
    (Types.preset_confirmation_needs_present state tail);
  Types.record_preset_confirmation_frame state tail;
  check int "jumping to the end does not cover skipped rows" 3 (seen ());
  Types.record_preset_confirmation_frame state { frame with pcf_first = 3; pcf_last = 6 };
  check int "filling the gap does not retroactively cover the tail" 6 (seen ());
  Types.record_preset_confirmation_frame state tail;
  check int "the tail counts after the gap is covered" 9 (seen ());
  state.workspace_read_authority <- ref ();
  let renewed = { frame with pcf_reading = state.workspace_read_authority } in
  check bool "a new reading owner needs a new presentation" true
    (Types.preset_confirmation_needs_present state renewed);
  Types.record_preset_confirmation_frame state renewed;
  check int "a new reading owner cannot reuse the old coverage" 3 (seen ());
  state.preset_confirmation_presented <- None;
  Types.record_preset_confirmation_frame state frame;
  check bool "a stale reading owner cannot record a frame" true
    (Option.is_none state.preset_confirmation_presented);
  Types.record_preset_confirmation_frame state renewed;
  check int "a frame under the new reading owner starts again" 3 (seen ());
  state.preset_confirmation_presented <- None;
  state.workspace_authority <- Types.Workspace_authority 42;
  Types.record_preset_confirmation_frame state renewed;
  check bool "a stale workspace authority cannot record a frame" true
    (Option.is_none state.preset_confirmation_presented);
  state.workspace_authority <- frame.pcf_authority;
  state.server_identity <- Some b;
  Types.record_preset_confirmation_frame state renewed;
  check bool "a frame cannot record under a different workspace" true
    (Option.is_none state.preset_confirmation_presented)

let () =
  run "Masc_tui_preset_text"
    [ ( "preset text"
      , [ test_case "default drift is visible and does not fail restoration" `Quick
            test_default_drift_is_visible_without_failing_restore
        ; test_case "restore classifies commit warnings" `Quick
            test_restore_classifies_commit_warnings
        ; test_case "saved comparison and current effective source decode independently" `Quick
            test_decode_saved_settings_and_effective_prompt_sources
        ; test_case "preserved request settings and skipped lanes retain typed evidence" `Quick
            test_decode_preserved_and_skipped_lanes
        ; test_case "save receipts remain with their workspace" `Quick
            test_save_receipts_remain_with_their_workspace
        ; test_case "pending saves follow workspace and name" `Quick
            test_pending_saves_follow_workspace_and_name
        ; test_case "confirmation requires contiguous current frames" `Quick
            test_confirmation_requires_contiguous_current_frames
        ] )
    ]
