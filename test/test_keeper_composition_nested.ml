open Alcotest
module Nested = Masc.Keeper_composition_nested
module Plan = Masc.Keeper_tool_plan
module Surface = Masc.Keeper_capability_surface
module Snapshot = Skill_catalog_snapshot
module Executor = Masc.Keeper_tool_plan_executor

let require label = function Ok value -> value | Error _ -> fail label

let document ?(execution = "inline") ?(policy = "continue_independent") ?(suffix = "") () =
  Printf.sprintf {|---
name: nested-read
description: Read an exact lane profile and query fixed prior evidence.
---

```toml composition
[[compositions]]
name = "nested-read"
execution = %S
branch_failure_policy = %S

[[compositions.params]]
name = "query"
type = "string"
enum = ["docker", "host"]
description = "Exact fixture query."

[[compositions.nodes]]
id = "lane/~profile"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "evidence"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"

[[compositions.exports]]
name = "profile/~name"
node = "lane/~profile"
pointer = "/profile"
```
%s
|} execution policy suffix
;;

let fixture_snapshot ?(source = document ()) ?(skill_names = None) ?(tool_deny = []) () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let config = Skill_source_config.parse_text
      "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n"
      |> require "Skill config" in
  let scans = List.map (fun source_config ->
      let resolved = Skill_source_config.resolve ~base_path:"/nested-fixture" ~user_home:None source_config in
      let resolved_path = match resolved.Skill_source_config.resolution with
        | Resolved path -> path
        | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ -> fail "source resolution" in
      { Snapshot.source = resolved
      ; observation = Snapshot.Source_ready { resolved_path; candidates = 1 }
      ; candidates = [ Snapshot.Candidate_document { directory = "nested-read"; source_text = source } ] }) config.sources in
  let snapshot = Snapshot.configured ~config scans |> require "frozen snapshot" in
  let global_skill_catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot snapshot in
  (match diagnostics with
   | [] -> ()
   | diagnostics ->
     let details =
       List.map
         (fun (diagnostic : Masc.Keeper_skill_catalog.projection_diagnostic) ->
            Printf.sprintf "%s: %s"
              (Snapshot.identity_to_yojson diagnostic.identity |> Yojson.Safe.to_string)
              (Masc.Keeper_skill_catalog.error_to_string diagnostic.error))
         diagnostics
       |> String.concat "\n"
     in
     failf "invalid fixture catalog:\n%s" details);
  let surface = Surface.create ~tool_deny ~sandbox_profile:Masc.Keeper_types_profile.Docker
      ~skill_names ~global_skill_catalog ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot snapshot)
      ~task_skills:[] in
  let reference = match Snapshot.entries snapshot with
    | [ entry ] -> Snapshot.entry_reference entry | _ -> fail "one exact entry" in
  surface, reference, snapshot
;;

let fixture ?source ?skill_names ?tool_deny () =
  let surface, reference, _ = fixture_snapshot ?source ?skill_names ?tool_deny () in
  surface, reference
;;

let nested ?(args = `Assoc [ "query", `String "docker" ]) ?(after = []) id reference = `Assoc
    ([ "id", `String id; "skill_reference", Skill_reference.to_yojson reference; "args", args ]
     @ if after = [] then [] else [ "after", `List (List.map (fun id -> `String id) after) ])
;;

let leaf ?(after = []) id = `Assoc
    [ "id", `String id; "tool", `String "keeper_lane_status"
    ; "after", `List (List.map (fun id -> `String id) after) ]
;;

let consumer id child pointer = `Assoc
    [ "id", `String id; "tool", `String "keeper_memory_search"
    ; "input", `Assoc [ "kind", `String "object"; "fields", `List
        [ `Assoc [ "name", `String "query"; "value", `Assoc
            [ "kind", `String "output"; "node", `String child; "pointer", `String pointer ] ] ] ] ]
;;

let request ?(policy = "continue_independent") ?(exports = []) nodes = `Assoc
    [ "nodes", `List nodes; "branch_failure_policy", `String policy; "exports", `List exports ]
;;

let exported name node pointer = `Assoc [ "name", `String name; "node", `String node; "pointer", `String pointer ]
let compile surface json = match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Inline ~capability_surface:surface json with
  | Ok value -> value | Error error -> fail (Yojson.Safe.to_string (Nested.error_to_json error))
let pointer = "/profile~1~0name"

let test_repeated_child_identity_bindings_and_output_mapping () =
  let surface, reference = fixture () in
  let alias = "a/quote\"~" in
  (* This ordinary ID looks like an expanded child path, but is a different
     structured path and must remain a distinct invocation. *)
  let lookalike = Yojson.Safe.to_string (`List [ `String alias; `String "lane/~profile" ]) in
  let compiled = compile surface (request
      ~exports:[ exported "answer" alias pointer ]
      [ nested alias reference; nested "b" reference; leaf lookalike; consumer "use-answer" alias pointer ]) in
  let plan = Nested.plan compiled in
  check int "two exact reused calls" 2 (List.length (Nested.calls compiled));
  check int "six actual leaves" 6 (List.length (Plan.nodes plan));
  let ids = List.map (fun (node : Plan.node) -> Plan.Node_id.to_string node.id) (Plan.nodes plan) in
  check int "no namespace collision" 6 (List.length (List.sort_uniq String.compare ids));
  let call = List.hd (Nested.calls compiled) in
  check bool "exact revision retained" true (Skill_reference.equal reference call.reference);
  let args = match call.arguments with Nested.Fixed args -> args | Upstream _ -> fail "expected fixed arguments" in
  check bool "canonical fixed bindings retained" true (Yojson.Safe.equal args (`Assoc [ "query", `String "docker" ]));
  let mapping = match call.scope with Nested.Inline {mapping;_} -> mapping | Nested.Async _ -> fail "inline scope" in
  let good_id = List.find (fun (id, _) -> Plan.Node_id.to_string id = "lane/~profile") mapping |> snd in
  let downstream = Plan.nodes plan |> List.find (fun (node : Plan.node) -> node.tool_name = "keeper_memory_search"
      && List.length (Plan.dependencies node) = 2) in
  check (list string) "consumer depends on whole child scope"
    (List.map (fun (_, id) -> Plan.Node_id.to_string id) mapping |> List.sort String.compare)
    (Plan.dependencies downstream |> List.map Plan.Node_id.to_string |> List.sort String.compare);
  let export = List.hd (Plan.exports plan) in
  check bool "named child export maps exact producer" true (Plan.Node_id.equal good_id export.node_id);
  check string "escaped export name resolves to producer pointer" "/profile" (Plan.Json_pointer.to_string export.pointer);
  let evidence = match Nested.calls_to_json compiled with
    | `List (first :: _) -> first | _ -> fail "durable nested evidence missing" in
  check bool "durable evidence preserves exact pinned reference" true
    (Yojson.Safe.equal (Yojson.Safe.Util.member "reference" evidence) (Skill_reference.to_yojson reference));
  check bool "durable evidence preserves bound args" true
    (Yojson.Safe.equal Yojson.Safe.Util.(evidence |> member "arguments" |> member "value") args)
;;

let test_child_failure_blocks_whole_child_consumers_but_keeps_exports () =
  Eio_main.run @@ fun _ ->
  let surface, reference = fixture () in
  let compiled = compile surface (request ~exports:[ exported "answer" "child" pointer ]
      [ nested "child" reference; consumer "uses-export" "child" pointer
      ; leaf ~after:[ "child" ] "uses-after"; leaf "independent" ]) in
  let plan = Nested.plan compiled in
  let dispatched = ref [] in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    dispatched := node.Plan.id :: !dispatched;
    if node.tool_name = "keeper_memory_search" then
      Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Runtime_failure
           ~start_time:(Tool_timing.start ()) "fixture branch rejected")
    else Executor.dispatch_result (Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
        ~data:(`Assoc [ "profile", `String "docker"; "lane", `Null; "endpoint", `Null; "operator_action", `Null ]) ()) in
  match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
  | Ok _ -> fail "partial child was promoted to success"
  | Error failure ->
    check int "only child leaves and independent leaf dispatched" 3 (List.length !dispatched);
    check int "independent useful result remains settled" 3 (List.length failure.settled);
    let lookup id = failure.settled |> List.find_map (fun (node : Executor.node_result) ->
        if Plan.Node_id.equal id node.node_id && Tool_result.is_success node.result then Some (Tool_result.data node.result) else None) in
    (match Plan.resolve_exports plan ~lookup with
     | [ _, Ok (`String "docker") ] -> () | _ -> fail "successful child export was lost with sibling failure");
    Printf.printf "composition_nested_trial child_failed=true dependent_dispatches=0 independent_result_retained=true selected_export_retained=true model_latency_measured=false\n%!"
;;

let test_fixed_async_child_compiles_exact_result_barrier () =
  let surface,reference = fixture ~source:(document ~execution:"async" ()) () in
  let recipe = request ~exports:[exported "answer" "child" pointer]
      [nested "child" reference;consumer "use-answer" "child" pointer] in
  let compiled = Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async
      ~capability_surface:surface recipe |> require "fixed async child compiler" in
  let plan = Nested.plan compiled in
  let call = List.hd (Nested.calls compiled) in
  let submission,result = match call.scope with Nested.Async {submission;result} -> submission,result
    | Inline _ -> fail "async child was flattened inline" in
  check int "one child has one submission, one canonical result and one consumer" 3 (List.length (Plan.nodes plan));
  let submission_contract = Plan.contract plan submission |> function Some contract -> contract
    | None -> fail "native submission contract missing" in
  let result_contract = Plan.contract plan result |> function Some contract -> contract
    | None -> fail "native result contract missing" in
  (match submission_contract.target,result_contract.target with
   | Plan.Child_submission child,Plan.Child_result result_child ->
     check bool "both operands retain one exact frozen child" true
       (Skill_reference.equal reference (Plan.child_reference child.child)
        && Skill_reference.equal reference (Plan.child_reference result_child.child));
     check bool "canonical fixed args remain bound" true
       (match Plan.child_input child.child with
        | Plan.Json_template.Literal value -> Yojson.Safe.equal value (`Assoc ["query",`String "docker"])
        | Output _ | Param _ | Object _ | Array _ -> false);
     check bool "result observes only after original submission" true
       (List.mem submission (Plan.dependencies result_child.result))
   | _ -> fail "async compiler did not retain native execution targets");
  let export = List.hd (Plan.exports plan) in
  check bool "outer consumers reference the canonical result barrier" true (Plan.Node_id.equal result export.node_id);
  check string "escaped named export stays one exact pointer segment" pointer
    (Plan.Json_pointer.to_string export.pointer);
  check bool "native result never routes through an ordinary descriptor name" true (Plan.descriptor plan result = None)
;;

let test_upstream_child_arguments_bind_exact_declared_plan ~children_first () =
  let surface,reference = fixture ~source:(document ~execution:"async" ()) () in
  let child alias source = `Assoc ["id",`String alias;"skill_reference",Skill_reference.to_yojson reference;
    "input",`Assoc ["kind",`String "object";"fields",`List
      [`Assoc ["name",`String "query";"value",`Assoc
        ["kind",`String "output";"node",`String source;"pointer",`String "/profile"]]]]] in
  let recipe = request (if children_first then
      [child "a" "first";child "b" "second";leaf "second";leaf "first"]
    else [leaf "first";leaf "second";child "a" "first";child "b" "second"]) in
  let compiled = Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async
      ~capability_surface:surface recipe |> require "upstream exact async compiler" in
  let plan = Nested.plan compiled and run_id = Plan.Run_id.fresh () in
  let layers = Plan.dependency_layers plan in
  let layer_of id = List.find_index (fun layer ->
      List.exists (fun (node : Plan.node) -> Plan.Node_id.equal node.id id) layer) layers
    |> function Some index -> index | None -> fail "compiled operand lost its layer" in
  List.iter (List.iter (fun (node : Plan.node) ->
    check bool "dependency layering retains original compiler-owned operands" true
      (List.exists (fun original -> original == node) (Plan.nodes plan));
    List.iter (fun dependency ->
      check bool "compiled data and canonical child barriers remain causal" true
        (layer_of dependency < layer_of node.id)) (Plan.dependencies node))) layers;
  let id name = Plan.Node_id.make (Yojson.Safe.to_string (`List [`String name])) |> require "encoded parent ID" in
  let producer name query =
    Plan.validate_output plan ~run_id ~node_id:(id name)
      (`Assoc ["profile",`String query;"lane",`Null;"endpoint",`Null;"operator_action",`Null])
      |> require "real producer contract" in
  let first = producer "first" "docker" and second = producer "second" "host" in
  List.iter2 (fun (call : Nested.call) expected ->
    let submission = match call.scope with Nested.Async {submission;_} -> submission
      | Inline _ -> fail "dynamic async child became inline" in
    let input = Plan.resolve_input plan ~run_id ~node_id:submission ~lookup:(fun node ->
        if Plan.Node_id.equal node (id "first") then Some first
        else if Plan.Node_id.equal node (id "second") then Some second else None)
      |> require "upstream arguments resolved before dispatch" in
    check bool "two uses of one exact Skill keep distinct argument values" true
      (Yojson.Safe.equal input (`Assoc ["query",`String expected]));
    let child = match Plan.contract plan submission with Some {target=Plan.Child_submission child;_} -> child.child
      | _ -> fail "exact child operand missing" in
    let bound = Plan.bind_child_plan ~input child |> require "frozen child argument binding" in
    let bound_layers = Plan.dependency_layers bound |> List.concat in
    check int "bound child retains every original leaf" (List.length (Plan.nodes bound))
      (List.length bound_layers);
    List.iter (fun node -> check bool "bound child layering retains its own new operands" true
      (List.exists (fun original -> original == node) (Plan.nodes bound))) bound_layers;
    let query = List.find (fun (node : Plan.node) -> node.tool_name = "keeper_memory_search") (Plan.nodes bound) in
    let resolved = Plan.resolve_input bound ~run_id:(Plan.Run_id.fresh ()) ~node_id:query.id
        ~lookup:(fun _ -> None) |> require "bound query through its reconstructed plan contract" in
    check bool "declared parameter reaches the correct leaf" true (Yojson.Safe.equal resolved input);
    List.iter (fun input -> match Plan.bind_child_plan ~input child with
      | Error (Plan.Child_arguments_rejected _) -> ()
      | Error _ | Ok _ -> fail "invalid dynamic arguments bypassed exact Skill schema")
      [`Assoc ["query",`String "invalid"];`Assoc ["query",`Int 1];
       `Assoc ["query",`String "docker";"extra",`Bool true]]) (Nested.calls compiled) ["docker";"host"];
  let module Request = Masc.Keeper_tool_plan_request in
  let encoded = Request.to_yojson plan |> require "owned parameterized child encoding" in
  (match Request.plan_of_json ~descriptors:(Surface.descriptors surface) encoded with
   | Error _ -> () | Ok _ -> fail "private parameterized operand became public authority");
  (match Request.template_of_json (`Assoc ["kind",`String "param";"name",`String "query"]) with
   | Error _ -> () | Ok _ -> fail "public input grammar admitted an unbound parameter");
  let both = match child "bad" "first" with `Assoc fields -> `Assoc (("args",`Assoc [])::fields)
    | _ -> fail "fixture call" in
  (match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async ~capability_surface:surface
      (request [both;leaf "first"]) with
   | Error (Nested.Invalid_call_field _) -> () | Error _ | Ok _ -> fail "ambiguous child input accepted")
;;

let test_upstream_inline_arguments_and_whole_child_failure () =
  Eio_main.run @@ fun _ ->
  let surface,reference = fixture () in
  let child alias source = `Assoc ["id",`String alias;"skill_reference",Skill_reference.to_yojson reference;
    "input",`Assoc ["kind",`String "object";"fields",`List
      [`Assoc ["name",`String "query";"value",`Assoc
        ["kind",`String "output";"node",`String source;"pointer",`String "/profile"]]]]] in
  let alias = "a/quote\"~" in
  let lookalike = Yojson.Safe.to_string (`List [`String alias;`String "arguments";`String "validated"]) in
  let compiled = compile surface (request ~exports:[exported "answer" alias pointer]
      [leaf "first";leaf "second";child alias "first";child "b" "second";
       consumer "downstream" alias pointer;leaf lookalike]) in
  let plan = Nested.plan compiled in
  let ids = List.map (fun (node : Plan.node) -> Plan.Node_id.to_string node.id) (Plan.nodes plan) in
  check int "private argument IDs cannot collide with public lookalikes" (List.length ids)
    (List.length (List.sort_uniq String.compare ids));
  List.iter (fun (call : Nested.call) -> match call.scope with
    | Nested.Inline {argument_node=Some id;_} ->
      (match Plan.contract plan id with Some {target=Plan.Child_arguments _;_} -> ()
       | Some _ | None -> fail "inline input lost its pure private contract");
      check bool "argument validation invents no ordinary descriptor" true (Plan.descriptor plan id = None)
    | Inline {argument_node=None;_} | Async _ -> fail "upstream inline input lost its validation node") (Nested.calls compiled);
  let id source = Plan.Node_id.make (Yojson.Safe.to_string (`List [`String source])) |> require "parent ID" in
  let queries = ref [] and downstream = ref false in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~(node : Plan.node) ~descriptor:_ ~schedule:_ ~input () =
    if Plan.Node_id.equal node.id (id "downstream") then downstream := true;
    if node.tool_name = "keeper_memory_search" then (
      queries := Yojson.Safe.Util.(input |> member "query" |> to_string) :: !queries;
      Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Runtime_failure
          ~effect_disposition:Tool_result.Proven_pre_effect ~start_time:(Tool_timing.start ()) "fixture child sibling failed"))
    else
      let profile = if Plan.Node_id.equal node.id (id "second") then "host" else "docker" in
      Executor.dispatch_result (Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
        ~data:(`Assoc ["profile",`String profile;"lane",`Null;"endpoint",`Null;"operator_action",`Null]) ()) in
  let failure = match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
    | Error failure -> failure | Ok _ -> fail "child sibling failures were promoted to success" in
  check (list string) "one exact inline Skill receives two different upstream arguments" ["docker";"host"]
    (List.sort String.compare !queries);
  check bool "whole-child failure blocks selected-export consumers" false !downstream;
  check bool "independent useful work remains completed" true
    (List.exists (fun (node : Executor.node_result) -> Plan.Node_id.equal node.node_id (id lookalike)
       && Tool_result.is_success node.result) failure.settled);
  let lookup id = List.find_map (fun (node : Executor.node_result) ->
    if Plan.Node_id.equal id node.node_id && Tool_result.is_success node.result
    then Some (Tool_result.data node.result) else None) failure.settled in
  (match Plan.resolve_exports plan ~lookup with
   | [_,Ok (`String "docker")] -> ()
   | _ -> fail "upstream inline sibling failure lost the successful selected export");
  let encoded = Masc.Keeper_tool_plan_request.to_yojson plan |> require "private inline evidence encoding" in
  (match Masc.Keeper_tool_plan_request.plan_of_json ~descriptors:(Surface.descriptors surface) encoded with
   | Error _ -> () | Ok _ -> fail "private inline validation became public route authority")
;;

let test_refusals_preserve_frozen_authority_and_contracts () =
  let surface, reference = fixture () in
  let check_error label surface json accepts = match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Inline ~capability_surface:surface json with
    | Error error when accepts error -> ()
    | Error error -> failf "%s: %s" label (Yojson.Safe.to_string (Nested.error_to_json error))
    | Ok _ -> fail (label ^ " accepted") in
  let input ref = request [ nested "child" ref ] in
  let revised = Skill_reference.make ~identity:reference.identity
      ~content_revision:(Skill_reference.content_revision_of_source_text "other revision") in
  check_error "changed revision" surface (input revised) (function Nested.Reference_unavailable _ -> true | _ -> false);
  let hidden, _ = fixture ~skill_names:(Some []) () in
  check_error "configured outside surface" hidden (input reference) (function Nested.Reference_unavailable _ -> true | _ -> false);
  let denied, _ = fixture ~tool_deny:[ "keeper_memory_search" ] () in
  check_error "denied child leaf" denied (input reference) (function Nested.Reference_unavailable _ -> true | _ -> false);
  List.iter (fun args -> check_error "child argument contract" surface (request [ nested ~args "child" reference ])
      (function Nested.Arguments_rejected _ -> true | _ -> false))
    [ `Assoc []; `Assoc [ "query", `String "invalid" ]; `Assoc [ "query", `Int 1 ]
    ; `Assoc [ "query", `String "docker"; "extra", `Bool true ] ];
  check_error "policy mismatch" surface (request ~policy:"fail_fast" [ nested "child" reference ])
    (function Nested.Child_policy_mismatch _ -> true | _ -> false);
  let async_surface, async_reference = fixture ~source:(document ~execution:"async" ()) () in
  check_error "async child" async_surface (input async_reference)
    (function Nested.Async_child_requires_suspension _ -> true | _ -> false);
  check_error "duplicate alias" surface (request [ nested "child" reference; leaf "child" ])
    (function Nested.Duplicate_alias _ -> true | _ -> false);
  check_error "missing alias" surface (request [ nested ~after:[ "missing" ] "child" reference ])
    (function Nested.Unknown_alias _ -> true | _ -> false);
  check_error "cycle after expansion" surface (request [ nested ~after:[ "later" ] "child" reference; leaf ~after:[ "child" ] "later" ])
    (function Nested.Expanded_plan_rejected (Plan.Dependency_cycle _) -> true | _ -> false);
  check_error "unexported child output" surface (request [ nested "child" reference; consumer "consumer" "child" "/not-exported" ])
    (function Nested.Unknown_child_export _ -> true | _ -> false);
  check_error "root child output" surface (request [ nested "child" reference; consumer "consumer" "child" "" ])
    (function Nested.Child_output_requires_export _ -> true | _ -> false);
  check_error "invalid subpath" surface (request [ nested "child" reference; consumer "consumer" "child" (pointer ^ "/absent") ])
    (function Nested.Expanded_plan_rejected (Plan.Invalid_output_pointer _) -> true | _ -> false)
;;

module Draft = Masc.Keeper_composition_draft
module Tools = Masc.Keeper_tool_composition_surface
module Ledger = Masc.Keeper_skill_activation_ledger
module Recorder = Masc.Keeper_skill_activation_recorder

let with_base operation =
  let root = Filename.temp_dir "masc-nested-public-" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> operation root)
;;

let decode_reference json = match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref value -> value
  | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ -> fail "missing normalized reference"
;;

let read_document ~base_path reference =
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.Tool_output.sha256 with
  | Ok (Some bytes) ->
    (match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string bytes) with
     | Tool_output.Decoded_artifact_manifest { structured_content; _ } -> structured_content
     | Tool_output.Not_artifact_manifest -> fail "expected durable manifest"
     | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
  | Ok None -> fail "missing durable document"
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)
;;

let prepare ~base_path surface json = match Draft.prepare ~base_path ~capability_surface:surface
    ~keeper_name:"fixture" ~execution:Masc.Keeper_tool_composition_catalog.Inline json with
  | Ok value -> value | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error))
;;

let test_inline_edit_recipe_preserves_effect_and_durable_admission () =
  let surface, _ = fixture () in
  let patch = `Assoc [ "id", `String "patch"; "tool", `String "Edit"
      ; "args", `Assoc [ "file_path", `String "document.txt"
          ; "old_string", `String "before"; "new_string", `String "after" ] ] in
  let recipe = request [ patch ] in
  let compiled = Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Inline
      ~capability_surface:surface recipe |> require "inline Edit recipe rejected" in
  let node = match Plan.nodes (Nested.plan compiled) with
    | [node] -> node | _ -> fail "one original Edit leaf" in
  let descriptor = Plan.descriptor (Nested.plan compiled) node.id
      |> function Some descriptor -> descriptor | None -> fail "Edit descriptor absent" in
  check bool "Edit retains its effectful serial producer" true
    (descriptor.execution = Masc.Keeper_tool_descriptor.Ordinary Serial
     && Masc.Keeper_tool_descriptor.prepared_leaf_admission descriptor = Owned_file_mutation_leaf
     && Masc.Keeper_tool_descriptor.readonly_static_hint descriptor = Some false);
  (match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async
      ~capability_surface:surface recipe with
   | Error (Nested.Unsupported_leaf {node_id;tool_name}) ->
       check string "durable refusal retains original node" "patch" (Plan.Node_id.to_string node_id);
       check string "durable refusal retains original Tool" "Edit" tool_name
   | Error _ -> fail "async Edit refused for an unrelated reason"
   | Ok _ -> fail "ordinary Edit acquired a replayable async launch contract");
  let source = {|---
name: nested-read
description: Apply one exact owned-file patch.
---
```toml composition
[[compositions]]
name = "nested-read"
execution = "inline"
branch_failure_policy = "continue_independent"
[[compositions.nodes]]
id = "patch"
tool = "Edit"
[compositions.nodes.input]
kind = "literal"
value = { file_path = "document.txt", old_string = "before", new_string = "after" }
```
|} in
  let surface, reference = fixture ~source () in
  let parent = request [ nested ~args:(`Assoc []) "child" reference ] in
  let compiled = Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Inline
      ~capability_surface:surface parent |> require "exact inline Edit child rejected" in
  check int "exact Edit child keeps one activation scope" 1 (List.length (Nested.calls compiled));
  check int "fixed child retains one original file leaf" 1 (List.length (Plan.nodes (Nested.plan compiled)));
  match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async
      ~capability_surface:surface parent with
  | Error (Nested.Unsupported_leaf _) -> ()
  | Error _ -> fail "durable parent refused for an unrelated reason"
  | Ok _ -> fail "inline child smuggled file effects into durable async admission"
;;

let test_inline_write_keeps_original_effect_and_durable_refusal () =
  let surface, _ = fixture () in
  let recipe = request [`Assoc ["id", `String "save"; "tool", `String "Write";
    "args", `Assoc ["file_path", `String "report.txt"; "content", `String "original bytes\n"]]] in
  let compiled = compile surface recipe in
  let node = match Plan.nodes (Nested.plan compiled) with
    | [node] -> node | _ -> fail "one original Write leaf" in
  let descriptor = Plan.descriptor (Nested.plan compiled) node.id
    |> function Some descriptor -> descriptor | None -> fail "original Write descriptor absent" in
  check bool "Write stays effectful and Serial" true
    (descriptor.execution = Masc.Keeper_tool_descriptor.Ordinary Serial
     && Masc.Keeper_tool_descriptor.readonly_static_hint descriptor = Some false);
  (match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async
      ~capability_surface:surface recipe with
   | Error (Nested.Unsupported_leaf {node_id;tool_name}) ->
       check string "async refusal names the original Write node" "save" (Plan.Node_id.to_string node_id);
       check string "async refusal names the original Write capability" "Write" tool_name
   | Error _ -> fail "async Write refused for an unrelated reason"
   | Ok _ -> fail "ordinary Write acquired durable replay authority");
  let declaration execution = Printf.sprintf {|[[compositions]]
name = "nested-read"
execution = %S
branch_failure_policy = "continue_independent"
[[compositions.nodes]]
id = "save"
tool = "Write"
[compositions.nodes.input]
kind = "literal"
value = { file_path = "report.txt", content = "original bytes\n" }
|} execution in
  (match Masc.Keeper_tool_composition_catalog.parse (declaration "async") with
   | Error (Async_leaf_not_admitted {tool_name;_}) ->
       check string "durable catalog keeps the same original refusal" "Write" tool_name
   | Error _ -> fail "async Write catalog refused for an unrelated reason"
   | Ok _ -> fail "async catalog admitted an ordinary file write");
  let source = "---\nname: nested-read\ndescription: Save the original file bytes.\n---\n```toml composition\n"
      ^ declaration "inline" ^ "```\n" in
  let surface, reference = fixture ~source () in
  let parent = request [nested ~args:(`Assoc []) "child" reference] in
  let compiled = compile surface parent in
  check int "exact inline Write child retains one activation scope" 1 (List.length (Nested.calls compiled));
  match Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Async
      ~capability_surface:surface parent with
  | Error (Nested.Unsupported_leaf _) -> ()
  | Error _ -> fail "async Write child refused for an unrelated reason"
  | Ok _ -> fail "inline Write child acquired durable async replay authority"
;;

let test_nested_draft_freezes_and_revalidates_recipe () =
  Eio_main.run @@ fun _ ->
  with_base @@ fun base_path ->
  let surface, reference = fixture () in
  List.iter (fun invalid_pointer ->
    let recipe pointer = request ~exports:[ exported "answer" "child" pointer ]
        [ nested "child" reference ] in
    let error = match Draft.prepare ~base_path ~capability_surface:surface ~keeper_name:"fixture"
        ~execution:Masc.Keeper_tool_composition_catalog.Inline (recipe invalid_pointer) with
      | Error (Draft.Nested_rejected ((Nested.Child_output_requires_export _ | Nested.Unknown_child_export _) as error)) -> error
      | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error))
      | Ok _ -> fail "undeclared child output accepted" in
    let open Yojson.Safe.Util in
    let rejection = Draft.error_to_json (Draft.Nested_rejected error) in
    check string "repair keeps the public child alias" "child" (rejection |> member "node_id" |> to_string);
    let available = rejection |> member "available_exports" |> to_list in
    let selected = match available with
      | [export] -> export
      | [] | _ :: _ -> fail "repair did not expose the exact admitted export set" in
    check string "public export name is retained" "profile/~name" (selected |> member "name" |> to_string);
    let advertised_pointer = selected |> member "pointer" |> to_string in
    let repaired = prepare ~base_path surface (recipe advertised_pointer) in
    check int "copying the advertised pointer repairs preparation" 1
      (List.length (Plan.exports (Draft.plan repaired)))) ["";"/not-exported"];
  let recipe = request ~exports:[ exported "answer" "child" pointer ] [ nested "child" reference ] in
  let dynamic_inline = request [`Assoc ["id",`String "child";"skill_reference",Skill_reference.to_yojson reference;
    "input",`Assoc ["kind",`String "literal";"value",`Assoc ["query",`String "docker"]]]] in
  (match Draft.prepare ~base_path ~capability_surface:surface ~keeper_name:"fixture"
      ~execution:Masc.Keeper_tool_composition_catalog.Inline dynamic_inline with
   | Ok draft ->
     check int "inline input retains one exact child" 1 (List.length (Draft.nested_calls draft));
     (match (List.hd (Draft.nested_calls draft)).scope with
      | Nested.Inline {argument_node=Some _;_} -> ()
      | Inline {argument_node=None;_} | Async _ -> fail "draft omitted inline argument authority")
   | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error)));
  let draft = prepare ~base_path surface recipe in
  let stored = read_document ~base_path (Draft.reference draft) in
  let open Yojson.Safe.Util in
  check bool "original exact recipe retained" true (Yojson.Safe.equal recipe (stored |> member "recipe"));
  check bool "prepared child mappings retained" true
    (Yojson.Safe.equal (stored |> member "nested_calls") (Draft.preview draft |> member "nested_calls"));
  let loaded = Draft.load ~base_path ~capability_surface:surface ~keeper_name:"fixture"
      ~sha256:(Draft.reference draft).sha256 |> require "load frozen nested recipe" in
  check int "load restores exact child provenance" 1 (List.length (Draft.nested_calls loaded));
  let changed, _ = fixture ~source:(document ~suffix:"Changed exact source revision." ()) () in
  (match Draft.load ~base_path ~capability_surface:changed ~keeper_name:"fixture" ~sha256:(Draft.reference draft).sha256 with
   | Error Draft.Capability_changed -> () | _ -> fail "changed Skill surface rebound the old draft");
  let corrupt = match stored with `Assoc fields -> `Assoc (("nested_calls", `List []) :: List.remove_assoc "nested_calls" fields)
    | _ -> fail "expected object manifest" in
  let raw = Tool_output.artifact_manifest_to_json ~content:"" ~structured_content:corrupt |> Yojson.Safe.to_string in
  let corrupt_reference = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
      ~bytes:raw ~mime:Tool_output.artifact_manifest_mime in
  (match Draft.load ~base_path ~capability_surface:surface ~keeper_name:"fixture" ~sha256:corrupt_reference.sha256 with
   | Error (Draft.Malformed_draft _) -> () | _ -> fail "different child mapping admitted");
  (match Draft.prepare ~base_path ~capability_surface:surface ~keeper_name:"fixture"
      ~execution:Masc.Keeper_tool_composition_catalog.Async recipe with
   | Ok async_draft -> check int "async parent preserves exact child mappings" 1 (List.length (Draft.nested_calls async_draft))
   | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error)));
  let publishable = match recipe with `Assoc fields -> `Assoc (("skill", `Assoc
      [ "package_id", `String "nested-published"; "description", `String "Exact child recipe" ]) :: fields)
    | _ -> fail "expected recipe object" in
  (match Draft.prepare ~base_path ~capability_surface:surface ~keeper_name:"fixture"
      ~execution:Masc.Keeper_tool_composition_catalog.Inline publishable with
   | Error Draft.Nested_publication_requires_catalog -> () | _ -> fail "published flattened plan lost child identities")
;;

let public_document = {|---
name: nested-read
description: Inspect independent lane profiles with exact fixed bindings.
---

```toml composition
[[compositions]]
name = "nested-read"
execution = "inline"
branch_failure_policy = "continue_independent"
[[compositions.nodes]]
id = "lane-a"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "lane-b"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.exports]]
name = "profile"
node = "lane-a"
pointer = "/profile"
```
|}
;;

let test_public_nested_prepare_run_records_only_admitted_children ?(execution=Masc.Keeper_tool_composition_catalog.Inline)
    ?(single_call=false) ~reject_child () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let eio_snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state eio_snapshot) @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base @@ fun base_path ->
  let surface, reference, snapshot = fixture_snapshot ~source:public_document () in
  let config = Masc.Workspace.default_config base_path in
  let module Call_log = Masc.Keeper_tool_call_log in
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  Call_log.init ~base_path ();
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "fixture"; "activation_mode", `String "manual" ]) |> require "meta fixture" in
  let trace_id = Keeper_id.Trace_id.of_string "trace-nested-public" |> require "trace identity" in
  let session_dir = Masc.Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id) in
  Unix.mkdir session_dir 0o700;
  let turn_ref = Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string trace_id) ~absolute_turn:1 in
  let task_selection = Masc.Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:"task-nested" [ reference ]
      |> require "task-bound exact child" in
  let runtime = ref "fixture.runtime" and runtime_reads = ref 0 in
  let recorder = Recorder.make ~trace_id ~turn_ref ~runtime_id:(fun () -> incr runtime_reads; Some !runtime)
      ~snapshot_revision:(Surface.skill_snapshot_revision surface) ~task_selection |> require "turn recorder" in
  let calls = ref 0 in
  let barrier, release = Eio.Promise.create () in
  let record ~invocation ~tool_name ~scope ~reference =
    incr calls;
    if !calls = 2 then Eio.Promise.resolve release ();
    Eio.Promise.await barrier;
    if reject_child && scope.Ledger.alias = "reject" then Error Recorder.Runtime_attempt_missing
    else Recorder.record_nested_composition ~config recorder ~invocation ~tool_name ~scope reference in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    { provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider; keeper_name = meta.name } in
  let ctx_snapshot = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"public nested fixture" in
  let cell = Call_log.create_turn_ctx_cell () in
  Call_log.set_turn_context ~cell ~agent_name:"fixture" ~task_id:"task-nested" ~turn:1 ~trace_id:"trace-nested-public" ();
  let tools = Tools.make_tools ~capability_surface:surface ~config ~meta ~publication_recovery ~ctx_snapshot
      ~record_nested_composition_activation:record ~nested_activation_context:recorder ~turn_ctx_cell:cell () in
  let execute id name input =
    let tool = List.find_map (fun (tool, _, _) -> if tool.Agent_core.Tool.schema.name = name then Some tool else None) tools
      |> function Some value -> value | None -> fail ("public control absent: " ^ name) in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:id ~turn:1
        ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Agent_core.Tool_contract.Serial }
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    match Agent_core.Tool.execute ~invocation tool input with
    | Ok output -> true, output.content | Error error -> false, error.Agent_core.Types.message in
  let invoke id name input =
    let success,content = execute id name input in
    let structured =
      match Tool_output.decode_from_agent_core content with
      | Tool_output.Decoded reference -> read_document ~base_path reference
      | Tool_output.Not_marker ->
        let json = Yojson.Safe.from_string content in
        (match Tool_output.normalized_artifact_ref_of_json (Yojson.Safe.Util.member "artifact_manifest" json) with
         | Tool_output.Decoded_normalized_artifact_ref reference ->
           ignore (Agent_core.Execution_json.object_fields ~context:"public typed artifact envelope"
             ~required:["structured_content";"artifact_manifest"] ~optional:["content"] json
             |> require "canonical public artifact envelope");
           let projected = Yojson.Safe.Util.member "structured_content" json in
           check bool "public inline projection matches its canonical manifest" true
             (Yojson.Safe.equal projected (read_document ~base_path reference));
           projected
         | Tool_output.Invalid_normalized_artifact_ref {detail} -> fail detail
         | Tool_output.Not_normalized_artifact_ref ->
           if success then fail "public success has no canonical artifact envelope"
           else Yojson.Safe.Util.member "data" json)
      | Tool_output.Invalid_marker { detail } -> fail detail
    in
    if structured = `Null then fail ("public result lacks structured content: " ^ content);
    success, content, structured in
  let scopes = [ nested ~args:(`Assoc []) "left" reference; nested ~args:(`Assoc []) "right" reference ]
      @ if reject_child then
          [ nested ~args:(`Assoc []) "reject" reference
          ; nested ~args:(`Assoc []) ~after:[ "reject" ] "blocked" reference ]
        else [] in
  let recipe = request ~exports:[ exported "answer" "left" "/profile" ] scopes in
  let input = match recipe with `Assoc fields -> `Assoc (("execution", `String (Masc.Keeper_tool_composition_catalog.execution_mode_to_string execution)) :: fields)
    | _ -> fail "recipe object" in
  let open Yojson.Safe.Util in
  let prepared = if single_call then (
    List.iteri (fun index rejected_input ->
      let accepted,_ = execute ("invalid-recipe-" ^ string_of_int index) Draft.run_tool_name rejected_input in
      check bool "ambiguous or continuing recipe is refused" false accepted;
      check int "refused recipe admits no child" 0 !calls)
      [ `Assoc ["recipe",input;"sha256",`String (String.make 64 '0')]
      ; `Assoc ["recipe",input;"resume_run_id",`String "019c0000-0000-7000-8000-000000000000"]
      ; `Assoc ["recipe",input;"recipe",input]
      ; `Assoc ["recipe",(match input with `Assoc fields ->
          `Assoc (("execution",`String "unknown") :: List.remove_assoc "execution" fields)
          | _ -> fail "fixture input object")]
      ; `Assoc ["recipe",`Assoc ["execution",`String (Masc.Keeper_tool_composition_catalog.execution_mode_to_string execution);
          "nodes",`List [nested ~args:(`Assoc ["unexpected",`Bool true]) "bad" reference]]]
      ; `Assoc ["recipe",`Assoc ["execution",`String "inline";"nodes",`List
          [`Assoc ["id",`String "bad";"tool",`String "keeper_lane_status";
            "args",`Assoc [];"input",`Assoc ["kind",`String "literal";"value",`Assoc []]]]]]
      ; `Assoc ["recipe",`Assoc ["execution",`String "inline";"nodes",`List
          [`Assoc ["id",`String "bad";"tool",`String "keeper_lane_status";"args",`String "not an object"]]]] ];
    None)
    else (
      let prepare_success,_,prepared = invoke "prepare-nested" Draft.prepare_tool_name input in
      check bool "public prepare accepts nested grammar" true prepare_success;
      check int "preparation is not activation" 0 !calls;
      Some prepared) in
  let run_input = match prepared with
    | Some prepared -> `Assoc ["sha256",`String (prepared |> member "draft" |> decode_reference).sha256]
    | None -> `Assoc ["recipe",input] in
  let success, accepted_content, accepted = invoke "run-nested" Draft.run_tool_name
      run_input in
  let draft_reference = accepted |> member "draft" |> decode_reference in
  let frozen_draft = read_document ~base_path draft_reference in
  check bool "frozen draft retains the original recipe" true
    (Yojson.Safe.equal (frozen_draft |> member "recipe") recipe);
  check string "frozen draft retains its preparing Keeper" "fixture"
    (frozen_draft |> member "keeper" |> to_string);
  let success,result_content,result = match execution with
    | Masc.Keeper_tool_composition_catalog.Inline -> success,accepted_content,accepted
    | Masc.Keeper_tool_composition_catalog.Async ->
      check bool "nested parent is durably accepted asynchronously" true success;
      check int "original runtime is bound exactly once before acceptance" 1 !runtime_reads;
      runtime := "later.runtime";
      Call_log.set_turn_context ~cell ~agent_name:"fixture" ~task_id:"later-task" ~turn:7 ~trace_id:"trace-later" ();
      let request_id = accepted |> member "request_id" |> to_string in
      let module Async = Masc.Keeper_msg_async in
      let rec await () = match Async.load_canonical_durable_terminal ~base_path ~caller:"fixture" request_id with
        | Ok proof -> (match (Async.durable_terminal_entry proof).status with
          | Done {ok;body;data=Some data} ->
            let entry = Async.durable_terminal_entry proof in
            let context = match entry.request_context with Some fields -> `Assoc fields | None -> fail "original async context absent" in
            check string "completed async request belongs to original Task" "task-nested"
              (context |> member "source_task_id" |> to_string);
            ok,body,data
          | _ -> fail "nested async parent did not retain a canonical completed result")
        | Error (Canonical_terminal_absent | Canonical_terminal_runtime_active _) -> Eio.Fiber.yield (); await ()
        | Error error -> fail (Async.canonical_terminal_error_to_string error) in
      await () in
  check bool "actual aggregate failure stays failure" (not reject_child) success;
  (match execution with
   | Inline -> check int "one admission per attempted child, independent of leaf count" (if reject_child then 3 else 2) !calls
   | Async -> check int "async worker never reads the later runtime callback" 1 !runtime_reads);
  let run_reference = accepted |> member "run_artifact" |> decode_reference in
  let run_binding = read_document ~base_path run_reference in
  let run_id = run_binding |> member "composition_run_id" |> to_string in
  check string "public acceptance retains pre-dispatch run" run_id (accepted |> member "composition_run_id" |> to_string);
  check bool "run binding retains all exact child mappings" true
    (Yojson.Safe.equal (run_binding |> member "nested_calls") (frozen_draft |> member "nested_calls"));
  check bool "usable selected answer survives independent admission failure" true
    (result |> member "exports" |> member "answer" |> member "available" |> to_bool);
  let child_scopes = result |> member "nested_scopes" |> to_list in
  List.iter (fun child ->
    let alias = child |> member "scope" |> member "alias" |> to_string in
    let expected = match alias with "reject" -> "admission_rejected" | "blocked" -> "not_started" | _ -> "completed" in
    check string ("child disposition " ^ alias) expected (child |> member "disposition" |> to_string);
    check bool ("child's export availability " ^ alias) (expected = "completed")
      (child |> member "exports" |> member "profile" |> member "available" |> to_bool)) child_scopes;
  let full_execution = result |> member "execution_artifact" |> decode_reference |> read_document ~base_path in
  check bool "full durable execution retains child provenance" true
    (Yojson.Safe.equal (result |> member "nested_scopes") (full_execution |> member "nested_scopes"));
  let successful_leaves = child_scopes |> List.concat_map (fun child -> child |> member "nodes" |> to_list)
      |> List.filter (fun node -> member "disposition" node = `String "completed") |> List.length in
  check int "four ordinary leaf handlers actually completed" 4 successful_leaves;
  let blocked_children = List.filter (fun child -> member "disposition" child = `String "not_started") child_scopes |> List.length in
  let ledger = Ledger.load ~config ~trace_id |> require "reload actual activation ledger" in
  check int "only successfully admitted scopes activated" 2 (List.length (Ledger.activations ledger));
  List.iter (fun (activation : Ledger.activation) ->
    let child = List.find (fun child ->
      child |> member "admission" |> member "skill_tool_use_id" = `String activation.skill_tool_use_id) child_scopes in
    let admission = child |> member "admission" in
    check bool "public result retains the exact actual activation receipt" true
      (Yojson.Safe.equal (Ledger.activation_to_yojson activation) (admission |> member "activation"));
    check string "public result retains the original immutable admission frame"
      (Ledger.activation_frame_sha256 activation) (admission |> member "activation_frame_sha256" |> to_string))
    (Ledger.activations ledger);
  List.iter (fun (activation : Ledger.activation) ->
    match activation.invocation with
    | Ledger.Nested_composition_invocation { scope; origin = Ledger.Task_composition { task_ids }; tool_name } ->
      let expected_parent = match execution with Inline -> "run-nested" | Async ->
        Masc.Keeper_tool_plan.Composition_run_id.of_string run_id |> require "original run identity"
          |> Masc.Keeper_composition_nested_run.async_result_parent in
      check string "actual child binds the correct parent result receipt" expected_parent scope.parent_tool_use_id;
      check string "actual child binds same composition run" run_id scope.composition_run_id;
      check string "actual child records public Tool" Draft.run_tool_name tool_name;
      check (list string) "original task attribution retained" [ "task-nested" ]
        (Ledger.task_id_set_to_list task_ids |> List.map Keeper_id.Task_id.to_string);
      check bool "exact source identity retained" true (Skill_reference.equal_identity reference.identity activation.identity);
      check string "child keeps the original selected runtime" "fixture.runtime" activation.runtime_id
    | _ -> fail "canonical nested task origin missing") (Ledger.activations ledger);
  (match execution with
   | Inline -> ()
   | Async ->
     let identity = Masc.Keeper_tool_plan.Composition_run_id.of_string run_id |> require "reload original journal identity" in
     let journal = Masc.Keeper_tool_execution_journal.load ~base_path ~keeper_name:"fixture" ~composition_run_id:identity
       |> require "reload original owned source" in
     let bound = Draft.load_nested_activation ~base_path (Masc.Keeper_tool_execution_journal.source journal)
       |> require "restore original bound context from immutable run" |> function
       | Some bound -> bound | None -> fail "nested async run lost its original binding" in
     let module Nested_run = Masc.Keeper_composition_nested_run in
     let parent_invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"run-nested" ~turn:1
         ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
         ~completion:Continue_after_success in
     let compiled = Nested.compile ~execution ~capability_surface:surface recipe |> require "original frozen child calls" in
     let retained = Nested_run.create ~calls:(Nested.calls compiled) ~composition_run_id:identity
         ~delivery_parent_tool_use_id:(Nested_run.async_result_parent identity)
         ~parent_invocation ~tool_name:Draft.run_tool_name ~record_activation:None () in
     List.iter (fun (call : Nested.call) ->
       match Nested_run.admitted_activation retained ~alias:call.alias with
       | Error _ -> () | Ok _ -> fail "unrestored child manufactured an activation") (Nested.calls compiled);
     Nested_run.restore_admissions retained ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
       Recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference);
     List.iter (fun (call : Nested.call) ->
       let receipt = Nested_run.admitted_activation retained ~alias:call.alias |> require "typed original child receipt" in
       let original = List.find (fun (activation : Ledger.activation) ->
         String.equal activation.skill_tool_use_id receipt.skill_tool_use_id) (Ledger.activations ledger) in
       check bool "restoration preserves the complete original activation" true (receipt = original)) (Nested.calls compiled);
     let source = Masc.Keeper_tool_execution_journal.source journal in
     let find_result_children result =
       match Draft.load_nested_result_children ~base_path source ~result |> require "decode exact retained result children" with
       | None -> fail "original result lost child receipts"
       | Some (original,children) -> Recorder.find_bound_result_children ~config original
           ~composition_run_id:identity ~logical_parent_tool_use_id:(Nested_run.async_result_parent identity)
           ~source_turn:1 ~tool_name:Draft.run_tool_name children in
     let receipts = find_result_children result |> require "original result receipts join original ledger" in
     check int "both actual admitted receipts survive public result parsing" 2 (List.length receipts);
     let rewrite_admissions transform = match result with
       | `Assoc fields -> `Assoc (("nested_scopes",`List (List.map (function
           | `Assoc fields -> `Assoc (List.map (fun (name,value) ->
               if String.equal name "admission" then name,transform value else name,value) fields)
           | _ -> fail "typed child scope missing") child_scopes)) :: List.remove_assoc "nested_scopes" fields)
       | _ -> fail "typed parent result missing" in
     let missing = rewrite_admissions (function
       | `Assoc fields -> `Assoc (List.remove_assoc "activation" fields)
       | _ -> fail "admitted child expected") in
     (match Draft.load_nested_result_children ~base_path source ~result:missing with
      | Error (Draft.Malformed_draft _) -> () | _ -> fail "ID-only result laundered missing original receipt");
     let changed_clock = rewrite_admissions (function
       | `Assoc fields ->
         let receipt = match List.assoc "activation" fields with
           | `Assoc fields -> `Assoc (("activated_at",`String "2000-01-01T00:00:00Z") :: List.remove_assoc "activated_at" fields)
           | _ -> fail "original receipt missing" in
         let receipt = Ledger.activation_of_yojson ~expected_trace_id:trace_id receipt |> require "well-formed changed receipt" in
         `Assoc (("activation",Ledger.activation_to_yojson receipt)
           :: ("activation_frame_sha256",`String (Ledger.activation_frame_sha256 receipt))
           :: List.remove_assoc "activation_frame_sha256" (List.remove_assoc "activation" fields))
       | _ -> fail "admitted child expected") in
     (match find_result_children changed_clock with
      | Error (Recorder.Invalid_bound_context _) -> () | _ -> fail "self-consistent changed clock replaced original ledger proof");
     let mismatched = Nested_run.create ~calls:(Nested.calls compiled) ~composition_run_id:identity
         ~delivery_parent_tool_use_id:(Nested_run.async_result_parent identity)
         ~parent_invocation ~tool_name:Draft.run_tool_name ~record_activation:None () in
     let wrong_receipt = List.hd (Ledger.activations ledger) in
     Nested_run.restore_admissions mismatched ~find_activation:(fun ~invocation:_ ~tool_name:_ ~scope:_ ~reference:_ ->
       Ok (Some wrong_receipt));
     let refused = List.filter (fun (call : Nested.call) ->
       match Nested_run.admitted_activation mismatched ~alias:call.alias with Error _ -> true | Ok _ -> false)
         (Nested.calls compiled) in
     check int "a sibling receipt cannot admit another original child" 1 (List.length refused);
     let unchanged = Ledger.load_existing ~config ~trace_id |> require "ledger after proof-only restoration checks"
       |> function Some ledger -> ledger | None -> fail "original ledger disappeared" in
     check bool "reading and refusing receipts creates no activation or clock" true
       (Ledger.activations unchanged = Ledger.activations ledger);
     List.iter (fun (activation : Ledger.activation) ->
       match activation.invocation with
       | Ledger.Nested_composition_invocation {scope;tool_name;_} ->
         let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:activation.skill_tool_use_id
           ~turn:activation.agent_core_turn ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
           ~completion:Continue_after_success in
         (match Recorder.record_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference
                |> require "re-admit exact original child with restored authority" with
          | Ledger.Already_recorded existing ->
            check string "re-admission preserves the first actual activation time" activation.activated_at existing.activated_at
          | Ledger.Recorded _ -> fail "restored child created a second activation")
       | _ -> fail "nested child provenance absent") (Ledger.activations ledger));
  let receipt : Ledger.tool_result_receipt =
    { tool_use_id = (match execution with Inline -> "run-nested" | Async ->
        Masc.Keeper_tool_plan.Composition_run_id.of_string run_id |> require "original result receipt run"
          |> Masc.Keeper_composition_nested_run.async_result_parent); content_bytes = String.length result_content
    ; content_sha256 = Digestif.SHA256.(digest_string result_content |> to_hex) } in
  (match execution with
   | Inline -> ()
   | Async ->
     let accepted_receipt : Ledger.tool_result_receipt =
       {tool_use_id="run-nested";content_bytes=String.length accepted_content;
        content_sha256=Digestif.SHA256.(digest_string accepted_content |> to_hex)} in
     let delivered = Recorder.observe_delivery ~config recorder ~tool_results:[accepted_receipt]
       ~boundary:(Ledger.Model_response {agent_core_turn=2}) ~runtime_id:"later.runtime"
       |> require "observe only actual original acceptance receipt" in
     check int "async acceptance never claims child result delivery" 0 (List.length delivered));
  let delivered = Recorder.observe_delivery ~config recorder ~tool_results:[ receipt ]
      ~boundary:(Ledger.Model_response { agent_core_turn = 2 }) ~runtime_id:"fixture.runtime"
      |> require "deliver actual public result to its children" in
  check int "actual parent result delivers both activated children" 2 (List.length delivered);
  (match execution with
   | Inline -> ()
   | Async ->
     let module Async = Masc.Keeper_msg_async in
     let events = Filename.concat session_dir "skill-activation-events.jsonl" in
     let saved = Filename.concat base_path "retained-original-activations.jsonl" in
     let original_ledger = Ledger.load_existing ~config ~trace_id |> require "exact ledger after child delivery"
       |> function Some ledger -> ledger | None -> fail "delivered original ledger missing" in
     let original_request = accepted |> member "request_id" |> to_string in
     let original_terminal = Async.load_canonical_durable_terminal ~base_path ~caller:"fixture" original_request
       |> require "original completed request before authority fault" |> Async.durable_terminal_entry in
     (* Canonical publication precedes the worker wrapper's switch cleanup.
        Let the original worker finish before faulting its ledger and comparing
        worker counts; its normal departure must not masquerade as a resume
        admission change. This isolated scenario owns the async workers. *)
     let rec await_worker_cleanup () =
       if Async.For_testing.active_switch_count () = 0 then ()
       else (Eio.Fiber.yield (); await_worker_cleanup ()) in
     await_worker_cleanup ();
     let resume_input = `Assoc ["sha256",`String draft_reference.sha256;"resume_run_id",`String run_id] in
     List.iter (fun corrupt ->
       Unix.rename events saved;
       Fun.protect ~finally:(fun () ->
         if Sys.file_exists events then Unix.unlink events;
         Unix.rename saved events) (fun () ->
         if corrupt then Eio.Path.save ~create:(`Exclusive 0o600)
             Eio.Path.(Eio.Stdenv.fs env / events) "invalid-original-activation\n";
         let reservations = Async.For_testing.reserved_request_id_count () in
         let workers = Async.For_testing.active_switch_count () in
         let resumed,_,data = invoke "resume-original-without-authority" Draft.run_tool_name resume_input in
         check bool "completed public resume refuses missing/corrupt original activation" false resumed;
         check bool "refusal returns no child exports" true (member "exports" data = `Null);
         check bool "refusal accepts no successor request" true (member "request_id" data = `Null);
         check int "refusal reserves no new async identity" reservations (Async.For_testing.reserved_request_id_count ());
         check int "refusal starts no worker" workers (Async.For_testing.active_switch_count ());
         let terminal = Async.load_canonical_durable_terminal ~base_path ~caller:"fixture" original_request
           |> require "original completed request survives refused resume" |> Async.durable_terminal_entry in
         check bool "original completed evidence stays exact" true (Async.same_entry_record original_terminal terminal);
         check int "refused resume cannot consult the later runtime" 1 !runtime_reads)) [false;true];
     let restored = Ledger.load_existing ~config ~trace_id |> require "restored original activation authority"
       |> function Some ledger -> ledger | None -> fail "original ledger not restored" in
     check bool "authority fault preserves exact child activations" true
       (Ledger.activations restored = Ledger.activations original_ledger);
     let resumed,_,data = invoke "resume-original-after-authority-repair" Draft.run_tool_name resume_input in
     check bool "restored exact authority permits completed public resume" true resumed;
     let request_id = data |> member "request_id" |> to_string in
     let rec await_reuse () = match Async.load_canonical_durable_terminal ~base_path ~caller:"fixture" request_id with
       | Ok proof -> (match (Async.durable_terminal_entry proof).status with
         | Done {ok=true;data=Some data;_} -> data
         | _ -> fail "restored original authority did not complete retained child results")
       | Error (Canonical_terminal_absent | Canonical_terminal_runtime_active _) -> Eio.Fiber.yield (); await_reuse ()
       | Error error -> fail (Async.canonical_terminal_error_to_string error) in
     let reused = await_reuse () in
     check bool "repaired authority reuses the original available answer" true
       (reused |> member "exports" |> member "answer" |> member "available" |> to_bool);
     let final_ledger = Ledger.load_existing ~config ~trace_id |> require "original ledger after result reuse"
       |> function Some ledger -> ledger | None -> fail "original activation disappeared" in
     check bool "retained results add no child activation or clock" true
       (Ledger.activations restored = Ledger.activations final_ledger);
     check int "completed resume retains original runtime without callback selection" 1 !runtime_reads);
  Printf.printf "composition_nested_public_trial rejected_child=%b prepared_scopes=%d admitted_children=%d child_admission_calls=%d actual_leaf_successes=%d blocked_children=%d parent_deliveries=%d exact_run_binding=true original_task_retained=true model_latency_measured=false\n%!"
    reject_child (List.length scopes) (List.length (Ledger.activations ledger)) !calls successful_leaves blocked_children (List.length delivered)
;;

let test_shared_node_schema_preserves_call_shapes () =
  let surface, reference = fixture () in
  let field = Yojson.Safe.Util.member in
  let schema = Masc.Keeper_composition_draft.prepare_schema.input_schema
    |> field "properties" |> field "nodes" |> field "items" in
  let base = ["id", `String "node"] in
  let ordinary = ["tool", `String "keeper_lane_status"] in
  let child = ["skill_reference", Skill_reference.to_yojson reference] in
  let args = "args", `Assoc [] in
  let child_args = "args", `Assoc ["query", `String "docker"] in
  let input = "input", `Assoc ["kind", `String "literal"; "value", `Assoc []] in
  let child_input = "input", `Assoc ["kind", `String "literal";
    "value", `Assoc ["query", `String "docker"]] in
  let check_shape expected fields =
    let args = `Assoc (base @ fields) in
    let checked = Tool_input_contract.check_arguments ~contract:Tool_input_contract.Host_tool
      ~schema:(Some schema) ~name:"composition node" ~args in
    check bool "shared definitions retain exact node alternatives"
      expected (Result.is_ok checked) in
  List.iter (check_shape true)
    [ordinary; ordinary @ [args]; ordinary @ [input]; child @ [child_args]; child @ [child_input]];
  List.iter (check_shape false)
    [ []; child; ordinary @ child @ [args]; ordinary @ [args;input];
      child @ [child_args;child_input]; ordinary @ ["args", `Null];
      ordinary @ ["after", `Null]; ordinary @ ["unknown", `String "field"] ];
  List.iter (fun fields ->
    ignore (Nested.compile ~execution:Masc.Keeper_tool_composition_catalog.Inline
      ~capability_surface:surface (`Assoc ["nodes", `List [`Assoc (base @ fields)];
        "branch_failure_policy", `String "continue_independent"])
      |> require "advertised Tool and exact Skill nodes still compile"))
    [ordinary @ [args]; child @ [child_args]; child @ [child_input]];
  Printf.printf "composition_schema node_json_bytes=%d prepare_json_bytes=%d run_json_bytes=%d canonical_compiler_changed=false\n%!"
    (String.length (Yojson.Safe.to_string schema))
    (String.length (Yojson.Safe.to_string Masc.Keeper_composition_draft.prepare_schema.input_schema))
    (String.length (Yojson.Safe.to_string Masc.Keeper_composition_draft.run_schema.input_schema))
;;

let () = run "exact inline composition compiler"
    [ "composition", [ test_case "shared node schema preserves public call shapes" `Quick
            test_shared_node_schema_preserves_call_shapes
        ; test_case "repeat exact child, bind params, namespace and map outputs" `Quick test_repeated_child_identity_bindings_and_output_mapping
        ; test_case "whole-child failure barrier with useful independent results" `Quick test_child_failure_blocks_whole_child_consumers_but_keeps_exports
        ; test_case "fixed async child compiles exact canonical result barrier" `Quick test_fixed_async_child_compiles_exact_result_barrier
        ; test_case "upstream arguments bind repeated exact async Skills independently" `Quick
            (test_upstream_child_arguments_bind_exact_declared_plan ~children_first:false)
        ; test_case "forward-declared exact children retain dynamic binding and barriers" `Quick
            (test_upstream_child_arguments_bind_exact_declared_plan ~children_first:true)
        ; test_case "upstream inline arguments preserve namespaces and whole-child failure" `Quick test_upstream_inline_arguments_and_whole_child_failure
        ; test_case "authority, arguments, cycles and semantic refusals" `Quick test_refusals_preserve_frozen_authority_and_contracts
        ; test_case "inline Edit recipes and exact children retain effect and durable admission" `Quick
            test_inline_edit_recipe_preserves_effect_and_durable_admission
        ; test_case "inline Write and exact children retain effect and durable refusal" `Quick
            test_inline_write_keeps_original_effect_and_durable_refusal
        ; test_case "frozen nested draft recipe and exact provenance" `Quick test_nested_draft_freezes_and_revalidates_recipe
        ; test_case "public prepare/run admits exact children once and delivers through parent" `Quick
            (test_public_nested_prepare_run_records_only_admitted_children ~reject_child:false)
        ; test_case "public admission failure keeps independent exports and blocked scopes" `Quick
            (test_public_nested_prepare_run_records_only_admitted_children ~single_call:true ~reject_child:true)
        ; test_case "async parent binds original runtime and exact child results" `Quick
            (test_public_nested_prepare_run_records_only_admitted_children ~single_call:true
              ~execution:Masc.Keeper_tool_composition_catalog.Async ~reject_child:false) ] ]
