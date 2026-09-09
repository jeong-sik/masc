open Alcotest
module Skills = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor

let entry () =
  let body = In_channel.with_open_bin "../skills/browser-live-click-regions/SKILL.md" In_channel.input_all in
  match Skills.parse_skill ~directory:"browser-live-click-regions" body with
  | Ok {surface=Skills.Composition entry;_} -> entry
  | _ -> fail "shipped browser composition is not a valid native MASC Skill"

let test_follow_output_contract () =
  let descriptor = List.find (fun (d : Masc.Keeper_tool_descriptor.t) ->
    d.public_name = "BrowserInteract") (Masc.Keeper_tool_descriptor.all_descriptors ()) in
  match descriptor.composable_output with
  | Masc.Keeper_tool_descriptor.Opaque_output -> fail "browser receipt is not composable"
  | Masc.Keeper_tool_descriptor.Json_output {schema} ->
    let open Yojson.Safe.Util in
    check string "destination reference has a declared string type" "string"
      (schema |> member "properties" |> member "destinationUrl" |> member "type" |> to_string);
    check bool "ordinary clicks need no destination receipt" false
      (List.mem (`String "destinationUrl") (schema |> member "required" |> to_list))

let test_click_then_regions ~fail_click ~fail_read () =
  Eio_main.run (fun _ ->
    let args = `Assoc ["clientId",`String "11111111-1111-4111-8111-111111111111";
      "tabId",`Int 7;"documentId",`String "observed";"nodeId",`String "link";
      "expectedUrl",`String "https://example.org/before"] in
    let plan = match Catalog.instantiate ~descriptors:(Masc.Keeper_tool_descriptor.all_descriptors ()) ~args (entry ()) with
      | Ok plan -> plan | Error e -> fail (Catalog.instantiation_error_to_string e) in
    let calls = ref [] in
    let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
      calls := !calls @ [node.Plan.tool_name];
      let result = match node.tool_name with
        | "BrowserInteract" ->
            check bool "follow uses the observed document and link" true
              (Yojson.Safe.Util.member "action" input=`String "follow_link"
               && Yojson.Safe.Util.member "documentId" input=`String "observed"
               && Yojson.Safe.Util.member "nodeId" input=`String "link");
            if fail_click then Tool_result.make_err ~tool_name:node.tool_name
              ~class_:Tool_result.Workflow_rejection ~start_time:0.0 "observed link detached"
            else Tool_result.make_ok ~tool_name:node.tool_name ~start_time:0.0
              ~data:(`Assoc ["tabId",`Int 7;"url",`String "https://example.org/after";
                "navigationSource",`Assoc ["url",`String "https://example.org/before";"documentId",`String "observed"];
                "destinationUrl",`String "https://example.org/after";"urlBefore",`String "https://example.org/before";"action",`String "follow_link"]) ()
        | "BrowserRead" ->
            check bool "follow-up reads regions on the pinned tab and client" true
              (Yojson.Safe.Util.member "tabId" input=`Int 7
               && Yojson.Safe.Util.member "clientId" input=Yojson.Safe.Util.member "clientId" args
               && Yojson.Safe.Util.member "mode" input=`String "regions"
               && Yojson.Safe.Util.member "expectedUrl" input=`String "https://example.org/after"
               && Yojson.Safe.Util.(input |> member "navigationSource" |> member "documentId")=`String "observed");
            if fail_read then Tool_result.make_err ~tool_name:node.tool_name
              ~class_:Tool_result.Workflow_rejection ~start_time:0.0 "region observation unavailable"
            else Tool_result.make_ok ~tool_name:node.tool_name ~start_time:0.0
              ~data:(`Assoc ["url",`String "https://example.org/after";"nodes",`List []]) ()
        | name -> fail ("unexpected composition action: " ^ name) in
      Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect result in
    let result = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
    if fail_click then (
      check bool "failure is retained" true (Result.is_error result);
      check (list string) "failed click is not retried and no read runs" ["BrowserInteract"] !calls)
    else if fail_read then (
      check (list string) "successful click is never replayed after read failure" ["BrowserInteract";"BrowserRead"] !calls;
      match result with
      | Ok _ -> fail "read failure disappeared"
      | Error failure -> check bool "settled click receipt remains available" true
          (List.exists (fun node -> Plan.Node_id.to_string node.Executor.node_id = "click"
            && (match node.result with Tool_result.Completed _ -> true | _ -> false)) failure.settled))
    else (
      check bool "composition completes" true (Result.is_ok result);
      check (list string) "exact ordered browser route" ["BrowserInteract";"BrowserRead"] !calls))

let () = run "browser composition" ["native skill",[
  test_case "runtime destination output contract" `Quick test_follow_output_contract;
  test_case "observed click then region read" `Quick (test_click_then_regions ~fail_click:false ~fail_read:false);
  test_case "failed click stops without replay" `Quick (test_click_then_regions ~fail_click:true ~fail_read:false);
  test_case "read failure retains successful click without replay" `Quick (test_click_then_regions ~fail_click:false ~fail_read:true)]]
