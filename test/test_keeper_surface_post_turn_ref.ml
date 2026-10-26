(** Exercise the real descriptor route and durable Dashboard transcript, without
    a provider or connector transport. The invocation's turn differs from the
    metadata trace, so metadata cannot substitute for its frozen provenance. *)
open Alcotest
module Runtime = Masc.Keeper_tool_runtime
module Store = Masc.Keeper_chat_store

let scenario () =
  let base_path = Filename.temp_dir "surface-post-turn-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Masc_test_deps.init_unified_tool_registry ();
    let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String "surface-post-proof"; "trace_id", `String "different-metadata-trace"]) with
      | Ok meta -> meta | Error detail -> fail detail in
    let config = Masc.Workspace.default_config base_path in
    let frozen = Ids.Turn_ref.make ~trace_id:"original-invocation" ~absolute_turn:3 in
    let ctx : Runtime.context =
      { config; meta;
        publication_recovery = {
          provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider;
          keeper_name = meta.name };
        ctx_work = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"fixture";
        turn_sandbox_factory = None; sw = None; clock = None; proc_mgr = None; net = None;
        mcp_session_id = None; continuation_channel = None; gate_context = None;
        turn_ref = Some frozen; gate_grant = None; tool_use_id = None; trace_id = None;
        source_context = None; owned_job_replay = None; result_projection = None;
        artifact_draft_scope = None; capability_authority = Runtime.Compatibility_meta }
    in
    let descriptor = match Runtime.descriptor_for_internal "keeper_surface_post" with
      | Some descriptor -> descriptor | None -> fail "surface post descriptor missing" in
    let post ctx content =
      match Runtime.handle ctx ~descriptor
        ~args:(`Assoc ["surface", `String "dashboard"; "content", `String content]) with
      | None -> fail "descriptor did not reach its handler"
      | Some result ->
          check bool "Dashboard post completed" true (result.disposition = Tool_result.Completed ());
          check bool "terminal delivery receipt is preserved" true
            (result.terminal_effect_receipt = Some (Masc.Keeper_tool_execution.Surface_post_completed
              Masc.Keeper_surface_post.To_dashboard));
          result
    in
    let posted = post ctx "original Task result" in
    ignore (post {ctx with turn_ref = None} "direct caller without a turn");
    let messages = Store.load ~base_dir:base_path ~keeper_name:meta.name in
    let original, direct = match messages with
      | [original; direct] -> original, direct
      | _ -> fail "each actual post must persist exactly one assistant message" in
    check (option string) "stored row keeps the invocation's original turn"
      (Some (Ids.Turn_ref.to_string frozen)) (Option.map Ids.Turn_ref.to_string original.turn_ref);
    check (option string) "missing invocation context stays absent" None
      (Option.map Ids.Turn_ref.to_string direct.turn_ref);
    let transcript = match Store.load_turn_transcript_result
      ~base_dir:base_path ~keeper_name:meta.name ~turn_ref:frozen with
      | Ok transcript -> transcript | Error _ -> fail "strict original turn transcript could not be read" in
    check (list string) "exact turn read finds only its actual terminal post"
      ["original Task result"]
      (List.map (fun (message : Store.chat_message) -> message.content) transcript.assistant);
    let projected = Store.to_json_array [original] in
    let contract = Yojson.Safe.Util.(projected |> index 0 |> member "stream_contract") in
    check string "history stream contract carries the same turn"
      (Ids.Turn_ref.to_string frozen) Yojson.Safe.Util.(contract |> member "turn_ref" |> to_string);
    let module Events = Masc.Keeper_chat_events in
    let module Audit = Masc.Keeper_chat_journal_audit in
    let journal ?(outcome=Masc.Keeper_turn_outcome.Terminal_effect_settled) effects =
      [Events.Run_started {run_id="operation";thread_id="conversation"};
       Events.Reply_details {reply="";turn_outcome=outcome;turn_ref=frozen;terminal_stream_scope=None}]
      @ effects @ [Events.Run_finished {run_id="operation"}]
      |> List.mapi (fun seq event -> {Masc.Keeper_chat_event_log.seq;ts=original.ts;event}) in
    let target=match posted.terminal_effect_receipt with
      | Some (Masc.Keeper_tool_execution.Surface_post_completed target) ->
          Masc.Keeper_surface_post.delivery_target_of_post_target target
      | None -> fail "actual post lost its terminal receipt" in
    let dashboard_effect=Events.External_effect_completed {target} in
    let verdict=Alcotest.testable Audit.pp_verdict Audit.equal_verdict in
    check verdict "actual same-turn post is the terminal Dashboard effect, not a second model reply"
      Audit.Match (Audit.compare (journal [dashboard_effect]) transcript.assistant);
    let mismatch=Audit.Mismatch [Audit.Assistant_text] in
    check verdict "turn label alone cannot suppress text validation" mismatch
      (Audit.compare (journal []) transcript.assistant);
    check verdict "another connector's effect cannot grant a Dashboard post" mismatch
      (Audit.compare (journal [Events.External_effect_completed
        {target=Masc.Keeper_surface_post.Delivered_to_discord {channel_id="different"}}]) transcript.assistant);
    check verdict "ordinary visible replies still compare their actual text" mismatch
      (Audit.compare (journal ~outcome:Masc.Keeper_turn_outcome.Visible_reply [dashboard_effect]) transcript.assistant);
    check verdict "a different turn cannot stand in for the original effect" mismatch
      (Audit.compare (journal [dashboard_effect]) [{original with turn_ref=Some
        (Ids.Turn_ref.make ~trace_id:"different-turn" ~absolute_turn:3)}]);
    check verdict "terminal effect without its stored post stays missing"
      (Audit.Mismatch [Audit.Missing_terminal_row]) (Audit.compare (journal [dashboard_effect]) []))

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "surface post original turn" ["persistence", [
    test_case "descriptor post retains exact turn through transcript and history" `Quick scenario]]
