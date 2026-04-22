open Alcotest

module KEC = Masc_mcp.Keeper_exec_context
module KCC = Masc_mcp.Keeper_context_core
module KMP = Masc_mcp.Keeper_memory_policy
module KT = Masc_mcp.Keeper_types
module KR = Masc_mcp.Keeper_registry
module KST = Masc_mcp.Keeper_state_machine

let ctx_messages = KEC.messages_of_context
let ctx_system_prompt = KEC.system_prompt_of_context

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let base_lifecycle ~(meta : KT.keeper_meta) : KEC.post_turn_lifecycle =
  {
    updated_meta = meta;
    checkpoint = None;
    handoff_json = None;
    handoff_attempted = false;
    handoff_failure_reason = None;
    compaction =
      {
        attempted = false;
        applied = false;
        failure_reason = None;
        trigger = None;
        decision = "skipped:test";
        before_tokens = 0;
        after_tokens = 0;
        saved_tokens = 0;
      };
    turn_generation = meta.runtime.generation;
    context_ratio = 0.0;
    context_tokens = 0;
    context_max = 0;
    message_count = 0;
  }

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > hay_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let tool_use_message ?(name = "list_files") ~tool_use_id () =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
    content =
      [
        Agent_sdk.Types.ToolUse
          { id = tool_use_id; name; input = `Assoc [] };
      ];
    name = None;
    tool_call_id = None; metadata = [];
  }

let tool_result_message ?(is_error = false) ~tool_use_id content =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.Tool;
    content =
      [
        Agent_sdk.Types.ToolResult
          { tool_use_id; content; is_error; json = None };
      ];
    name = None;
    tool_call_id = None; metadata = [];
  }

let tool_result_content_for_id ~tool_use_id msgs =
  List.find_map
    (fun (msg : Agent_sdk.Types.message) ->
      List.find_map
        (function
          | Agent_sdk.Types.ToolResult { tool_use_id = id; content; _ }
            when String.equal id tool_use_id -> Some content
          | _ -> None)
        msg.content)
    msgs

let has_tool_use_id ~tool_use_id msgs =
  List.exists
    (fun (msg : Agent_sdk.Types.message) ->
      List.exists
        (function
          | Agent_sdk.Types.ToolUse { id; _ } ->
              String.equal id tool_use_id
          | _ -> false)
        msg.content)
    msgs

let make_keeper_meta ?(name = "keeper-lifecycle-test")
    ?(trace_id = "trace-keeper-lifecycle") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let append_turn ctx idx =
  let payload = String.make 160 'x' in
  KEC.append ctx
    (Agent_sdk.Types.user_msg
       (Printf.sprintf "turn %02d user %s" idx payload))
  |> fun next ->
  KEC.append next
    (Agent_sdk.Types.assistant_msg
       (Printf.sprintf "turn %02d assistant %s" idx payload))

let build_dense_context ~turns ~max_tokens ~state_reply =
  let rec loop idx ctx =
    if idx > turns then ctx else loop (idx + 1) (append_turn ctx idx)
  in
  let ctx = loop 1 (KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens) in
  KEC.append ctx (Agent_sdk.Types.assistant_msg state_reply)
  |> KEC.sync_oas_context

let save_checkpoint ~base_dir ~(meta : KT.keeper_meta) ~ctx =
  let session =
    KEC.create_session ~session_id:(Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
  in
  match KEC.save_oas_checkpoint
    ~max_checkpoint_messages:120
    ~session
    ~agent_name:meta.agent_name
    ~model:"llama:auto"
    ~ctx
    ~generation:meta.runtime.generation
  with
  | Ok cp -> cp
  | Error e -> Alcotest.fail (Printf.sprintf "save_oas_checkpoint failed: %s" e)

let load_context ~base_dir ~trace_id ~max_tokens =
  let (_session, loaded_opt) =
    KEC.load_context_from_checkpoint
      ~max_checkpoint_messages:120
      ~trace_id
      ~primary_model_max_tokens:max_tokens
      ~base_dir
  in
  loaded_opt

let test_apply_post_turn_lifecycle_without_checkpoint_records_skip () =
  let base_dir = temp_dir "keeper_lifecycle_none" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta = make_keeper_meta () in
      let lifecycle =
        KEC.apply_post_turn_lifecycle
          ~on_compaction_started:(fun () -> ())
          ~on_handoff_started:(fun () -> ())
          ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:512
          ~current_turn_overflow_blocker:None
          ~checkpoint:None
      in
      check bool "compaction not attempted" false lifecycle.compaction.attempted;
      check (option string) "compaction no failure" None
        lifecycle.compaction.failure_reason;
      check bool "handoff not attempted" false lifecycle.handoff_attempted;
      check bool "compaction not applied" false lifecycle.compaction.applied;
      check string "skip decision" "skipped:no_checkpoint"
        lifecycle.compaction.decision;
      check string "runtime decision persisted" "skipped:no_checkpoint"
        lifecycle.updated_meta.runtime.compaction_rt.last_decision;
      check bool "last check ts recorded" true
        (lifecycle.updated_meta.runtime.compaction_rt.last_check_ts > 0.0);
      check int "turn generation unchanged" meta.runtime.generation
        lifecycle.turn_generation)

let test_load_context_prefers_live_primary_max_tokens_over_checkpoint_limit () =
  let base_dir = temp_dir "keeper_lifecycle_live_limit" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta = make_keeper_meta ~trace_id:"trace-live-limit" () in
      let ctx =
        build_dense_context ~turns:4 ~max_tokens:4096
          ~state_reply:"[STATE]\nGoal: test\nProgress: saved\n[/STATE]"
      in
      let checkpoint = save_checkpoint ~base_dir ~meta ~ctx in
      check int "stored checkpoint max preserved in checkpoint helper" 4096
        (KEC.checkpoint_max_tokens checkpoint ~fallback:32768);
      match
        load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~max_tokens:32768
      with
      | Some loaded ->
          check int "restore uses live primary max tokens" 32768
            (KEC.max_tokens_of_context loaded)
      | None -> fail "expected checkpoint context to load")

let test_apply_post_turn_lifecycle_compacts_and_updates_continuity () =
  let base_dir = temp_dir "keeper_lifecycle_compact" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let now_ts = Time_compat.now () in
      let meta =
        let base = make_keeper_meta () in
        {
          base with
          auto_handoff = false;
          compaction =
            {
              base.compaction with
              ratio_gate = 0.0;
              message_gate = 2;
              token_gate = 1;
              cooldown_sec = 0;
            };
          runtime =
            {
              base.runtime with
              last_continuity_update_ts = now_ts -. 60.0;
            };
        }
      in
      let state_reply =
        "ready\n\n[STATE]\nGoal: preserve continuity\nProgress: compacted\n[/STATE]"
      in
      let original_ctx =
        build_dense_context ~turns:24 ~max_tokens:320 ~state_reply
      in
      let _original_message_count = List.length (ctx_messages original_ctx) in
      let checkpoint = save_checkpoint ~base_dir ~meta ~ctx:original_ctx in
      let compaction_started = ref 0 in
      let lifecycle =
        KEC.apply_post_turn_lifecycle
          ~on_handoff_started:(fun () -> ())
          ~base_dir ~meta
          ~on_compaction_started:(fun () -> incr compaction_started)
          ~model:"llama:auto"
          ~primary_model_max_tokens:320
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      check int "compaction start hook called once" 1 !compaction_started;
      check bool "compaction attempted" true lifecycle.compaction.attempted;
      check (option string) "compaction no failure" None
        lifecycle.compaction.failure_reason;
      check bool "compaction applied" true lifecycle.compaction.applied;
      check bool "saved tokens positive" true (lifecycle.compaction.saved_tokens > 0);
      check int "compaction count increments" 1
        lifecycle.updated_meta.runtime.compaction_rt.count;
      check int "last before tokens recorded" lifecycle.compaction.before_tokens
        lifecycle.updated_meta.runtime.compaction_rt.last_before_tokens;
      check int "last after tokens recorded" lifecycle.compaction.after_tokens
        lifecycle.updated_meta.runtime.compaction_rt.last_after_tokens;
      check bool "continuity summary captured" true
        (contains_substring lifecycle.updated_meta.continuity_summary
           "Goal: preserve continuity");
      check bool "continuity ts updated" true
        (lifecycle.updated_meta.runtime.last_continuity_update_ts > 0.0);
      let progress_path =
        Filename.concat
          (Filename.concat (Filename.concat (Filename.dirname base_dir) "keepers") meta.name)
          "progress.md"
      in
      check bool "progress log written" true (Sys.file_exists progress_path);
      let progress_body = Fs_compat.load_file progress_path in
      check bool "progress log keeps goal" true
        (contains_substring progress_body "Goal: preserve continuity");
      check bool "progress log is forward-looking" false
        (contains_substring progress_body "Done:");
      match
        load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string lifecycle.updated_meta.runtime.trace_id)
          ~max_tokens:320
      with
      | Some loaded ->
          check bool "compacted checkpoint persisted" true
            (List.length (ctx_messages loaded) < _original_message_count)
      | None -> fail "expected compacted checkpoint to be persisted")

let test_apply_post_turn_lifecycle_keeps_checkpoint_when_compaction_skips () =
  let base_dir = temp_dir "keeper_lifecycle_skip_compaction" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let meta =
        let base = make_keeper_meta ~trace_id:"trace-lifecycle-skip" () in
        {
          base with
          auto_handoff = false;
          compaction =
            {
              base.compaction with
              ratio_gate = 1.0;
              message_gate = 0;
              token_gate = 0;
              cooldown_sec = 0;
            };
          runtime =
            {
              base.runtime with
              last_continuity_update_ts = 1.0;
            };
        }
      in
      let original_ctx =
        build_dense_context ~turns:2 ~max_tokens:4096
          ~state_reply:
            "done\n\n[STATE]\nGoal: keep checkpoint\nProgress: stable\n[/STATE]"
      in
      let original_count = List.length (ctx_messages original_ctx) in
      let checkpoint = save_checkpoint ~base_dir ~meta ~ctx:original_ctx in
      let lifecycle =
        KEC.apply_post_turn_lifecycle
          ~on_compaction_started:(fun () -> ())
          ~on_handoff_started:(fun () -> ())
          ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:4096
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      check bool "compaction not attempted" false lifecycle.compaction.attempted;
      check bool "compaction skipped" false lifecycle.compaction.applied;
      check string "skip decision recorded" "blocked:below_thresholds"
        lifecycle.compaction.decision;
      match
        load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string lifecycle.updated_meta.runtime.trace_id)
          ~max_tokens:4096
      with
      | Some loaded ->
          check int "checkpoint messages preserved" original_count
            (List.length (ctx_messages loaded))
      | None -> fail "expected original checkpoint to remain available")

let test_apply_post_turn_lifecycle_handoffs_after_compaction () =
  let base_dir = temp_dir "keeper_lifecycle_handoff" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let now_ts = Time_compat.now () in
      let meta =
        let base = make_keeper_meta ~trace_id:"trace-lifecycle-source" () in
        {
          base with
          auto_handoff = true;
          handoff_threshold = 0.0;
          handoff_cooldown_sec = 0;
          compaction =
            {
              base.compaction with
              ratio_gate = 0.0;
              message_gate = 2;
              token_gate = 1;
              cooldown_sec = 0;
            };
          runtime =
            {
              base.runtime with
              last_continuity_update_ts = now_ts -. 60.0;
            };
        }
      in
      let checkpoint =
        build_dense_context ~turns:18 ~max_tokens:256
          ~state_reply:
            "done\n\n[STATE]\nGoal: roll over safely\nProgress: ready\n[/STATE]"
        |> fun ctx -> save_checkpoint ~base_dir ~meta ~ctx
      in
      let compaction_started = ref 0 in
      let handoff_started = ref 0 in
      let lifecycle =
        KEC.apply_post_turn_lifecycle ~base_dir ~meta
          ~on_compaction_started:(fun () -> incr compaction_started)
          ~on_handoff_started:(fun () -> incr handoff_started)
          ~model:"llama:auto"
          ~primary_model_max_tokens:256
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      check int "compaction start hook called once" 1 !compaction_started;
      check int "handoff start hook called once" 1 !handoff_started;
      check bool "compaction attempted" true lifecycle.compaction.attempted;
      check bool "handoff attempted" true lifecycle.handoff_attempted;
      check (option string) "handoff no failure" None
        lifecycle.handoff_failure_reason;
      check bool "compaction applied before handoff" true
        lifecycle.compaction.applied;
      check bool "handoff emitted" true (Option.is_some lifecycle.handoff_json);
      check int "turn generation remains pre-handoff generation" 0
        lifecycle.turn_generation;
      check int "meta generation advanced" 1
        lifecycle.updated_meta.runtime.generation;
      check bool "trace rotated" true
        (lifecycle.updated_meta.runtime.trace_id <> meta.runtime.trace_id);
      check bool "previous trace stored in history" true
        (List.mem (Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id) lifecycle.updated_meta.runtime.trace_history);
      (match lifecycle.handoff_json with
       | Some handoff ->
           let open Yojson.Safe.Util in
           check (option int) "new_generation field present" (Some 1)
             (handoff |> member "new_generation" |> to_int_option);
           check (option int) "to_generation field present" (Some 1)
             (handoff |> member "to_generation" |> to_int_option)
       | None -> fail "expected handoff json");
      match
        load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string lifecycle.updated_meta.runtime.trace_id)
          ~max_tokens:256
      with
      | Some loaded ->
          check bool "new trace checkpoint exists" true
            (List.length (ctx_messages loaded) > 0)
      | None -> fail "expected rollover checkpoint in new trace")

let test_apply_post_turn_lifecycle_handoffs_on_current_turn_overflow_signal ()
    =
  let base_dir = temp_dir "keeper_lifecycle_overflow_signal_handoff" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let meta =
        let base = make_keeper_meta ~trace_id:"trace-overflow-signal" () in
        {
          base with
          auto_handoff = true;
          handoff_threshold = 0.85;
          handoff_cooldown_sec = 0;
          compaction =
            {
              base.compaction with
              ratio_gate = 1.0;
              message_gate = 0;
              token_gate = 0;
              cooldown_sec = 0;
            };
        }
      in
      let checkpoint =
        KEC.create ~system_prompt:"stable" ~max_tokens:4096
        |> fun ctx ->
        KEC.append ctx
          (Agent_sdk.Types.user_msg "short checkpoint")
        |> KEC.sync_oas_context
        |> fun ctx -> save_checkpoint ~base_dir ~meta ~ctx
      in
      let lifecycle =
        KEC.apply_post_turn_lifecycle ~base_dir ~meta
          ~on_compaction_started:(fun () -> ())
          ~on_handoff_started:(fun () -> ())
          ~model:"llama:auto"
          ~primary_model_max_tokens:4096
          ~current_turn_overflow_blocker:
            (Some "Invalid request: Prompt exceeds max length")
          ~checkpoint:(Some checkpoint)
      in
      check bool "ratio stays below threshold" true
        (lifecycle.context_ratio < meta.handoff_threshold);
      check bool "handoff attempted" true lifecycle.handoff_attempted;
      check bool "handoff emitted" true (Option.is_some lifecycle.handoff_json);
      check int "generation advanced" 1
        lifecycle.updated_meta.runtime.generation)

let test_rollover_aborts_on_save_failure () =
  let base_dir = temp_dir "keeper_lifecycle_rollover_abort" in
  Fun.protect
    ~finally:(fun () ->
      (* Restore write permissions for cleanup *)
      (try Unix.chmod base_dir 0o755 with _ -> ());
      cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let now_ts = Time_compat.now () in
      let original_trace = "trace-rollover-abort" in
      let meta =
        let base = make_keeper_meta ~trace_id:original_trace () in
        {
          base with
          auto_handoff = true;
          handoff_threshold = 0.0;
          handoff_cooldown_sec = 0;
          compaction =
            {
              base.compaction with
              ratio_gate = 1.0;
              message_gate = 0;
              token_gate = 0;
              cooldown_sec = 0;
            };
          runtime =
            {
              base.runtime with
              last_continuity_update_ts = now_ts -. 60.0;
            };
        }
      in
      let ctx =
        build_dense_context ~turns:10 ~max_tokens:256
          ~state_reply:
            "done\n\n[STATE]\nGoal: test abort\nProgress: saved\n[/STATE]"
      in
      let checkpoint = save_checkpoint ~base_dir ~meta ~ctx in
      (* Make base_dir read-only so new session dir creation fails *)
      Unix.chmod base_dir 0o555;
      let handoff_started = ref 0 in
      let rollover =
        KEC.maybe_rollover_oas_handoff
          ~on_started:(fun () -> incr handoff_started)
          ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:256
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      (* Restore permissions before assertions *)
      Unix.chmod base_dir 0o755;
      check int "handoff start hook called once" 1 !handoff_started;
      check bool "handoff attempted" true rollover.attempted;
      check bool "handoff failure recorded" true
        (Option.is_some rollover.failure_reason);
      check bool "handoff NOT emitted on save failure" false
        (Option.is_some rollover.handoff_json);
      check string "trace_id unchanged" original_trace
        (Masc_mcp.Keeper_id.Trace_id.to_string rollover.updated_meta.runtime.trace_id);
      check int "generation unchanged" 0
        rollover.updated_meta.runtime.generation)

let test_recover_latest_checkpoint_for_overflow_retry_compacts_oas_checkpoint () =
  let base_dir = temp_dir "keeper_lifecycle_overflow_retry_oas" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let meta = make_keeper_meta ~trace_id:"trace-overflow-retry-oas" () in
      let original_ctx =
        build_dense_context ~turns:22 ~max_tokens:4096
          ~state_reply:
            "done\n\n[STATE]\nGoal: retry after overflow\nProgress: ready\n[/STATE]"
      in
      ignore (save_checkpoint ~base_dir ~meta ~ctx:original_ctx);
      match
        KEC.recover_latest_checkpoint_for_overflow_retry ~base_dir ~meta
          ~model:"llama:auto" ~primary_model_max_tokens:256
      with
      | Some recovery ->
          check bool "compaction applied" true recovery.compaction.applied;
          check bool "saved tokens positive" true
            (recovery.compaction.saved_tokens > 0);
          (match
             load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id)
               ~max_tokens:256
          with
          | Some loaded ->
              check int "checkpoint max tokens clamped" 256
                (KEC.max_tokens_of_context loaded);
          | None -> fail "expected compacted OAS checkpoint")
      | None -> fail "expected overflow retry recovery from OAS checkpoint")

let test_recover_latest_checkpoint_for_overflow_retry_uses_legacy_checkpoint () =
  let base_dir = temp_dir "keeper_lifecycle_overflow_retry_legacy" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let meta = make_keeper_meta ~trace_id:"trace-overflow-retry-legacy" () in
      let session =
        KEC.create_session ~session_id:(Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
      in
      let legacy_ctx =
        build_dense_context ~turns:18 ~max_tokens:2048
          ~state_reply:
            "done\n\n[STATE]\nGoal: recover legacy checkpoint\nProgress: ready\n[/STATE]"
      in
      ignore (KEC.save_checkpoint session legacy_ctx ~generation:3);
      match
        KEC.recover_latest_checkpoint_for_overflow_retry ~base_dir ~meta
          ~model:"llama:auto" ~primary_model_max_tokens:192
      with
      | Some recovery ->
          check int "legacy generation preserved" 3 recovery.turn_generation;
          check bool "legacy recovery compacts" true recovery.compaction.applied;
          (match
             load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id)
               ~max_tokens:192
           with
          | Some loaded ->
              check int "legacy retry max tokens clamped" 192
                (KEC.max_tokens_of_context loaded);
          | None -> fail "expected compacted checkpoint after legacy recovery")
      | None -> fail "expected overflow retry recovery from legacy checkpoint")

let test_recover_latest_checkpoint_for_overflow_retry_ignores_checkpoint_system_prompt_in_history_budget () =
  let base_dir = temp_dir "keeper_lifecycle_overflow_retry_system_prompt" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let meta = make_keeper_meta ~trace_id:"trace-overflow-retry-system-prompt" () in
      let long_system_prompt = String.make 4000 's' in
      let original_ctx =
        let rec loop idx ctx =
          if idx > 20 then ctx else loop (idx + 1) (append_turn ctx idx)
        in
        let ctx =
          loop 1
            (KEC.create ~system_prompt:long_system_prompt ~max_tokens:4096)
        in
        KEC.append ctx
          (Agent_sdk.Types.assistant_msg
             "done\n\n[STATE]\nGoal: retry despite large system prompt\nProgress: ready\n[/STATE]")
        |> KEC.sync_oas_context
      in
      ignore (save_checkpoint ~base_dir ~meta ~ctx:original_ctx);
      match
        KEC.recover_latest_checkpoint_for_overflow_retry ~base_dir ~meta
          ~model:"llama:auto" ~primary_model_max_tokens:512
      with
      | Some _ ->
          (match
             load_context ~base_dir ~trace_id:(Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id)
               ~max_tokens:512
           with
          | Some loaded ->
              check int "history retry max tokens clamped" 512
                (KEC.max_tokens_of_context loaded);
          | None -> fail "expected overflow retry checkpoint to be saved")
      | None ->
          fail
            "expected overflow retry recovery to keep message history within budget even with a large checkpoint system prompt")

let test_recover_latest_checkpoint_for_overflow_retry_repairs_orphan_tool_result () =
  let base_dir = temp_dir "keeper_lifecycle_overflow_retry_orphan" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let trace_id = "trace-overflow-retry-orphan" in
      let meta = make_keeper_meta ~trace_id () in
      let orphan_id = "call-overflow-orphan" in
      let dense_ctx =
        build_dense_context ~turns:22 ~max_tokens:4096
          ~state_reply:
            "done\n\n[STATE]\nGoal: repair orphan on overflow retry\nProgress: ready\n[/STATE]"
      in
      let checkpoint = save_checkpoint ~base_dir ~meta ~ctx:dense_ctx in
      let checkpoint =
        { checkpoint with
          messages =
            {
              Agent_sdk.Types.role = Agent_sdk.Types.Tool;
              content =
                [
                  Agent_sdk.Types.ToolResult
                    {
                      tool_use_id = orphan_id;
                      content = "";
                      is_error = false;
                      json = Some (`Assoc [ ("path", `String "README.md") ]);
                    };
                ];
              name = None;
              tool_call_id = None; metadata = [];
            }
            :: checkpoint.messages;
        }
      in
      let session = KEC.create_session ~session_id:trace_id ~base_dir in
      (match
         Masc_mcp.Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir checkpoint
       with
       | Ok () -> ()
       | Error _ -> Alcotest.fail "save_oas raw orphan checkpoint failed");
      match
        KEC.recover_latest_checkpoint_for_overflow_retry ~base_dir ~meta
          ~model:"llama:auto" ~primary_model_max_tokens:256
      with
      | Some recovery ->
          check (option string)
            "overflow retry drops structured orphan tool result" None
            (tool_result_content_for_id ~tool_use_id:orphan_id
               recovery.checkpoint.messages)
      | None -> fail "expected overflow retry recovery from orphan checkpoint")

let test_rollover_repairs_orphan_tool_result () =
  let base_dir = temp_dir "keeper_lifecycle_rollover_orphan" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let trace_id = "trace-rollover-orphan" in
      let meta =
        {
          (make_keeper_meta ~trace_id ()) with
          auto_handoff = true;
          handoff_threshold = 0.0;
          handoff_cooldown_sec = 0;
        }
      in
      let orphan_id = "call-rollover-orphan" in
      let checkpoint =
        {
          Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
          session_id = trace_id;
          agent_name = "patch-test";
          model = "test-model";
          system_prompt = None;
          messages =
            [
              {
                Agent_sdk.Types.role = Agent_sdk.Types.Tool;
                content =
                  [
                    Agent_sdk.Types.ToolResult
                      {
                        tool_use_id = orphan_id;
                        content = "";
                        is_error = false;
                        json = Some (`Assoc [ ("path", `String "lib/keeper.ml") ]);
                      };
                  ];
                name = None;
                tool_call_id = None; metadata = [];
              };
              Agent_sdk.Types.assistant_msg
                "done\n\n[STATE]\nGoal: rollover orphan repair\nProgress: ready\n[/STATE]";
            ];
          usage = Agent_sdk.Types.empty_usage;
          turn_count = 2;
          created_at = 0.0;
          tools = [];
          tool_choice = None;
          disable_parallel_tool_use = false;
          temperature = None;
          top_p = None;
          top_k = None;
          min_p = None;
          enable_thinking = None;
          response_format = Agent_sdk.Types.Off;
          thinking_budget = None;
          cache_system_prompt = false;
          max_input_tokens = None;
          max_total_tokens = Some 4096;
          context = Agent_sdk.Context.create ();
          mcp_sessions = [];
          working_context = None;
        }
      in
      let rollover =
        KEC.maybe_rollover_oas_handoff
          ~on_started:(fun () -> ())
          ~base_dir
          ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:256
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      check bool "rollover attempted" true rollover.attempted;
      let next_trace_id =
        Masc_mcp.Keeper_id.Trace_id.to_string rollover.updated_meta.runtime.trace_id
      in
      let next_session = KEC.create_session ~session_id:next_trace_id ~base_dir in
      match
        Masc_mcp.Keeper_checkpoint_store.load_oas
          ~session_dir:next_session.session_dir
          ~session_id:next_trace_id
      with
      | Ok saved ->
          check (option string)
            "rollover drops structured orphan tool result" None
            (tool_result_content_for_id ~tool_use_id:orphan_id saved.messages)
      | Error _ -> Alcotest.fail "load_oas rollover checkpoint failed")

(* --- patch_checkpoint_last_assistant tests (#5431) --- *)

let make_test_checkpoint ?(session_id = "old-session")
    (messages : Agent_sdk.Types.message list) : Agent_sdk.Checkpoint.t =
  {
    Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
    session_id;
    agent_name = "patch-test";
    model = "test-model";
    system_prompt = None;
    messages;
    usage = Agent_sdk.Types.empty_usage;
    turn_count = List.length messages;
    created_at = 0.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens = Some 4096;
    context = Agent_sdk.Context.create ();
    mcp_sessions = [];
    working_context = None;
  }

let contaminated_world_state_text =
  "## Current World State\n\n\
   ### Namespace State\n- Unclaimed tasks: 22\n- Active agents: 6\n\n\
   ### Available Tools\n- keeper_board_list\n- keeper_task_claim\n\n\
   ### Continuity\nGoal: keep going\nDone: none\n"

let contaminated_user_message ?(prompt = "짧게 ping만 해봐") () :
    Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.User;
    content =
      [
        Agent_sdk.Types.Text prompt;
        Agent_sdk.Types.Text contaminated_world_state_text;
        Agent_sdk.Types.Text ("[system context] " ^ contaminated_world_state_text);
      ];
    name = None;
    tool_call_id = None; metadata = [];
  }

let oversized_checkpoint_text =
  String.make 20_000 'x'

let oversized_user_message ?(prompt = "긴 텍스트도 저장되면 안 돼") () :
    Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.User;
    content =
      [
        Agent_sdk.Types.Text prompt;
        Agent_sdk.Types.Text oversized_checkpoint_text;
      ];
    name = None;
    tool_call_id = None; metadata = [];
  }

let summarized_contaminated_text =
  "[Summary of 2 earlier messages]\n\
   [User] ## Current World State\n\n\
   ### Namespace State\n- Unclaimed tasks: 22\n\n\
   ### Available Tools\n- keeper_board_list\n\n\
   ### Continuity\nGoal: keep going\nDone: none\n\
   [Assistant] 이 줄은 남아야 한다.\n"

let summarized_contaminated_message () : Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.User;
    content = [Agent_sdk.Types.Text summarized_contaminated_text];
    name = None;
    tool_call_id = None; metadata = [];
  }

let test_persist_message_drops_world_state_and_separates_internal_history () =
  let base_dir = temp_dir "keeper_lifecycle_history_split" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-history-split" ~base_dir
      in
      KEC.persist_message
        ~source:"direct_user"
        session
        (Agent_sdk.Types.user_msg "real conversation");
      KEC.persist_message
        ~source:"world_state_prompt"
        session
        (Agent_sdk.Types.user_msg contaminated_world_state_text);
      KEC.persist_message
        ~source:"internal_assistant"
        session
        (Agent_sdk.Types.assistant_msg "internal reply");
      let main_history =
        Fs_compat.load_file
          (Filename.concat session.session_dir "history.jsonl")
      in
      let internal_history =
        Fs_compat.load_file
          (Filename.concat session.session_dir "history.internal.jsonl")
      in
      check bool "main history keeps direct conversation" true
        (contains_substring main_history "real conversation");
      check bool "main history excludes world state prompt" false
        (contains_substring main_history "Current World State");
      check bool "main history excludes internal assistant" false
        (contains_substring main_history "internal reply");
      check bool "internal history drops world state prompt" false
        (contains_substring internal_history "Current World State");
      check bool "internal history stores internal assistant" true
        (contains_substring internal_history "internal reply"))

let test_migrate_session_history_logs_moves_internal_entries () =
  let base_dir = temp_dir "keeper_lifecycle_history_migrate" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-history-migrate" ~base_dir
      in
      let history_path = Filename.concat session.session_dir "history.jsonl" in
      let internal_history_path =
        Filename.concat session.session_dir "history.internal.jsonl"
      in
      let payload =
        String.concat "\n"
          [
            {|{"role":"user","content":"real conversation"}|};
            {|{"role":"user","source":"world_state_prompt","content":"## Current World State\n\n### Namespace State\n- Unclaimed tasks: 1\n\n### Available Tools\n- keeper_board_list\n\n### Continuity\nGoal: keep going"}|};
            {|{"role":"assistant","source":"internal_assistant","content":"internal reply"}|};
            {|{"role":"user","content":"[Summary]\n[User] ## Current World State\n\n### Namespace State\n- Unclaimed tasks: 1\n\n### Available Tools\n- keeper_board_list\n\n### Continuity\nGoal: keep going"}|};
          ]
        ^ "\n"
      in
      Fs_compat.save_file history_path payload;
      Fs_compat.save_file
        internal_history_path
        (String.concat "\n"
           [
             {|{"role":"user","source":"world_state_prompt","content":"## Current World State\n\n### Namespace State\n- Unclaimed tasks: 9\n\n### Available Tools\n- keeper_board_list\n\n### Continuity\nGoal: keep going"}|};
             {|{"role":"assistant","source":"internal_assistant","content":"existing internal reply"}|};
           ]
         ^ "\n");
      let stats =
        KCC.migrate_session_history_logs ~session_dir:session.session_dir
      in
      check int "moved internal lines" 1 stats.moved_lines;
      check int "dropped prompt lines" 3 stats.dropped_lines;
      let main_history = Fs_compat.load_file history_path in
      let internal_history =
        Fs_compat.load_file internal_history_path
      in
      check bool "main history keeps real conversation" true
        (contains_substring main_history "real conversation");
      check bool "main history excludes world state" false
        (contains_substring main_history "Current World State");
      check bool "main history excludes internal assistant" false
        (contains_substring main_history "internal reply");
      check bool "internal history drops world state" false
        (contains_substring internal_history "Current World State");
      check bool "internal history keeps moved internal assistant" true
        (contains_substring internal_history "internal reply"))

let test_save_oas_checkpoint_strips_ephemeral_world_state () =
  let base_dir = temp_dir "keeper_lifecycle_save_strip" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-save-strip" ~base_dir
      in
      let ctx =
        KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:64_000
        |> fun ctx -> KEC.append ctx (contaminated_user_message ())
        |> KEC.sync_oas_context
      in
      match
        KEC.save_oas_checkpoint
          ~max_checkpoint_messages:120
          ~session
          ~agent_name:"keeper-lifecycle"
          ~model:"glm:glm-5.1"
          ~ctx
          ~generation:1
      with
      | Error e ->
          Alcotest.fail
            (Printf.sprintf "save_oas_checkpoint failed: %s" e)
      | Ok checkpoint ->
          check int "saved message count" 1
            (List.length checkpoint.messages);
          let text =
            Agent_sdk.Types.text_of_message (List.hd checkpoint.messages)
          in
          check bool "preserves actual prompt" true
            (contains_substring text "짧게 ping만 해봐");
          check bool "drops world state snapshot" false
            (contains_substring text "Current World State"))

let test_save_oas_checkpoint_caps_oversized_text () =
  let base_dir = temp_dir "keeper_lifecycle_save_cap" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-save-cap" ~base_dir
      in
      let ctx =
        KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:64_000
        |> fun ctx -> KEC.append ctx (oversized_user_message ())
        |> KEC.sync_oas_context
      in
      match
        KEC.save_oas_checkpoint
          ~max_checkpoint_messages:120
          ~session
          ~agent_name:"keeper-lifecycle"
          ~model:"glm:glm-5.1"
          ~ctx
          ~generation:1
      with
      | Error e ->
          Alcotest.fail
            (Printf.sprintf "save_oas_checkpoint failed: %s" e)
      | Ok checkpoint ->
          let text =
            Agent_sdk.Types.text_of_message (List.hd checkpoint.messages)
          in
          check bool "keeps prompt prefix" true
            (contains_substring text "긴 텍스트도 저장되면 안 돼");
          check bool "adds truncation marker" true
            (contains_substring text "[capped]");
          check bool "text was compacted" true
            (String.length text < String.length oversized_checkpoint_text))

let test_sanitize_checkpoint_message_caps_oversized_tool_result () =
  let oversized =
    String.make
      (KCC.default_max_checkpoint_tool_result_chars + 1024)
      'x'
  in
  let msg = tool_result_message ~tool_use_id:"tool-cap" oversized in
  match KCC.sanitize_checkpoint_message msg with
  | None, _ -> fail "expected oversized tool result to survive as capped output"
  | Some sanitized, stats ->
      (match sanitized.content with
       | [ Agent_sdk.Types.ToolResult { content; _ } ] ->
           check bool "adds truncation marker" true
             (contains_substring content KCC.checkpoint_text_cap_marker);
           check bool "tool result was compacted" true
             (String.length content < String.length oversized);
           check bool "tool result stays within configured cap" true
             (String.length content
              <= KCC.default_max_checkpoint_tool_result_chars
                 + String.length KCC.checkpoint_text_cap_marker)
       | _ -> fail "expected a single capped ToolResult block");
      check int "tool result truncation recorded" 1 stats.truncated_blocks

let test_sanitize_checkpoint_message_caps_tool_result_aggregate_budget () =
  let oversized = String.make 190_000 'z' in
  let msg =
    {
      Agent_sdk.Types.role = Agent_sdk.Types.Tool;
      content =
        [
          Agent_sdk.Types.ToolResult
            {
              tool_use_id = "tool-agg-1";
              content = oversized;
              is_error = false;
              json = None;
            };
          Agent_sdk.Types.ToolResult
            {
              tool_use_id = "tool-agg-2";
              content = oversized;
              is_error = false;
              json = None;
            };
          Agent_sdk.Types.ToolResult
            {
              tool_use_id = "tool-agg-3";
              content = oversized;
              is_error = false;
              json = None;
            };
        ];
      name = None;
      tool_call_id = None; metadata = [];
    }
  in
  match KCC.sanitize_checkpoint_message msg with
  | None, _ -> fail "expected aggregate-budgeted tool results to survive"
  | Some sanitized, stats ->
      (match sanitized.content with
       | [
           Agent_sdk.Types.ToolResult { content = first; _ };
           Agent_sdk.Types.ToolResult { content = second; _ };
           Agent_sdk.Types.ToolResult { content = third; _ };
         ] ->
           check bool "first tool result truncated" true
             (contains_substring first KCC.checkpoint_text_cap_marker);
           check bool "second tool result truncated" true
             (contains_substring second KCC.checkpoint_text_cap_marker);
           check string "aggregate overflow gets stubbed"
             "[tool result cleared]" third
       | _ -> fail "expected three ToolResult blocks after aggregate cap");
      check int "aggregate cap records truncated blocks" 2
        stats.truncated_blocks;
      check int "aggregate cap records dropped block" 1 stats.dropped_blocks

let test_save_oas_checkpoint_stubs_old_tool_results () =
  let base_dir = temp_dir "keeper_lifecycle_save_tool_stub" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-save-tool-stub" ~base_dir
      in
      let old_tool_use_id = "tool-old" in
      let recent_tool_use_id = "tool-recent" in
      let old_output = String.make 200 'a' in
      let recent_output = String.make 200 'b' in
      let ctx =
        KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:64_000
        |> fun ctx ->
        KEC.append_many ctx
          [
            Agent_sdk.Types.user_msg "inspect the old turn";
            tool_use_message ~tool_use_id:old_tool_use_id ();
            tool_result_message ~tool_use_id:old_tool_use_id old_output;
            Agent_sdk.Types.assistant_msg "old turn summary";
            Agent_sdk.Types.user_msg "inspect the recent turn";
            tool_use_message ~tool_use_id:recent_tool_use_id ~name:"grep_search" ();
            tool_result_message ~tool_use_id:recent_tool_use_id recent_output;
            Agent_sdk.Types.assistant_msg "recent turn summary";
          ]
        |> KEC.sync_oas_context
      in
      match
        KEC.save_oas_checkpoint
          ~max_checkpoint_messages:120
          ~session
          ~agent_name:"keeper-lifecycle"
          ~model:"glm:glm-5.1"
          ~ctx
          ~generation:1
      with
      | Error e ->
          Alcotest.fail
            (Printf.sprintf "save_oas_checkpoint failed: %s" e)
      | Ok checkpoint ->
          let old_saved =
            tool_result_content_for_id
              ~tool_use_id:old_tool_use_id
              checkpoint.messages
          in
          let recent_saved =
            tool_result_content_for_id
              ~tool_use_id:recent_tool_use_id
              checkpoint.messages
          in
          (match old_saved with
           | None -> fail "expected old tool result in saved checkpoint"
           | Some content ->
               check bool "old tool result is compacted" true
                 (not (String.equal old_output content));
               check bool "old tool result stays structured" true
                 (String.starts_with ~prefix:"[tool:" content);
               check bool "old tool result keeps tool name" true
                 (contains_substring content "list_files"));
          (match recent_saved with
           | None -> fail "expected recent tool result in saved checkpoint"
           | Some content ->
               check string "recent tool result stays full" recent_output content))

let test_save_oas_checkpoint_repairs_orphaned_tool_result_after_cap () =
  let base_dir = temp_dir "keeper_lifecycle_save_orphan_tool_result" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-save-orphan-tool-result" ~base_dir
      in
      let tool_id = "tool-orphan-save" in
      let tool_output = "saved tool output" in
      let ctx =
        KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:64_000
        |> fun ctx ->
        KEC.append_many ctx
          [
            Agent_sdk.Types.user_msg "inspect file";
            tool_use_message ~tool_use_id:tool_id ();
            tool_result_message ~tool_use_id:tool_id tool_output;
            Agent_sdk.Types.assistant_msg "done";
          ]
        |> KEC.sync_oas_context
      in
      match
        KEC.save_oas_checkpoint
          ~max_checkpoint_messages:2
          ~session
          ~agent_name:"keeper-lifecycle"
          ~model:"glm:glm-5.1"
          ~ctx
          ~generation:1
      with
      | Error e ->
          Alcotest.fail
            (Printf.sprintf "save_oas_checkpoint failed: %s" e)
      | Ok checkpoint ->
          (* trim_messages_preserving_pairs drops the orphan ToolResult
             along with the ToolUse, so only "done" survives (1 message).
             The old test expected 2 because it allowed orphan creation
             and relied on repair to downgrade the ToolResult to text.
             The new behavior prevents orphans at the source. *)
          check bool "save cap enforced with pair preservation"
            true (List.length checkpoint.messages <= 2);
          check (option string) "orphan tool result removed" None
            (tool_result_content_for_id ~tool_use_id:tool_id checkpoint.messages))

let test_load_context_repairs_orphaned_tool_result_after_cap () =
  let base_dir = temp_dir "keeper_lifecycle_load_orphan_tool_result" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-load-orphan-tool-result" in
      let session =
        KEC.create_session ~session_id:trace_id ~base_dir
      in
      let tool_id = "tool-orphan-load" in
      let tool_output = "loaded tool output" in
      let checkpoint =
        make_test_checkpoint ~session_id:trace_id
          [
            Agent_sdk.Types.user_msg "inspect file";
            tool_use_message ~tool_use_id:tool_id ();
            tool_result_message ~tool_use_id:tool_id tool_output;
            Agent_sdk.Types.assistant_msg "done";
          ]
      in
      (match
         Masc_mcp.Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir checkpoint
       with
       | Ok () -> ()
       | Error e ->
           Alcotest.fail
             (Printf.sprintf "save_oas failed: %s" e));
      let (_session, loaded_opt) =
        KEC.load_context_from_checkpoint
          ~max_checkpoint_messages:2
          ~trace_id
          ~primary_model_max_tokens:64_000
          ~base_dir
      in
      match loaded_opt with
      | None -> fail "expected checkpoint context to load"
      | Some loaded ->
          check bool "load cap enforced with pair preservation"
            true (List.length (ctx_messages loaded) <= 2);
          check (option string) "loaded orphan tool result removed" None
            (tool_result_content_for_id ~tool_use_id:tool_id (ctx_messages loaded)))

let test_deserialize_context_repairs_orphan_tool_result () =
  let ctx =
    KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:4096
    |> fun ctx ->
    KEC.append ctx
      {
        Agent_sdk.Types.role = Agent_sdk.Types.Tool;
        content =
          [
            Agent_sdk.Types.ToolResult
              {
                tool_use_id = "call-orphan-json";
                content = "";
                is_error = false;
                json = Some (`Assoc [ ("path", `String "README.md") ]);
              };
          ];
        name = None;
        tool_call_id = None; metadata = [];
      }
  in
  let ctx =
    KCC.deserialize_context (KEC.serialize_context ctx) ~max_tokens:4096
  in
  check (option string) "deserialized orphan tool result downgraded" None
    (tool_result_content_for_id ~tool_use_id:"call-orphan-json" (ctx_messages ctx));
  match List.hd (ctx_messages ctx) with
  | { Agent_sdk.Types.content = [ Agent_sdk.Types.Text text ]; _ } ->
      check string "deserialized orphan falls back to marker when payload metadata is absent"
        "[tool result call-orphan-json]" text
  | _ -> fail "expected orphan tool result to degrade to text on deserialize"

let test_deserialize_context_preserves_valid_tool_pair () =
  let tool_id = "call-valid-pair" in
  let ctx =
    KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:4096
    |> fun ctx ->
    KEC.append_many ctx
      [
        Agent_sdk.Types.user_msg "read the file";
        tool_use_message ~tool_use_id:tool_id ();
        tool_result_message ~tool_use_id:tool_id "paired output";
        Agent_sdk.Types.assistant_msg "done";
      ]
  in
  let roundtrip =
    KCC.deserialize_context (KEC.serialize_context ctx) ~max_tokens:4096
  in
  check (option string) "paired tool result stays structured"
    (Some "paired output")
    (tool_result_content_for_id ~tool_use_id:tool_id (ctx_messages roundtrip))

let test_deserialize_context_repairs_dangling_tool_use () =
  let tool_id = "call-dangling-use-json" in
  let ctx =
    KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:4096
    |> fun ctx ->
    KEC.append_many ctx
      [
        Agent_sdk.Types.user_msg "read the file";
        tool_use_message ~tool_use_id:tool_id ~name:"keeper_board_comment" ();
        Agent_sdk.Types.assistant_msg "done";
      ]
  in
  let roundtrip =
    KCC.deserialize_context (KEC.serialize_context ctx) ~max_tokens:4096
  in
  check bool "dangling tool use removed on deserialize" false
    (has_tool_use_id ~tool_use_id:tool_id (ctx_messages roundtrip));
  match List.nth_opt (ctx_messages roundtrip) 1 with
  | Some { Agent_sdk.Types.content = [ Agent_sdk.Types.Text text ]; _ } ->
      check bool "dangling tool use downgraded to text on deserialize" true
        (contains_substring text "tool use keeper_board_comment");
      check bool "dangling tool use id retained on deserialize" true
        (contains_substring text tool_id)
  | _ -> fail "expected dangling tool use to downgrade to text on deserialize"

let test_load_context_repairs_dangling_tool_use_after_cap () =
  let base_dir = temp_dir "keeper_lifecycle_load_dangling_tool_use" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-load-dangling-tool-use" in
      let session =
        KEC.create_session ~session_id:trace_id ~base_dir
      in
      let tool_id = "tool-dangling-load" in
      let checkpoint =
        make_test_checkpoint ~session_id:trace_id
          [
            Agent_sdk.Types.user_msg "inspect file";
            tool_use_message ~tool_use_id:tool_id ~name:"keeper_board_comment" ();
            Agent_sdk.Types.assistant_msg "done";
          ]
      in
      (match
         Masc_mcp.Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir checkpoint
       with
       | Ok () -> ()
       | Error e ->
           Alcotest.fail
             (Printf.sprintf "save_oas failed: %s" e));
      let (_session, loaded_opt) =
        KEC.load_context_from_checkpoint
          ~max_checkpoint_messages:8
          ~trace_id
          ~primary_model_max_tokens:64_000
          ~base_dir
      in
      match loaded_opt with
      | None -> fail "expected checkpoint context to load"
      | Some loaded ->
          check bool "dangling tool use removed on load" false
            (has_tool_use_id ~tool_use_id:tool_id (ctx_messages loaded));
          match List.nth_opt (ctx_messages loaded) 1 with
          | Some { Agent_sdk.Types.content = [ Agent_sdk.Types.Text text ]; _ } ->
              check bool "dangling tool use downgraded to text on load" true
                (contains_substring text "tool use keeper_board_comment");
              check bool "dangling tool use id retained on load" true
                (contains_substring text tool_id)
          | _ ->
              fail "expected dangling tool use to downgrade to text on load")

let test_save_oas_checkpoint_strips_summarized_world_state () =
  let base_dir = temp_dir "keeper_lifecycle_save_summary_strip" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let session =
        KEC.create_session ~session_id:"trace-save-summary-strip" ~base_dir
      in
      let ctx =
        KEC.create ~system_prompt:"keeper lifecycle" ~max_tokens:64_000
        |> fun ctx -> KEC.append ctx (summarized_contaminated_message ())
        |> KEC.sync_oas_context
      in
      match
        KEC.save_oas_checkpoint
          ~max_checkpoint_messages:120
          ~session
          ~agent_name:"keeper-lifecycle"
          ~model:"glm:glm-5.1"
          ~ctx
          ~generation:1
      with
      | Error e ->
          Alcotest.fail
            (Printf.sprintf "save_oas_checkpoint failed: %s" e)
      | Ok checkpoint ->
          let text =
            Agent_sdk.Types.text_of_message (List.hd checkpoint.messages)
          in
          check bool "drops embedded world state from summary" false
            (contains_substring text "Current World State");
          check bool "preserves assistant summary text" true
            (contains_substring text "이 줄은 남아야 한다."))

let test_patch_checkpoint_replaces_last_assistant () =
  let msgs =
    [ Agent_sdk.Types.user_msg "hello";
      Agent_sdk.Types.assistant_msg "raw response without STATE" ]
  in
  let cp = make_test_checkpoint msgs in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"new-session"
      ~response_text:"patched response\n[STATE]\nprogress: done\n[/STATE]"
  in
  let last_msg = List.nth patched.messages 1 in
  let text = Agent_sdk.Types.text_of_message last_msg in
  check bool "scrubs STATE block" false (contains_substring text "[STATE]");
  check bool "contains patched text" true
    (contains_substring text "patched response");
  check bool "replay metadata attached" true
    (KMP.snapshot_of_message_metadata last_msg <> None);
  check string "session_id updated" "new-session" patched.session_id

let test_patch_checkpoint_preserves_non_assistant () =
  let msgs =
    [ Agent_sdk.Types.user_msg "question 1";
      Agent_sdk.Types.assistant_msg "answer 1";
      Agent_sdk.Types.user_msg "question 2";
      Agent_sdk.Types.assistant_msg "answer 2 raw" ]
  in
  let cp = make_test_checkpoint msgs in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"s" ~response_text:"answer 2 with STATE"
  in
  (* First user message preserved *)
  let first_text = Agent_sdk.Types.text_of_message (List.nth patched.messages 0) in
  check string "first user preserved" "question 1" first_text;
  (* First assistant preserved (only LAST assistant is patched) *)
  let second_text = Agent_sdk.Types.text_of_message (List.nth patched.messages 1) in
  check string "first assistant preserved" "answer 1" second_text;
  (* Last assistant patched *)
  let last_text = Agent_sdk.Types.text_of_message (List.nth patched.messages 3) in
  check string "last assistant patched" "answer 2 with STATE" last_text;
  check bool "no metadata without state snapshot" true
    (KMP.snapshot_of_message_metadata (List.nth patched.messages 3) = None)

let test_patch_checkpoint_updates_session_id () =
  let cp = make_test_checkpoint ~session_id:"old" [] in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"new-trace-id" ~response_text:"unused"
  in
  check string "session_id" "new-trace-id" patched.session_id

let test_patch_checkpoint_no_assistant_noop () =
  let msgs = [ Agent_sdk.Types.user_msg "only user" ] in
  let cp = make_test_checkpoint msgs in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"s" ~response_text:"should not appear"
  in
  check int "message count unchanged" 1 (List.length patched.messages);
  let text = Agent_sdk.Types.text_of_message (List.hd patched.messages) in
  check string "user msg unchanged" "only user" text

let test_patch_checkpoint_strips_ephemeral_world_state () =
  let msgs =
    [
      contaminated_user_message ~prompt:"지금 상태 한 줄로만 말해." ();
      Agent_sdk.Types.assistant_msg "raw response";
    ]
  in
  let cp = make_test_checkpoint msgs in
  let patched =
    KCC.patch_checkpoint_last_assistant cp
      ~session_id:"patched-session"
      ~response_text:"clean response"
  in
  let first_text = Agent_sdk.Types.text_of_message (List.hd patched.messages) in
  check bool "keeps user prompt" true
    (contains_substring first_text "지금 상태 한 줄로만 말해.");
  check bool "removes world state from prior user message" false
    (contains_substring first_text "Current World State")

let test_load_context_migrates_ephemeral_world_state_checkpoint () =
  let base_dir = temp_dir "keeper_lifecycle_load_migrate" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-load-migrate" in
      let session = KEC.create_session ~session_id:trace_id ~base_dir in
      let checkpoint =
        make_test_checkpoint ~session_id:trace_id
          [ contaminated_user_message ~prompt:"짧게 ping만 해봐" () ]
      in
      (match
         Masc_mcp.Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir checkpoint
       with
       | Ok () -> ()
       | Error e ->
           Alcotest.fail
             (Printf.sprintf "seed save_oas failed: %s" e));
      let loaded_opt = load_context ~base_dir ~trace_id ~max_tokens:64_000 in
      let loaded =
        match loaded_opt with
        | Some ctx -> ctx
        | None -> Alcotest.fail "expected migrated context"
      in
      let loaded_text =
        String.concat "\n"
          (List.map Agent_sdk.Types.text_of_message (ctx_messages loaded))
      in
      check bool "loaded prompt preserved" true
        (contains_substring loaded_text "짧게 ping만 해봐");
      check bool "loaded world state removed" false
        (contains_substring loaded_text "Current World State");
      match
        Masc_mcp.Keeper_checkpoint_store.load_oas
          ~session_dir:session.session_dir
          ~session_id:trace_id
      with
      | Error _ -> Alcotest.fail "expected migrated checkpoint on disk"
      | Ok migrated ->
          let migrated_text =
            String.concat "\n"
              (List.map Agent_sdk.Types.text_of_message migrated.messages)
          in
          check bool "migrated checkpoint persists cleanup" false
            (contains_substring migrated_text "Current World State"))

let test_load_context_migrates_oversized_text_checkpoint () =
  let base_dir = temp_dir "keeper_lifecycle_load_cap" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-load-cap" in
      let session = KEC.create_session ~session_id:trace_id ~base_dir in
      let checkpoint =
        make_test_checkpoint ~session_id:trace_id
          [ oversized_user_message ~prompt:"짧게 요약해" () ]
      in
      (match
         Masc_mcp.Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir checkpoint
       with
       | Ok () -> ()
       | Error e ->
           Alcotest.fail
             (Printf.sprintf "seed save_oas failed: %s" e));
      let loaded_opt = load_context ~base_dir ~trace_id ~max_tokens:64_000 in
      let loaded =
        match loaded_opt with
        | Some ctx -> ctx
        | None -> Alcotest.fail "expected migrated capped context"
      in
      let loaded_text =
        String.concat "\n"
          (List.map Agent_sdk.Types.text_of_message (ctx_messages loaded))
      in
      check bool "loaded prompt preserved" true
        (contains_substring loaded_text "짧게 요약해");
      check bool "loaded checkpoint capped" true
        (contains_substring loaded_text "[capped]");
      check bool "loaded text reduced" true
        (String.length loaded_text < String.length oversized_checkpoint_text);
      match
        Masc_mcp.Keeper_checkpoint_store.load_oas
          ~session_dir:session.session_dir
          ~session_id:trace_id
      with
      | Error _ -> Alcotest.fail "expected capped checkpoint on disk"
      | Ok migrated ->
          let migrated_text =
            String.concat "\n"
              (List.map Agent_sdk.Types.text_of_message migrated.messages)
          in
          check bool "migrated checkpoint persists cap" true
            (contains_substring migrated_text "[capped]");
          check bool "migrated text reduced" true
            (String.length migrated_text < String.length oversized_checkpoint_text))

let test_load_context_migrates_summarized_world_state_checkpoint () =
  let base_dir = temp_dir "keeper_lifecycle_load_summary_strip" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-load-summary-strip" in
      let session = KEC.create_session ~session_id:trace_id ~base_dir in
      let checkpoint =
        make_test_checkpoint ~session_id:trace_id
          [ summarized_contaminated_message () ]
      in
      (match
         Masc_mcp.Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir checkpoint
       with
       | Ok () -> ()
       | Error e ->
           Alcotest.fail
             (Printf.sprintf "seed save_oas failed: %s" e));
      let loaded_opt = load_context ~base_dir ~trace_id ~max_tokens:64_000 in
      let loaded =
        match loaded_opt with
        | Some ctx -> ctx
        | None -> Alcotest.fail "expected migrated summarized context"
      in
      let loaded_text =
        String.concat "\n"
          (List.map Agent_sdk.Types.text_of_message (ctx_messages loaded))
      in
      check bool "loaded summary drops world state" false
        (contains_substring loaded_text "Current World State");
      check bool "loaded summary keeps assistant text" true
        (contains_substring loaded_text "이 줄은 남아야 한다.");
      match
        Masc_mcp.Keeper_checkpoint_store.load_oas
          ~session_dir:session.session_dir
          ~session_id:trace_id
      with
      | Error _ -> Alcotest.fail "expected migrated summary checkpoint on disk"
      | Ok migrated ->
          let migrated_text =
            String.concat "\n"
              (List.map Agent_sdk.Types.text_of_message migrated.messages)
          in
          check bool "migrated summary strips world state" false
            (contains_substring migrated_text "Current World State");
          check bool "migrated summary keeps assistant text" true
            (contains_substring migrated_text "이 줄은 남아야 한다."))

(* Regression tests for compaction gate fixes introduced in #5599:
   - ts=0.0 must not block compaction via the cooldown gate
   - ratio >= 0.8 (emergency_compact_ratio_threshold) must bypass the cooldown gate
   Both tests keep ratio_gate=1.0 / message_gate=0 / token_gate=0 so that no
   actual OAS compaction is triggered — only the gate logic is exercised. *)

(* Large enough to guarantee ratio >= 0.8 when max_tokens=100 (each char ~0.25 tokens
   via estimate_char_tokens, so 400 chars ≈ 100 tokens per message; two messages
   easily exceed the 80-token threshold needed for ratio>=0.8 in a 100-token window). *)
let emergency_test_text_length = 400

let make_gate_only_meta ?(last_continuity_update_ts = 0.0) ?(cooldown_sec = 3600) () =
  let base = make_keeper_meta () in
  {
    base with
    compaction =
      {
        base.compaction with
        ratio_gate = 1.0;
        message_gate = 0;
        token_gate = 0;
        cooldown_sec;
      };
    runtime =
      {
        base.runtime with
        last_continuity_update_ts;
      };
  }

let test_compact_if_needed_ts_zero_bypasses_cooldown () =
  (* When last_reflection_ts=0.0 (keeper has never reflected) the cooldown
     gate must NOT block compaction even though now_ts - 0.0 < cooldown. *)
  let meta = make_gate_only_meta ~last_continuity_update_ts:0.0 ~cooldown_sec:3600 () in
  let ctx = KEC.create ~system_prompt:"sp" ~max_tokens:4096 in
  let now_ts = 1000.0 in (* well within the 3600s cooldown window *)
  let (_ctx, trigger, decision) = KEC.compact_if_needed ~meta ~now_ts ctx in
  check (option string) "no compaction triggered (ratio_gate=1.0)" None trigger;
  check string "ts=0.0 bypasses cooldown, not skipped" "blocked:below_thresholds" decision

let test_compact_if_needed_emergency_bypass_ignores_cooldown () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* When ratio >= 0.8 the cooldown gate must be bypassed even if the
     reflection timestamp is fresh and the cooldown period has not elapsed.
     Without the emergency bypass, cooldown (3600s) would block compaction
     because only 60s have elapsed since last reflection. *)
  let now_ts = 10_000.0 in
  let meta =
    make_gate_only_meta ~last_continuity_update_ts:(now_ts -. 60.0) ~cooldown_sec:3600 ()
  in
  let long_text = String.make emergency_test_text_length 'x' in
  let ctx =
    KEC.create ~system_prompt:"sp" ~max_tokens:100
    |> fun c -> KEC.append c (Agent_sdk.Types.user_msg long_text)
    |> fun c -> KEC.append c (Agent_sdk.Types.assistant_msg long_text)
    |> KEC.sync_oas_context
  in
  let ratio = KCC.context_ratio ctx in
  check bool "context ratio is above emergency threshold" true (ratio >= 0.8);
  let (_ctx, trigger, decision) = KEC.compact_if_needed ~meta ~now_ts ctx in
  (* Emergency ratio bypasses cooldown → compaction fires (ratio >= ratio_gate=1.0) *)
  check bool "compaction was triggered (emergency bypass)" true (Option.is_some trigger);
  check bool "decision starts with applied:" true (String.starts_with ~prefix:"applied:" decision)

let test_compact_if_needed_records_saved_tokens_metric () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let now_ts = 20_000.0 in
  let meta =
    make_gate_only_meta
      ~last_continuity_update_ts:(now_ts -. 60.0)
      ~cooldown_sec:0
      ()
  in
  let long_text = String.make emergency_test_text_length 'x' in
  let ctx =
    KEC.create ~system_prompt:"sp" ~max_tokens:100
    |> fun c -> KEC.append c (Agent_sdk.Types.user_msg long_text)
    |> fun c -> KEC.append c (Agent_sdk.Types.assistant_msg long_text)
    |> KEC.sync_oas_context
  in
  let labels = [ ("keeper", meta.name) ] in
  let before_metric =
    Masc_mcp.Prometheus.get_metric_value
      Masc_mcp.Prometheus.metric_keeper_compaction_saved_tokens
      ~labels
      ()
    |> Option.value ~default:0.0
  in
  let (compacted_ctx, trigger, decision) =
    KEC.compact_if_needed ~meta ~now_ts ctx
  in
  let after_metric =
    Masc_mcp.Prometheus.get_metric_value
      Masc_mcp.Prometheus.metric_keeper_compaction_saved_tokens
      ~labels
      ()
    |> Option.value ~default:0.0
  in
  check bool "compaction was triggered" true (Option.is_some trigger);
  check bool "decision starts with applied:" true
    (String.starts_with ~prefix:"applied:" decision);
  check bool "token count reduced" true
    (KCC.token_count compacted_ctx < KCC.token_count ctx);
  check bool "saved tokens metric increased" true (after_metric > before_metric)

let test_dispatch_keeper_phase_event_uses_room_base_path () =
  let base_dir = temp_dir "keeper_lifecycle_registry_phase" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-phase-regression" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:meta.name
        KST.Compaction_started;
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "compaction start reaches registry" "compacting"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after compaction dispatch")

let test_dispatch_post_turn_lifecycle_events_uses_room_base_path () =
  let base_dir = temp_dir "keeper_lifecycle_registry_outcome" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      KR.clear ();
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_keeper_meta ~name:"keeper-outcome-regression" () in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:meta.name
        KST.Compaction_started;
      let lifecycle =
        {
          (base_lifecycle ~meta) with
          compaction =
            {
              attempted = true;
              applied = true;
              failure_reason = None;
              trigger = Some "test";
              decision = "applied:test";
              before_tokens = 42;
              after_tokens = 21;
              saved_tokens = 21;
            };
        }
      in
      KEC.dispatch_post_turn_lifecycle_events
        ~config
        ~keeper_name:meta.name
        lifecycle;
      match KR.get ~base_path:config.base_path meta.name with
      | Some entry ->
          check string "compaction completion reaches registry" "running"
            (KST.phase_to_string entry.phase)
      | None -> fail "expected registered keeper after lifecycle dispatch")

let test_dispatch_keeper_phase_event_rejection_increments_metric () =
  let base_dir = temp_dir "keeper_lifecycle_registry_rejection" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Masc_mcp.Coord.default_config base_dir in
      let labels = [ ("event", "compaction_started") ] in
      let before =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Prometheus.metric_keeper_lifecycle_dispatch_rejections
          ~labels ()
        |> Option.value ~default:0.0
      in
      KEC.dispatch_keeper_phase_event
        ~config
        ~keeper_name:"missing-keeper"
        KST.Compaction_started;
      let after =
        Masc_mcp.Prometheus.get_metric_value
          Masc_mcp.Prometheus.metric_keeper_lifecycle_dispatch_rejections
          ~labels ()
        |> Option.value ~default:0.0
      in
      check bool "rejection metric increments" true (after > before))

let () =
  run "keeper_lifecycle"
    [
      ( "post_turn_lifecycle",
        [
          test_case "no checkpoint records skip state" `Quick
            test_apply_post_turn_lifecycle_without_checkpoint_records_skip;
          test_case "restore prefers live primary max tokens" `Quick
            test_load_context_prefers_live_primary_max_tokens_over_checkpoint_limit;
          test_case "compaction persists checkpoint and continuity" `Quick
            test_apply_post_turn_lifecycle_compacts_and_updates_continuity;
          test_case "skip compaction keeps checkpoint" `Quick
            test_apply_post_turn_lifecycle_keeps_checkpoint_when_compaction_skips;
          test_case "handoff runs after compaction" `Quick
            test_apply_post_turn_lifecycle_handoffs_after_compaction;
          test_case "handoff runs on current-turn overflow signal" `Quick
            test_apply_post_turn_lifecycle_handoffs_on_current_turn_overflow_signal;
          test_case "rollover aborts on save failure" `Quick
            test_rollover_aborts_on_save_failure;
          test_case "overflow retry compacts OAS checkpoint" `Quick
            test_recover_latest_checkpoint_for_overflow_retry_compacts_oas_checkpoint;
          test_case "overflow retry falls back to legacy checkpoint" `Quick
            test_recover_latest_checkpoint_for_overflow_retry_uses_legacy_checkpoint;
          test_case
            "overflow retry history budget ignores checkpoint system prompt"
            `Quick
            test_recover_latest_checkpoint_for_overflow_retry_ignores_checkpoint_system_prompt_in_history_budget;
          test_case "overflow retry repairs orphan tool result" `Quick
            test_recover_latest_checkpoint_for_overflow_retry_repairs_orphan_tool_result;
          test_case "rollover repairs orphan tool result" `Quick
            test_rollover_repairs_orphan_tool_result;
        ] );
      ( "checkpoint_patch",
        [
          test_case
            "persist_message drops world state and separates internal history"
            `Quick
            test_persist_message_drops_world_state_and_separates_internal_history;
          test_case "migrate_session_history_logs moves internal entries" `Quick
            test_migrate_session_history_logs_moves_internal_entries;
          test_case "save strips ephemeral world state" `Quick
            test_save_oas_checkpoint_strips_ephemeral_world_state;
          test_case "save caps oversized text" `Quick
            test_save_oas_checkpoint_caps_oversized_text;
          test_case "save caps oversized tool result" `Quick
            test_sanitize_checkpoint_message_caps_oversized_tool_result;
          test_case "save caps aggregate tool result budget" `Quick
            test_sanitize_checkpoint_message_caps_tool_result_aggregate_budget;
          test_case "save stubs old tool results" `Quick
            test_save_oas_checkpoint_stubs_old_tool_results;
          test_case "save repairs orphaned tool result after cap" `Quick
            test_save_oas_checkpoint_repairs_orphaned_tool_result_after_cap;
          test_case "save strips summarized world state" `Quick
            test_save_oas_checkpoint_strips_summarized_world_state;
          test_case "patch replaces last assistant text" `Quick
            test_patch_checkpoint_replaces_last_assistant;
          test_case "patch preserves non-assistant messages" `Quick
            test_patch_checkpoint_preserves_non_assistant;
          test_case "patch updates session_id" `Quick
            test_patch_checkpoint_updates_session_id;
          test_case "patch with no assistant is noop" `Quick
            test_patch_checkpoint_no_assistant_noop;
          test_case "patch strips ephemeral world state" `Quick
            test_patch_checkpoint_strips_ephemeral_world_state;
          test_case "load migrates ephemeral world state checkpoint" `Quick
            test_load_context_migrates_ephemeral_world_state_checkpoint;
          test_case "load migrates oversized text checkpoint" `Quick
            test_load_context_migrates_oversized_text_checkpoint;
          test_case "load migrates summarized world state checkpoint" `Quick
            test_load_context_migrates_summarized_world_state_checkpoint;
          test_case "load repairs orphaned tool result after cap" `Quick
            test_load_context_repairs_orphaned_tool_result_after_cap;
          test_case "deserialize repairs orphaned tool result" `Quick
            test_deserialize_context_repairs_orphan_tool_result;
          test_case "deserialize preserves valid tool pair" `Quick
            test_deserialize_context_preserves_valid_tool_pair;
          test_case "deserialize repairs dangling tool use" `Quick
            test_deserialize_context_repairs_dangling_tool_use;
          test_case "load repairs dangling tool use after cap" `Quick
            test_load_context_repairs_dangling_tool_use_after_cap;
        ] );
      ( "compact_policy",
        [
          test_case "ts=0.0 bypasses cooldown gate" `Quick
            test_compact_if_needed_ts_zero_bypasses_cooldown;
          test_case "emergency ratio bypasses cooldown gate" `Quick
            test_compact_if_needed_emergency_bypass_ignores_cooldown;
          test_case "compaction records saved tokens metric" `Quick
            test_compact_if_needed_records_saved_tokens_metric;
        ] );
      ( "registry_dispatch",
        [
          test_case "phase event uses room base_path" `Quick
            test_dispatch_keeper_phase_event_uses_room_base_path;
          test_case "post-turn lifecycle events use room base_path" `Quick
            test_dispatch_post_turn_lifecycle_events_uses_room_base_path;
          test_case "phase event rejection increments metric" `Quick
            test_dispatch_keeper_phase_event_rejection_increments_metric;
        ] );
    ]
