open Alcotest
module Skills = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor

let skill_entry name =
  let path = Filename.concat (Filename.concat "../skills" name) "SKILL.md" in
  let body = In_channel.with_open_bin path In_channel.input_all in
  match Skills.parse_skill ~directory:name body with
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
    check string "activation exposes a typed active receipt" "boolean"
      (schema |> member "properties" |> member "active" |> member "type" |> to_string);
    check bool "other interactions need no active receipt" false
      (List.mem (`String "active") (schema |> member "required" |> to_list));
    check bool "ordinary clicks need no destination receipt" false
      (List.mem (`String "destinationUrl") (schema |> member "required" |> to_list))

type navigation_case = Navigated | Navigation_failed | Read_failed | Invalid_receipt
type observation = Regions | Content

let test_follow_then_read observation case () =
  Eio_main.run (fun _ ->
    let skill_name, read_mode = match observation with
      | Regions -> "browser-live-click-regions", "regions"
      | Content -> "browser-live-click-content", "scene" in
    let args = `Assoc ["clientId",`String "11111111-1111-4111-8111-111111111111";
      "tabId",`Int 7;"documentId",`String "observed";"nodeId",`String "link";
      "expectedUrl",`String "https://example.org/before"] in
    let entry = skill_entry skill_name in
    check string "native callable skill name"
      ("keeper_compose_" ^ skill_name) (Catalog.tool_name entry);
    let plan = match Catalog.instantiate ~descriptors:(Masc.Keeper_tool_descriptor.all_descriptors ()) ~args entry with
      | Ok plan -> plan | Error e -> fail (Catalog.instantiation_error_to_string e) in
    let calls = ref [] in
    let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
      calls := !calls @ [node.Plan.tool_name];
      let result = match node.tool_name with
        | "BrowserInteract" ->
            check bool "follow pins the observed client, tab, URL, document and link" true
              (Yojson.Safe.Util.member "action" input=`String "follow_link"
               && Yojson.Safe.Util.member "lane" input=`String "live"
               && Yojson.Safe.Util.member "clientId" input=Yojson.Safe.Util.member "clientId" args
               && Yojson.Safe.Util.member "tabId" input=`Int 7
               && Yojson.Safe.Util.member "expectedUrl" input=`String "https://example.org/before"
               && Yojson.Safe.Util.member "documentId" input=`String "observed"
               && Yojson.Safe.Util.member "nodeId" input=`String "link");
            (match case with
            | Navigation_failed -> Tool_result.make_err ~tool_name:node.tool_name
                ~class_:Tool_result.Workflow_rejection ~start_time:0.0 "observed link detached"
            | Invalid_receipt -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time:0.0
                ~data:(`Assoc ["tabId",`Int 7;"action",`String "follow_link"]) ()
            | Navigated | Read_failed -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time:0.0
              ~data:(`Assoc ["tabId",`Int 7;"url",`String "https://example.org/after";
                "navigationSource",`Assoc ["url",`String "https://example.org/before";"documentId",`String "observed"];
                "destinationUrl",`String "https://example.org/after";"urlBefore",`String "https://example.org/before";"action",`String "follow_link"]) ())
        | "BrowserRead" ->
            check bool "follow-up reads the selected view on the pinned tab and client" true
              (Yojson.Safe.Util.member "tabId" input=`Int 7
               && Yojson.Safe.Util.member "lane" input=`String "live"
               && Yojson.Safe.Util.member "clientId" input=Yojson.Safe.Util.member "clientId" args
               && Yojson.Safe.Util.member "mode" input=`String read_mode
               && Yojson.Safe.Util.member "expectedUrl" input=`String "https://example.org/after"
               && Yojson.Safe.Util.(input |> member "navigationSource" |> member "url")=`String "https://example.org/before"
               && Yojson.Safe.Util.(input |> member "navigationSource" |> member "documentId")=`String "observed");
            (match case with
            | Read_failed -> Tool_result.make_err ~tool_name:node.tool_name
                ~class_:Tool_result.Workflow_rejection ~start_time:0.0 "observation unavailable"
            | Navigated -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time:0.0
                ~data:(`Assoc ["url",`String "https://example.org/after";"nodes",`List []]) ()
            | Navigation_failed | Invalid_receipt -> fail "read ran without a valid follow receipt")
        | name -> fail ("unexpected composition action: " ^ name) in
      Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect result in
    let result = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
    match case with
    | Navigation_failed | Invalid_receipt -> (
      check bool "failure is retained" true (Result.is_error result);
      check (list string) "failed click is not retried and no read runs" ["BrowserInteract"] !calls)
    | Read_failed -> (
      check (list string) "successful click is never replayed after read failure" ["BrowserInteract";"BrowserRead"] !calls;
      match result with
      | Ok _ -> fail "read failure disappeared"
      | Error failure ->
          check bool "completed follow remains a recorded effect after read failure" true
            (failure.effect_disposition = Tool_result.Proven_post_effect);
          check bool "settled click receipt remains available" true
          (List.exists (fun node -> Plan.Node_id.to_string node.Executor.node_id = "click"
            && (match node.result with Tool_result.Completed _ -> true | _ -> false)) failure.settled))
    | Navigated -> (
      check bool "composition completes" true (Result.is_ok result);
      check (list string) "exact ordered browser route" ["BrowserInteract";"BrowserRead"] !calls))

let test_navigate_then_read observation case () =
  Eio_main.run (fun _ ->
    let skill_name, read_mode = match observation with
      | Regions -> "browser-navigate-regions", "regions"
      | Content -> "browser-navigate-content", "scene" in
    let requested_url = "https://example.org/start" in
    let landing_url = "https://example.org/redirected" in
    let args = `Assoc [ "tabId", `Int 7; "url", `String requested_url ] in
    let entry = skill_entry skill_name in
    check string "native callable skill name"
      ("keeper_compose_" ^ skill_name) (Catalog.tool_name entry);
    let plan =
      match Catalog.instantiate
        ~descriptors:(Masc.Keeper_tool_descriptor.all_descriptors ()) ~args entry with
      | Ok plan -> plan
      | Error error -> fail (Catalog.instantiation_error_to_string error)
    in
    let calls = ref [] in
    let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
      calls := !calls @ [ node.Plan.tool_name ];
      let ok data = Tool_result.make_ok ~tool_name:node.tool_name ~start_time:0.0 ~data () in
      let rejected message = Tool_result.make_err ~tool_name:node.tool_name
        ~class_:Tool_result.Workflow_rejection ~start_time:0.0 message in
      let result =
        match node.tool_name with
        | "BrowserGoto" ->
          check bool "navigation pins the observed tab and requested URL" true
            (input = args);
          (match case with
           | Navigation_failed -> rejected "navigation unavailable"
           | Invalid_receipt -> ok (`Assoc [ "title", `String "Landing page" ])
           | Navigated | Read_failed ->
             ok (`Assoc [ "url", `String landing_url; "title", `String "Landing page" ]))
        | "BrowserRead" ->
          let open Yojson.Safe.Util in
          check string "explicit automation lane" "automation"
            (input |> member "lane" |> to_string);
          check int "same observed tab" 7 (input |> member "tabId" |> to_int);
          check string "the selected observation precedes the site decision" read_mode
            (input |> member "mode" |> to_string);
          check string "guard follows the actual redirect receipt" landing_url
            (input |> member "expectedUrl" |> to_string);
          (match case with
           | Read_failed -> rejected "observation unavailable"
           | Navigated -> ok (`Assoc [ "url", `String landing_url; "nodes", `List [] ])
           | Navigation_failed | Invalid_receipt -> fail "read ran without a valid receipt")
        | name -> fail ("unexpected composition tool: " ^ name)
      in
      Executor.dispatch_result result
    in
    let result = Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () in
    match case with
    | Navigated ->
      check bool "navigation and observation complete" true (Result.is_ok result);
      check (list string) "one ordered pair" [ "BrowserGoto"; "BrowserRead" ] !calls
    | Navigation_failed | Invalid_receipt ->
      check bool "failure remains visible" true (Result.is_error result);
      check (list string) "no dependent read or navigation retry" [ "BrowserGoto" ] !calls
    | Read_failed ->
      check (list string) "failed observation does not replay navigation"
        [ "BrowserGoto"; "BrowserRead" ] !calls;
      (match result with
       | Ok _ -> fail "read failure disappeared"
       | Error failure ->
         check bool "settlement records that navigation already took effect" true
           (failure.effect_disposition = Tool_result.Proven_post_effect);
         check bool "completed navigation remains available for recovery" true
           (List.exists (fun node ->
              Plan.Node_id.to_string node.Executor.node_id = "navigate"
              && match node.result with Tool_result.Completed _ -> true | _ -> false)
              failure.settled)))
;;

let () = run "browser composition" ["native skill",[
  test_case "runtime destination output contract" `Quick test_follow_output_contract;
  test_case "observed click then region read" `Quick (test_follow_then_read Regions Navigated);
  test_case "failed click stops without replay" `Quick (test_follow_then_read Regions Navigation_failed);
  test_case "read failure retains successful click without replay" `Quick (test_follow_then_read Regions Read_failed);
  test_case "region read rejects malformed follow receipt" `Quick (test_follow_then_read Regions Invalid_receipt);
  test_case "observed click then visible content" `Quick (test_follow_then_read Content Navigated);
  test_case "content follow failure stops without replay" `Quick (test_follow_then_read Content Navigation_failed);
  test_case "content read failure retains follow receipt" `Quick (test_follow_then_read Content Read_failed);
  test_case "content read rejects malformed follow receipt" `Quick (test_follow_then_read Content Invalid_receipt);
  test_case "navigation uses redirected landing URL" `Quick (test_navigate_then_read Regions Navigated);
  test_case "navigation failure stops before read" `Quick (test_navigate_then_read Regions Navigation_failed);
  test_case "read failure retains navigation receipt" `Quick (test_navigate_then_read Regions Read_failed);
  test_case "malformed navigation receipt stops before read" `Quick (test_navigate_then_read Regions Invalid_receipt);
  test_case "content uses redirected landing URL" `Quick (test_navigate_then_read Content Navigated);
  test_case "content navigation failure stops before read" `Quick (test_navigate_then_read Content Navigation_failed);
  test_case "content read failure retains navigation receipt" `Quick (test_navigate_then_read Content Read_failed);
  test_case "content rejects malformed navigation receipt" `Quick (test_navigate_then_read Content Invalid_receipt)]]
