(* Tier K4 — Keeper_tool_emission_hook unit tests.

   Coverage:
   - feature flag respected (off → no-op, on → captures)
   - PostToolUse: Ok content parses → accumulator grows
   - PostToolUse: Error tool_result → ignored
   - non-JSON content → silently ignored (no exception)
   - non-PostToolUse events → ignored
   - drain empties accumulator
   - install_into_hooks chain preserves original decision *)

module H = Masc_mcp.Keeper_tool_emission_hook
module THooks = Agent_sdk.Hooks
module TT = Agent_sdk.Types

let dummy_schedule : THooks.tool_schedule =
  {
    planned_index = 0;
    batch_index = 0;
    batch_size = 1;
    concurrency_class = "default";
    batch_kind = "sequential";
  }

let with_env_set name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name value;
  let restore () =
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally:restore f

let with_env_unset name f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name "";
  let restore () =
    match prev with
    | Some v -> Unix.putenv name v
    | None -> ()
  in
  Fun.protect ~finally:restore f

let make_post_tool_use ~content : THooks.hook_event =
  THooks.PostToolUse
    { tool_use_id = "tu-1"
    ; tool_name = "fake_tool"
    ; input = `Assoc []
    ; output = Ok ({ TT.content } : TT.tool_output)
    ; result_bytes = String.length content
    ; duration_ms = 1.0
    ; schedule = dummy_schedule
    }

let make_pre_tool_use () : THooks.hook_event =
  THooks.PreToolUse
    { tool_use_id = "tu-1"
    ; tool_name = "fake_tool"
    ; input = `Assoc []
    ; accumulated_cost_usd = 0.0
    ; turn = 1
    ; schedule = dummy_schedule
    }

let make_post_tool_use_error () : THooks.hook_event =
  THooks.PostToolUse
    { tool_use_id = "tu-2"
    ; tool_name = "broken_tool"
    ; input = `Assoc []
    ; output =
        Error
          ({ TT.message = "boom"
           ; recoverable = true
           ; error_class = None
           } : TT.tool_error)
    ; result_bytes = 0
    ; duration_ms = 0.5
    ; schedule = dummy_schedule
    }

let assert_eq_int ~label expected actual =
  if expected <> actual then (
    Printf.printf "FAIL [%s]: expected %d actual %d\n" label
      expected actual;
    exit 1)

let test_disabled_no_op () =
  with_env_unset "MASC_TOOL_EMISSION" (fun () ->
      assert (not (H.masc_tool_emission_enabled ()));
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      let event =
        make_post_tool_use
          ~content:
            {|{"__multimodal_kind":"code","__multimodal_id":"01900000-0000-7000-8000-000000000001","source":"x"}|}
      in
      let _ : THooks.hook_decision = hook event in
      assert_eq_int ~label:"disabled_no_capture" 0
        (H.accumulator_size acc));
  print_endline "  disabled_no_op: OK"

let test_enabled_captures_post_tool_use () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      assert (H.masc_tool_emission_enabled ());
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      let event =
        make_post_tool_use
          ~content:
            {|{"__multimodal_kind":"code","__multimodal_id":"01900000-0000-7000-8000-000000000001","source":"x"}|}
      in
      let _ : THooks.hook_decision = hook event in
      assert_eq_int ~label:"enabled_capture" 1
        (H.accumulator_size acc));
  print_endline "  enabled_captures_post_tool_use: OK"

let test_error_tool_result_ignored () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      let _ : THooks.hook_decision =
        hook (make_post_tool_use_error ())
      in
      assert_eq_int ~label:"error_ignored" 0
        (H.accumulator_size acc));
  print_endline "  error_tool_result_ignored: OK"

let test_non_json_content_ignored () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      let event =
        make_post_tool_use ~content:"not actually json {{{"
      in
      let _ : THooks.hook_decision = hook event in
      assert_eq_int ~label:"non_json_ignored" 0
        (H.accumulator_size acc));
  print_endline "  non_json_content_ignored: OK"

let test_other_events_ignored () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      let _ : THooks.hook_decision = hook (make_pre_tool_use ()) in
      assert_eq_int ~label:"pre_tool_use_ignored" 0
        (H.accumulator_size acc));
  print_endline "  other_events_ignored: OK"

let test_drain_empties_accumulator () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      let _ : THooks.hook_decision =
        hook
          (make_post_tool_use
             ~content:
               {|{"__multimodal_kind":"code","__multimodal_id":"01900000-0000-7000-8000-000000000010","source":"x"}|})
      in
      let _ : THooks.hook_decision =
        hook
          (make_post_tool_use
             ~content:
               {|{"__multimodal_kind":"image","__multimodal_id":"01900000-0000-7000-8000-000000000011","data_url":"data:..."}|})
      in
      assert_eq_int ~label:"size_before_drain" 2
        (H.accumulator_size acc);
      let new_wc =
        H.drain_into_working_context acc ~working_context:None
      in
      (* Both items had reserved keys → both flow through. *)
      let raws, _ =
        Multimodal.Wirein_helpers.extract_raw_artifacts new_wc
      in
      assert_eq_int ~label:"emitted_raws" 2 (List.length raws);
      assert_eq_int ~label:"size_after_drain" 0
        (H.accumulator_size acc));
  print_endline "  drain_empties_accumulator: OK"

let test_drain_skips_untagged () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      let hook = H.make_post_tool_use_hook acc in
      (* tagged *)
      let _ : THooks.hook_decision =
        hook
          (make_post_tool_use
             ~content:
               {|{"__multimodal_kind":"doc","__multimodal_id":"01900000-0000-7000-8000-000000000020","body":"# t"}|})
      in
      (* untagged — captured but skipped by Tool_emission *)
      let _ : THooks.hook_decision =
        hook
          (make_post_tool_use
             ~content:{|{"echo":"hello","ts":12345}|})
      in
      let new_wc =
        H.drain_into_working_context acc ~working_context:None
      in
      let raws, _ =
        Multimodal.Wirein_helpers.extract_raw_artifacts new_wc
      in
      assert_eq_int ~label:"only_tagged_emitted" 1
        (List.length raws));
  print_endline "  drain_skips_untagged: OK"

let test_install_chain_preserves_decision () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      (* original hook returns Skip; chain must surface Skip. *)
      let original : THooks.hook =
        fun _ -> THooks.Skip
      in
      let hooks = { THooks.empty with post_tool_use = Some original } in
      let combined = H.install_into_hooks acc hooks in
      let chained = Option.get combined.post_tool_use in
      let event =
        make_post_tool_use
          ~content:
            {|{"__multimodal_kind":"code","__multimodal_id":"01900000-0000-7000-8000-000000000030","source":"x"}|}
      in
      let decision = chained event in
      assert (decision = THooks.Skip);
      (* side effect: K4 hook must still capture into accumulator. *)
      assert_eq_int ~label:"chained_capture" 1
        (H.accumulator_size acc));
  print_endline "  install_chain_preserves_decision: OK"

let test_install_no_existing_hook () =
  with_env_set "MASC_TOOL_EMISSION" "1" (fun () ->
      let acc = H.create_accumulator () in
      let hooks = THooks.empty in
      let combined = H.install_into_hooks acc hooks in
      let chained = Option.get combined.post_tool_use in
      let event =
        make_post_tool_use
          ~content:
            {|{"__multimodal_kind":"audio","__multimodal_id":"01900000-0000-7000-8000-000000000040","wav":"r"}|}
      in
      let decision = chained event in
      assert (decision = THooks.Continue);
      assert_eq_int ~label:"installed_capture" 1
        (H.accumulator_size acc));
  print_endline "  install_no_existing_hook: OK"

let () =
  print_endline "=== Keeper_tool_emission_hook ===";
  test_disabled_no_op ();
  test_enabled_captures_post_tool_use ();
  test_error_tool_result_ignored ();
  test_non_json_content_ignored ();
  test_other_events_ignored ();
  test_drain_empties_accumulator ();
  test_drain_skips_untagged ();
  test_install_chain_preserves_decision ();
  test_install_no_existing_hook ();
  print_endline "=== Keeper_tool_emission_hook: 9/9 OK ==="
