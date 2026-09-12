open Alcotest
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor
module Surface = Masc.Keeper_tool_composition_surface
module Log = Masc.Keeper_tool_call_log

let expect = function Ok value -> value | Error detail -> fail detail
let composition = {|[[compositions]]
name = "observed-page"
execution = "inline"
[[compositions.nodes]]
id = "page"
tool = "BrowserRead"
[compositions.nodes.input]
kind = "literal"
value = { lane = "automation", tabId = 7, mode = "scene" }
|}
let scene = `Assoc [
  "schema",`String "masc.browser.scene.v1"; "tabId",`Int 7;
  "documentId",`String "observed-document"; "url",`String "https://example.org/page";
  "title",`String "Observed page"; "view",`String "content"; "scope",`Null;
  "viewport",`Assoc ["width",`Int 800;"height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0];
  "chars",`Int 0; "truncated",`Bool false; "nodes",`List []]

let test_composition_retains_observation ~reject_schema () =
  let base = Filename.temp_dir "browser-composition-observation-" "" in
  Fun.protect ~finally:(fun () ->
    Browser_lane.install_automation_executor None;
    Log.reset_for_testing (); Time_compat.clear_clock (); Fs_compat.remove_tree base)
    (fun () -> Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Log.reset_for_testing (); Log.init ~base_path:base ();
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Page_scene {tab_id=7;view=Content;scope=None;_} ->
          Browser_lane.Answered (`Assoc ["ok",`Bool true;"data",scene])
        | _ -> fail "composition must perform only the observed scene read"));
      let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () |> List.map
        (fun (descriptor : Masc.Keeper_tool_descriptor.t) ->
          if reject_schema && descriptor.public_name="BrowserRead" then
            {descriptor with composable_output=Json_output {schema=`Assoc [
              "type",`String "object";
              "properties",`Assoc ["missingReceipt",`Assoc ["type",`String "string"]];
              "required",`List [`String "missingReceipt"]]}}
          else descriptor) in
      let catalog = Catalog.parse composition |> Result.map_error Catalog.error_to_string |> expect in
      let plan = Catalog.instantiate ~descriptors ~args:(`Assoc []) (List.hd (Catalog.entries catalog))
        |> Result.map_error Catalog.instantiation_error_to_string |> expect in
      let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String "observer"])
        |> expect in
      let config = Masc.Workspace.default_config base in
      let parent_invocation = Agent_core.Tool_contract.Invocation.create
        ~tool_use_id:"composition-parent" ~turn:1
        ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
        ~completion:Continue_after_success in
      let cell = Masc.Keeper_tool_call_log_context.create_cell () in
      let observe_node_result = Surface.For_testing.observe_node_result
        ~composition_tool:"keeper_compose_observed-page" ~composition_execution:Catalog.Inline
        ~composition_tool_kind:Masc.Keeper_tool_descriptor.Composition_tool
        ~composition_run_id:(Plan.Composition_run_id.fresh ()) ~parent_invocation ~meta
        ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell ()) in
      let produced = ref None in
      let dispatch ~tool_use_id:_ ~node:_ ~descriptor:_ ~schedule:_ ~input =
        let execution = Masc.Keeper_tool_in_process_runtime.handle_browser_read_with_outcome
            ~config ~meta ~args:input in
        let result = Tool_result.make_ok ~tool_name:"BrowserRead" ~start_time:0.
            ?data:execution.data ?metadata:execution.metadata ()
            |> Tool_result.with_retained_artifacts execution.retained_artifacts in
        check bool "producer read succeeds before schema validation" true
          (execution.disposition=Tool_result.Completed ());
        produced := Some result;
        Executor.dispatch_result result in
      let outcome = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch ~observe_node_result () in
      check bool "executor actually applies declared output schema" (not reject_schema) (Result.is_ok outcome);
      let result = match !produced with Some result -> result | None -> fail "read never dispatched" in
      let reference = match Tool_result.retained_artifacts result with
        | [reference] -> reference | _ -> fail "one retained scene required" in
      let rows = Log.read_recent ~keeper_name:meta.name () in
      let row = match rows with [row] -> row | _ -> fail "production observer must commit exactly one node row" in
      let open Yojson.Safe.Util in
      check bool "node log records schema rejection" (not reject_schema) (row |> member "success" |> to_bool);
      check string "node receipt preserves composition identity" "page" (row |> member "composition_node_id" |> to_string);
      let roots = Tool_output.normalized_artifact_refs_in_json (row |> member "artifact_refs") in
      check bool "retained producer root survives output schema rejection" true
        (List.exists (fun (root : Tool_output.artifact_ref) -> root.sha256=reference.sha256) roots);
      (match outcome with
       | Error _ -> ()
       | Ok nodes ->
         let payload = `List (List.map (fun (node : Executor.node_result) -> Tool_result.to_json node.result) nodes) in
         let aggregate = Tool_result.make_ok ~tool_name:"keeper_compose_observed-page" ~start_time:0. ~data:payload () in
         let projected = match Masc.Tool_bridge.to_agent_core_typed_result ~base_path:base
           ~model_projection:(Tool_output.Inline_up_to {maximum_bytes=100000}) aggregate with
           | Ok projected -> projected | Error error -> fail error.message in
         check string "successful composition payload stays inline" (Yojson.Safe.to_string payload) projected.content);
      let gc = Tool_blob_maintenance.run ~base_path:base ~mode:Observe_only
        |> Result.map_error Tool_blob_maintenance.error_to_string |> expect in
      check int "committed node roots retain the observation" 1 gc.live_references;
      check int "retained observation is not a GC candidate" 0 gc.candidates_recorded))

let () = run "browser observation composition" ["production observer",[
  test_case "success preserves inline payload and root" `Quick (test_composition_retains_observation ~reject_schema:false);
  test_case "schema rejection preserves original observation root" `Quick (test_composition_retains_observation ~reject_schema:true)]]
