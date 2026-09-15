open Alcotest
module Skills = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor

let shipped_skill name =
  let path = Filename.concat (Filename.concat "../skills" name) "SKILL.md" in
  let body = In_channel.with_open_bin path In_channel.input_all in
  match Skills.parse_skill ~directory:name body with
  | Ok skill -> skill
  | Error _ -> fail "shipped browser composition is not a valid native MASC Skill"

let skill_entry name =
  match (shipped_skill name).Skills.surface with
  | Skills.Composition entry -> entry
  | Skills.Instruction -> fail "shipped browser composition is not a valid native MASC Skill"

(* A Keeper meets this text in two places: as the keeper_compose_<name> tool
   description (the TOML copy) and as the capability search hit (the
   frontmatter copy). They are one text. Only the frontmatter parser bounds its
   length, so keeping the copies equal also keeps the tool description inside
   that bound. *)
let test_description_is_one_text skill_name () =
  let skill = shipped_skill skill_name in
  match skill.Skills.surface with
  | Skills.Instruction -> fail "shipped browser composition declares no composition"
  | Skills.Composition entry ->
    (match entry.Catalog.description with
     | None -> fail "the tool would show only the generic composition sentence"
     | Some description ->
       check bool "the tool description says something" false
         (String.equal description "");
       check string "capability search shows the tool description"
         description skill.Skills.description)

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

let follow_skill = "browser-live-follow-read"
let navigate_skill = "browser-navigate-read"

let read_mode = function
  | Regions -> "regions"
  | Content -> "scene"

(* One call through Agent-Core's own tool execution, on a tool built the way
   the composition surface builds a composition tool: the same bridge
   constructor, name and generated input schema. The handler stands in for the
   composition handler and only records that it ran. *)
let call_through_agent_core entry args =
  let tool_name = Catalog.tool_name entry in
  let handler_ran = ref false in
  let tool =
    Masc.Tool_bridge.agent_core_tool_of_masc_with_execution_env
      ~name:tool_name ~description:"shipped composition input schema probe"
      ~input_schema:(Catalog.input_schema_of_params entry.Catalog.params)
      (fun _execution_env _input ->
         handler_ran := true;
         Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String "ran") ())
  in
  let invocation =
    Agent_core.Tool_contract.Invocation.create ~tool_use_id:"browser-composition-probe"
      ~turn:1 ~completion:Agent_core.Tool_contract.Continue_after_success
      ~schedule:{ Agent_core.Tool_contract.planned_index = 0; batch_index = 0; batch_size = 1;
                  execution_mode = Agent_core.Tool_contract.Serial }
  in
  match
    Agent_core.Agent_tools.find_and_execute_tool
      ~context:(Agent_core.Context.create_sync ()) ~tools:[ tool ]
      ~hooks:Agent_core.Hooks.empty ~event_bus:None ~tracer:Agent_core.Tracing.null
      ~agent_name:"browser-composition-probe" ~invocation tool_name args
  with
  | Ok result -> result.Agent_core.Agent_tools.outcome, !handler_ran
  | Error (Agent_core.Agent_tools.Hook_execution_failed { detail; _ }) ->
    fail ("a tool call with no hooks failed in a hook: " ^ detail)

(* Both shipped compositions offer the same two reads and nothing else. The
   node tool, BrowserRead, also takes "text", so a value outside the declared
   members has to be refused before the composition runs rather than run as
   another read. Agent-Core refuses it while checking the call against the
   composition's input schema, before the composition handler. *)
let test_mode_is_a_closed_choice skill_name () =
  let entry = skill_entry skill_name in
  let open Yojson.Safe.Util in
  let mode =
    Catalog.input_schema_of_params entry.Catalog.params
    |> member "properties" |> member "mode"
  in
  check (list string) "the model is offered exactly scene and regions"
    [ "scene"; "regions" ]
    (mode |> member "enum" |> to_list |> List.map to_string);
  check bool "mode is required" true
    (Catalog.input_schema_of_params entry.Catalog.params
     |> member "required" |> to_list |> List.mem (`String "mode"));
  (* Every other argument is valid for whichever composition declares it, so
     the only thing Agent-Core can refuse is the mode. *)
  let valid_arguments =
    [ "clientId", `String "11111111-1111-4111-8111-111111111111"
    ; "tabId", `Int 7
    ; "documentId", `String "observed"
    ; "nodeId", `String "link"
    ; "expectedUrl", `String "https://example.org/before"
    ; "url", `String "https://example.org/start"
    ]
  in
  let declared name =
    List.exists
      (fun param -> String.equal param.Catalog.param_name name)
      entry.Catalog.params
  in
  let args mode =
    `Assoc
      (List.filter (fun (name, _) -> declared name) valid_arguments
       @ [ "mode", `String mode ])
  in
  Eio_main.run (fun _ ->
    List.iter
      (fun mode ->
         match call_through_agent_core entry (args mode) with
         | Agent_core.Types.Tool_succeeded, true -> ()
         | (Agent_core.Types.Tool_succeeded | Agent_core.Types.Tool_failed _), _ ->
           fail ("declared mode " ^ mode ^ " did not reach the composition handler"))
      [ "scene"; "regions" ];
    match call_through_agent_core entry (args "text") with
    | Agent_core.Types.Tool_failed { failure_kind = Agent_core.Types.Validation_error; _ }, false ->
      ()
    | (Agent_core.Types.Tool_succeeded | Agent_core.Types.Tool_failed _), _ ->
      fail "a read mode outside scene and regions was not refused before the handler")

let test_follow_then_read observation case () =
  Eio_main.run (fun _ ->
    let skill_name = follow_skill in
    let read_mode = read_mode observation in
    let args = `Assoc ["clientId",`String "11111111-1111-4111-8111-111111111111";
      "tabId",`Int 7;"documentId",`String "observed";"nodeId",`String "link";
      "expectedUrl",`String "https://example.org/before";"mode",`String read_mode] in
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
          (List.exists (fun node -> Plan.Node_id.to_string node.Executor.node_id = "follow"
            && (match node.result with Tool_result.Completed _ -> true | _ -> false)) failure.settled))
    | Navigated -> (
      check bool "composition completes" true (Result.is_ok result);
      check (list string) "exact ordered browser route" ["BrowserInteract";"BrowserRead"] !calls))

let test_navigate_then_read observation case () =
  Eio_main.run (fun _ ->
    let skill_name = navigate_skill in
    let read_mode = read_mode observation in
    let requested_url = "https://example.org/start" in
    let landing_url = "https://example.org/redirected" in
    let navigation = `Assoc [ "tabId", `Int 7; "url", `String requested_url ] in
    let args =
      `Assoc [ "tabId", `Int 7; "url", `String requested_url; "mode", `String read_mode ]
    in
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
            (input = navigation);
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
  test_case "live follow description is one text" `Quick (test_description_is_one_text follow_skill);
  test_case "navigation description is one text" `Quick (test_description_is_one_text navigate_skill);
  test_case "live follow offers only scene and regions" `Quick (test_mode_is_a_closed_choice follow_skill);
  test_case "navigation offers only scene and regions" `Quick (test_mode_is_a_closed_choice navigate_skill);
  test_case "observed follow then region read" `Quick (test_follow_then_read Regions Navigated);
  test_case "failed follow stops without replay" `Quick (test_follow_then_read Regions Navigation_failed);
  test_case "read failure retains successful follow without replay" `Quick (test_follow_then_read Regions Read_failed);
  test_case "region read rejects malformed follow receipt" `Quick (test_follow_then_read Regions Invalid_receipt);
  test_case "observed follow then visible content" `Quick (test_follow_then_read Content Navigated);
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
