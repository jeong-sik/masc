open Masc
let require = function Ok value -> value | Error message -> Alcotest.fail message
let member = Yojson.Safe.Util.member
let with_base f =
  let path = Filename.temp_file "keeper_draft_bundle" "" in Sys.remove path; Unix.mkdir path 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove path) (fun () -> f (Unix.realpath path))
let run_tool (tool : Agent_core.Tool.t) input =
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:(Random_id.uuid_v7 ()) ~turn:0
      ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Agent_core.Tool_contract.Serial }
      ~completion:(Agent_core.Tool.completion tool) in
  match tool.handler (Agent_core.Tool.Execution_env.create ~invocation ()) input with
  | Ok output -> Yojson.Safe.from_string output.Agent_core.Llm_provider.Types.content
  | Error error -> Alcotest.fail error.Agent_core.Llm_provider.Types.message
let test_bundle ~raised () = with_base (fun base_path ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) (fun () ->
    Config_dir_resolver.reset ();
    Fun.protect ~finally:Config_dir_resolver.reset (fun () ->
      ignore (Masc_test_deps.init_unified_tool_registry ());
      let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "draft-bundle"; "trace_id", `String "bundle-trace"]) |> require in
      let ctx = Keeper_tool_call_log.create_turn_ctx_cell () in
      Keeper_tool_call_log.set_turn_context ~cell:ctx ~agent_name:meta.name ~trace_id:"bundle-trace" ~turn:0 ~keeper_turn_id:17 ();
      let bundle = Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
          ~config:(Workspace.default_config base_path) ~meta
          ~publication_recovery:{ provider = Keeper_publication_recovery_availability.non_runtime_provider; keeper_name = meta.name }
          ~ctx_snapshot:(Keeper_context_runtime.create ~eio:true ~system_prompt:"shared artifact tool fixture") ~turn_ctx_cell:ctx () in
      let cleaned = ref false in
      let cleanup () = if not !cleaned then (cleaned := true; bundle.cleanup ()) in
      Fun.protect ~finally:cleanup (fun () ->
        let tool = match List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_artifact_draft") bundle.tools with
          | Some tool -> tool | None -> Alcotest.fail "Keeper bundle does not offer the draft tool" in
        let request = Published_artifact.request_of_json (`Assoc ["title", `String "bundle draft"; "summary", `String "fixture"; "format", `String "markdown"; "content", `String "alpha beta"]) |> require in
        let artifact, _ = Published_artifact_store.publish ~base_path ~author:"publisher" request |> Result.map_error Published_artifact_store.error_message |> require in
        let opened = run_tool tool (`Assoc ["action", `String "open"; "artifact_id", `String artifact.id; "revision", `Int 1]) in
        let target = member "target" opened |> Artifact_draft.target_of_json |> require in
        let observer = Artifact_draft_live.join ~source:Artifact_draft_live.Dashboard_connection ~base_path ~actor:"human" ~target in
        Fun.protect ~finally:(fun () -> Artifact_draft_live.leave observer) (fun () ->
          let peers () = match Artifact_draft_live.observe observer with Some (frame, _) -> member "peers" frame |> Yojson.Safe.Util.to_list | None -> Alcotest.fail "observer closed" in
          let chosen = run_tool tool (`Assoc ["action", `String "select"; "target", Artifact_draft.target_to_json target; "anchor", `Int 0; "head", `Int 5]) in
          Alcotest.(check bool) "tool returns direct reusable selection" true (member "position" (member "selection" chosen) <> `Null);
          let peer = List.find (fun peer -> member "actor" peer = `String meta.name) (peers ()) in
          let expected = Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~absolute_turn:17 |> Ids.Turn_ref.to_yojson in
          Alcotest.(check bool) "actual handler turn context owns presence" true (member "turn_ref" (member "source" peer) = expected);
          (try Fun.protect ~finally:cleanup (fun () -> if raised then raise Exit) with Exit -> ());
          Alcotest.(check int) "bundle cleanup removes Keeper presence" 1 (List.length (peers ())))))))
let () = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let tests, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer-dir"
    then ["normal tool bundle cleanup", `Quick, test_bundle ~raised:false; "raised tool bundle cleanup", `Quick, test_bundle ~raised:true], [|Sys.argv.(0)|] else [], Sys.argv in
  let run () = Alcotest.run ~argv "Keeper draft bundle lifetime" ["runtime", tests] in
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    if tests = [] then run () else Masc_test_deps.with_process_env "PATH" (Some (Sys.argv.(2) ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH"))) run))
