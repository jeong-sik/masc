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

(* Both are held back from Agent Core requests until keeper_tool_search names
   them. Measured 2026-09-18..24: 2 and 14 turns used them, while their 1,980
   and 1,583 byte schemas rode every request. *)
let test_is_deferred skill_name () =
  let entry = skill_entry skill_name in
  check bool "declared defer_loading = true" true
    (entry.Catalog.loading = Tool_definition_toml.Deferrable);
  (* A deferred tool is picked from keeper_tool_search by its one-line
     summary, so the first line is a whole sentence the cut leaves alone. *)
  match entry.Catalog.description with
  | None -> fail "a deferred composition needs a description to be picked by"
  | Some description ->
    let first_line = List.hd (String.split_on_char '\n' description) in
    check string "the summary is the whole first line" first_line
      (Masc.Keeper_identity_tool_search.summary_of description)

type navigation_case = Navigated | Navigation_failed | Read_failed | Invalid_receipt
type observation = Regions | Content

let follow_skill = "browser-live-follow-read"

let read_mode = function
  | Regions -> "regions"
  | Content -> "scene"

(* The shipped composition offers two reads and nothing else.
   BrowserRead itself also takes "text"; the materialized tools refuse it in
   Agent-Core's input check (test_keeper_tool_dispatch_runtime). *)
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
     |> member "required" |> to_list |> List.mem (`String "mode"))

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
    let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input () =
      calls := !calls @ [node.Plan.tool_name];
      let result = match node.tool_name with
        | "BrowserInteract" ->
            check bool "follow pins the observed client, tab, URL, document and link" true
              (Yojson.Safe.Util.member "action" input=`String "follow_link"
               && Yojson.Safe.Util.member "clientId" input=Yojson.Safe.Util.member "clientId" args
               && Yojson.Safe.Util.member "tabId" input=`Int 7
               && Yojson.Safe.Util.member "expectedUrl" input=`String "https://example.org/before"
               && Yojson.Safe.Util.member "documentId" input=`String "observed"
               && Yojson.Safe.Util.member "nodeId" input=`String "link");
            (match case with
            | Navigation_failed -> Tool_result.make_err ~tool_name:node.tool_name
                ~class_:Tool_result.Workflow_rejection ~start_time:(Tool_timing.start ()) "observed link detached"
            | Invalid_receipt -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
                ~data:(`Assoc ["tabId",`Int 7;"action",`String "follow_link"]) ()
            | Navigated | Read_failed -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
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
                ~class_:Tool_result.Workflow_rejection ~start_time:(Tool_timing.start ()) "observation unavailable"
            | Navigated -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
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

let () = run "browser composition" ["native skill",[
  test_case "runtime destination output contract" `Quick test_follow_output_contract;
  test_case "live follow description is one text" `Quick (test_description_is_one_text follow_skill);
  test_case "live follow is deferred" `Quick (test_is_deferred follow_skill);
  test_case "live follow offers only scene and regions" `Quick (test_mode_is_a_closed_choice follow_skill);
  test_case "observed follow then region read" `Quick (test_follow_then_read Regions Navigated);
  test_case "failed follow stops without replay" `Quick (test_follow_then_read Regions Navigation_failed);
  test_case "read failure retains successful follow without replay" `Quick (test_follow_then_read Regions Read_failed);
  test_case "region read rejects malformed follow receipt" `Quick (test_follow_then_read Regions Invalid_receipt);
  test_case "observed follow then visible content" `Quick (test_follow_then_read Content Navigated);
  test_case "content follow failure stops without replay" `Quick (test_follow_then_read Content Navigation_failed);
  test_case "content read failure retains follow receipt" `Quick (test_follow_then_read Content Read_failed);
  test_case "content read rejects malformed follow receipt" `Quick (test_follow_then_read Content Invalid_receipt)]]
