open Alcotest

module KEC = Masc_mcp.Keeper_exec_context
module KT = Masc_mcp.Keeper_types

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

let make_keeper_meta ?(name = "keeper-lifecycle-test")
    ?(trace_id = "trace-keeper-lifecycle") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String "keeper_unified");
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
    KEC.create_session ~session_id:meta.runtime.trace_id ~base_dir
  in
  KEC.save_oas_checkpoint ~session
    ~agent_name:meta.agent_name
    ~model:"llama:auto"
    ~ctx
    ~generation:meta.runtime.generation

let load_context ~base_dir ~trace_id ~max_tokens =
  let (_session, loaded_opt) =
    KEC.load_context_from_checkpoint ~trace_id
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
        KEC.apply_post_turn_lifecycle ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:512
          ~checkpoint:None
      in
      check bool "compaction not applied" false lifecycle.compaction.applied;
      check string "skip decision" "skipped:no_checkpoint"
        lifecycle.compaction.decision;
      check string "runtime decision persisted" "skipped:no_checkpoint"
        lifecycle.updated_meta.runtime.compaction_rt.last_decision;
      check bool "last check ts recorded" true
        (lifecycle.updated_meta.runtime.compaction_rt.last_check_ts > 0.0);
      check int "turn generation unchanged" meta.runtime.generation
        lifecycle.turn_generation)

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
      let original_message_count = List.length original_ctx.messages in
      let checkpoint = save_checkpoint ~base_dir ~meta ~ctx:original_ctx in
      let lifecycle =
        KEC.apply_post_turn_lifecycle ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:320
          ~checkpoint:(Some checkpoint)
      in
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
      match
        load_context ~base_dir ~trace_id:lifecycle.updated_meta.runtime.trace_id
          ~max_tokens:320
      with
      | Some loaded ->
          check bool "compacted checkpoint persisted" true
            (List.length loaded.messages < original_message_count)
      | None -> fail "expected compacted checkpoint to be persisted")

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
      let lifecycle =
        KEC.apply_post_turn_lifecycle ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:256
          ~checkpoint:(Some checkpoint)
      in
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
        (List.mem meta.runtime.trace_id lifecycle.updated_meta.runtime.trace_history);
      (match lifecycle.handoff_json with
       | Some handoff ->
           let open Yojson.Safe.Util in
           check (option int) "new_generation field present" (Some 1)
             (handoff |> member "new_generation" |> to_int_option);
           check (option int) "to_generation field present" (Some 1)
             (handoff |> member "to_generation" |> to_int_option)
       | None -> fail "expected handoff json");
      match
        load_context ~base_dir ~trace_id:lifecycle.updated_meta.runtime.trace_id
          ~max_tokens:256
      with
      | Some loaded ->
          check bool "new trace checkpoint exists" true
            (List.length loaded.messages > 0)
      | None -> fail "expected rollover checkpoint in new trace")

let () =
  run "keeper_lifecycle"
    [
      ( "post_turn_lifecycle",
        [
          test_case "no checkpoint records skip state" `Quick
            test_apply_post_turn_lifecycle_without_checkpoint_records_skip;
          test_case "compaction persists checkpoint and continuity" `Quick
            test_apply_post_turn_lifecycle_compacts_and_updates_continuity;
          test_case "handoff runs after compaction" `Quick
            test_apply_post_turn_lifecycle_handoffs_after_compaction;
        ] );
    ]
