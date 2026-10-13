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

let fixture ?(source = document ()) ?(skill_names = None) ?(tool_deny = []) () =
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
  check int "valid fixture catalog" 0 (List.length diagnostics);
  let surface = Surface.create ~tool_deny ~sandbox_profile:Masc.Keeper_types_profile.Docker
      ~skill_names ~global_skill_catalog ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot snapshot)
      ~task_skills:[] in
  let reference = match Snapshot.entries snapshot with
    | [ entry ] -> Snapshot.entry_reference entry | _ -> fail "one exact entry" in
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
let compile surface json = match Nested.compile ~capability_surface:surface json with
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
  check bool "canonical fixed bindings retained" true (Yojson.Safe.equal call.args (`Assoc [ "query", `String "docker" ]));
  let good_id = List.find (fun (id, _) -> Plan.Node_id.to_string id = "lane/~profile") call.node_mapping |> snd in
  let downstream = Plan.nodes plan |> List.find (fun (node : Plan.node) -> node.tool_name = "keeper_memory_search"
      && List.length (Plan.dependencies node) = 2) in
  check (list string) "consumer depends on whole child scope"
    (List.map (fun (_, id) -> Plan.Node_id.to_string id) call.node_mapping |> List.sort String.compare)
    (Plan.dependencies downstream |> List.map Plan.Node_id.to_string |> List.sort String.compare);
  let export = List.hd (Plan.exports plan) in
  check bool "named child export maps exact producer" true (Plan.Node_id.equal good_id export.node_id);
  check string "escaped export name resolves to producer pointer" "/profile" (Plan.Json_pointer.to_string export.pointer);
  let evidence = match Nested.calls_to_json compiled with
    | `List (first :: _) -> first | _ -> fail "durable nested evidence missing" in
  check bool "durable evidence preserves exact pinned reference" true
    (Yojson.Safe.equal (Yojson.Safe.Util.member "reference" evidence) (Skill_reference.to_yojson reference));
  check bool "durable evidence preserves bound args" true
    (Yojson.Safe.equal (Yojson.Safe.Util.member "args" evidence) call.args)
;;

let test_child_failure_blocks_whole_child_consumers_but_keeps_exports () =
  Eio_main.run @@ fun _ ->
  let surface, reference = fixture () in
  let compiled = compile surface (request ~exports:[ exported "answer" "child" pointer ]
      [ nested "child" reference; consumer "uses-export" "child" pointer
      ; leaf ~after:[ "child" ] "uses-after"; leaf "independent" ]) in
  let plan = Nested.plan compiled in
  let dispatched = ref [] in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
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

let test_refusals_preserve_frozen_authority_and_contracts () =
  let surface, reference = fixture () in
  let check_error label surface json accepts = match Nested.compile ~capability_surface:surface json with
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

let () = run "exact inline composition compiler"
    [ "composition", [ test_case "repeat exact child, bind params, namespace and map outputs" `Quick test_repeated_child_identity_bindings_and_output_mapping
        ; test_case "whole-child failure barrier with useful independent results" `Quick test_child_failure_blocks_whole_child_consumers_but_keeps_exports
        ; test_case "authority, arguments, cycles and semantic refusals" `Quick test_refusals_preserve_frozen_authority_and_contracts ] ]
