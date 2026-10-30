open Masc
let require = function Ok value -> value | Error message -> Alcotest.fail message
let member = Yojson.Safe.Util.member
let with_base f =
  let path = Filename.temp_file "keeper_draft_bundle" "" in Sys.remove path; Unix.mkdir path 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove path) (fun () -> f (Unix.realpath path))
let run_tool_raw (tool : Agent_core.Tool.t) input =
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:(Random_id.uuid_v7 ()) ~turn:0
      ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Agent_core.Tool_contract.Serial }
      ~completion:(Agent_core.Tool.completion tool) in
  match tool.handler (Agent_core.Tool.Execution_env.create ~invocation ()) input with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error error -> Alcotest.fail error.Agent_core.Llm_provider.Types.message
let run_tool tool input = Yojson.Safe.from_string (run_tool_raw tool input)
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
let test_discovery_bundle () = with_base (fun base_path ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) (fun () ->
    Config_dir_resolver.reset ();
    Fun.protect ~finally:Config_dir_resolver.reset (fun () ->
      ignore (Masc_test_deps.init_unified_tool_registry ());
      let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "other-editor"; "trace_id", `String "discovery-trace"]) |> require in
      let ctx = Keeper_tool_call_log.create_turn_ctx_cell () in
      Keeper_tool_call_log.set_turn_context ~cell:ctx ~agent_name:meta.name ~trace_id:"discovery-trace" ~turn:0 ~keeper_turn_id:17 ();
      let bundle = Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
          ~config:(Workspace.default_config base_path) ~meta
          ~publication_recovery:{ provider = Keeper_publication_recovery_availability.non_runtime_provider; keeper_name = meta.name }
          ~ctx_snapshot:(Keeper_context_runtime.create ~eio:true ~system_prompt:"artifact discovery fixture") ~turn_ctx_cell:ctx () in
      Fun.protect ~finally:bundle.cleanup (fun () ->
        let tool = match List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_artifact_draft") bundle.tools with
          | Some tool -> tool | None -> Alcotest.fail "Keeper bundle does not offer the draft tool" in
        let request = Published_artifact.request_of_json (`Assoc ["title", `String "shared report"; "summary", `String "fixture";
          "format", `String "markdown"; "content", `String "other author's exact source"]) |> require in
        let artifact, _ = Published_artifact_store.publish ~base_path ~author:"first-author" request
          |> Result.map_error Published_artifact_store.error_message |> require in
        let found = run_tool tool (`Assoc ["action", `String "find"; "query", `String "shared report"]) in
        let candidates = member "artifacts" found |> Yojson.Safe.Util.to_list in
        Alcotest.(check string) "bundle finds another author" artifact.id
          (member "id" (List.hd candidates) |> Yojson.Safe.Util.to_string);
        let published = run_tool tool (`Assoc ["action", `String "published"; "artifact_id", `String artifact.id]) in
        let data = member "structured_content" published in
        Alcotest.(check string) "model receives the published source" "other author's exact source"
          (member "content" data |> Yojson.Safe.Util.to_string);
        Alcotest.(check bool) "typed publication has a durable result manifest" true
          (member "artifact_manifest" published <> `Null);
        let source = String.concat "" (List.init 2000 (fun i ->
          Printf.sprintf "줄 %04d: \"source\"\r\n" i)) in
        let update = Published_artifact.request_of_json (`Assoc [
          "id", `String artifact.id; "expected_revision", `Int 1;
          "title", `String "shared report"; "summary", `String "large revision";
          "format", `String "markdown"; "content", `String source]) |> require in
        ignore (Published_artifact_store.publish ~base_path ~author:"second-author" update
          |> Result.map_error Published_artifact_store.error_message |> require);
        let output = run_tool_raw tool (`Assoc ["action", `String "published"; "artifact_id", `String artifact.id]) in
        let reference = match Tool_output.decode_from_agent_core output with
          | Tool_output.Decoded reference -> reference
          | Tool_output.Not_marker -> Alcotest.fail "large published result did not produce a marker"
          | Tool_output.Invalid_marker { detail } -> Alcotest.fail detail in
        Alcotest.(check string) "marker identifies a result manifest"
          Tool_output.artifact_manifest_mime reference.mime;
        Alcotest.(check bool) "manifest exceeds the inline limit" true
          (reference.bytes > Common.max_tool_result_wire_bytes);
        let reader = match List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_artifact_read") bundle.tools with
          | Some tool -> tool | None -> Alcotest.fail "Keeper bundle does not offer the artifact reader" in
        let bytes = Buffer.create reference.bytes in
        let rec collect offset pages =
          let wire = run_tool_raw reader (`Assoc ["sha256", `String reference.sha256; "offset", `Int offset]) in
          Alcotest.(check bool) "reader page stays inline" true
            (not (Tool_output.is_marker wire) && String.length wire <= Common.max_tool_result_wire_bytes);
          let page = Yojson.Safe.from_string wire in
          Alcotest.(check bool) "reader page succeeded" true (member "ok" page = `Bool true);
          Alcotest.(check string) "reader kept the exact reference" reference.sha256
            (member "sha256" page |> Yojson.Safe.Util.to_string);
          Alcotest.(check int) "reader continued at requested offset" offset
            (member "offset" page |> Yojson.Safe.Util.to_int);
          Alcotest.(check int) "reader preserved total size" reference.bytes
            (member "total_bytes" page |> Yojson.Safe.Util.to_int);
          Alcotest.(check string) "reader returned UTF-8" "utf-8"
            (member "encoding" page |> Yojson.Safe.Util.to_string);
          let content = member "content" page |> Yojson.Safe.Util.to_string in
          let next = member "next_offset" page |> Yojson.Safe.Util.to_int in
          Alcotest.(check int) "page byte offset matches payload" next (offset + String.length content);
          Alcotest.(check bool) "each page advances" true (next > offset);
          Buffer.add_string bytes content;
          match member "eof" page with
          | `Bool true ->
            Alcotest.(check int) "last page reaches end" reference.bytes next;
            pages + 1
          | `Bool false -> collect next (pages + 1)
          | _ -> Alcotest.fail "reader page lacks EOF" in
        let pages = collect 0 0 in
        Alcotest.(check bool) "large manifest requires multiple reader pages" true (pages > 1);
        let restored = Buffer.contents bytes |> Yojson.Safe.from_string in
        let data = match Tool_output.artifact_manifest_of_json restored with
          | Tool_output.Decoded_artifact_manifest { structured_content; _ } -> structured_content
          | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ ->
            Alcotest.fail "reader did not restore the published result manifest" in
        let latest = member "artifact" data in
        Alcotest.(check string) "restored publication identity" artifact.id
          (member "id" latest |> Yojson.Safe.Util.to_string);
        Alcotest.(check int) "restored latest revision" 2
          (member "revision" latest |> Yojson.Safe.Util.to_int);
        Alcotest.(check string) "restored exact published bytes" source
          (member "content" data |> Yojson.Safe.Util.to_string)))))
let () = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let tests, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer-dir"
    then ["normal tool bundle cleanup", `Quick, test_bundle ~raised:false; "raised tool bundle cleanup", `Quick, test_bundle ~raised:true], [|Sys.argv.(0)|] else [], Sys.argv in
  let run () = Alcotest.run ~argv "Keeper draft bundle lifetime"
      ["runtime", ("workspace discovery through model bundle", `Quick, test_discovery_bundle) :: tests] in
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    if tests = [] then run () else Masc_test_deps.with_process_env "PATH" (Some (Sys.argv.(2) ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH"))) run))
