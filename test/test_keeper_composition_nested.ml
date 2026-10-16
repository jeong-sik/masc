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

let test_nested_draft_freezes_and_revalidates_recipe () =
  Eio_main.run @@ fun _ ->
  with_base @@ fun base_path ->
  let surface, reference = fixture () in
  let recipe = request ~exports:[ exported "answer" "child" pointer ] [ nested "child" reference ] in
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
   | Error Draft.Nested_async_requires_worker_binding -> () | _ -> fail "async child captured an active-turn recorder");
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

let test_public_nested_prepare_run_records_only_admitted_children ~reject_child () =
  Eio_main.run @@ fun env ->
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
  let recorder = Recorder.make ~trace_id ~turn_ref ~runtime_id:(fun () -> Some "fixture.runtime")
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
  let tools = Tools.make_tools ~capability_surface:surface ~config ~meta ~publication_recovery ~ctx_snapshot
      ~record_nested_composition_activation:record () in
  let invoke id name input =
    let tool = List.find_map (fun (tool, _, _) -> if tool.Agent_core.Tool.schema.name = name then Some tool else None) tools
      |> function Some value -> value | None -> fail ("public control absent: " ^ name) in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:id ~turn:1
        ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Agent_core.Tool_contract.Serial }
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    let success, content = match Agent_core.Tool.execute ~invocation tool input with
      | Ok output -> true, output.content | Error error -> false, error.Agent_core.Types.message in
    let structured =
      match Tool_output.decode_from_agent_core content with
      | Tool_output.Decoded reference -> read_document ~base_path reference
      | Tool_output.Not_marker ->
        Yojson.Safe.from_string content |> Yojson.Safe.Util.member "structured_content"
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
  let input = match recipe with `Assoc fields -> `Assoc (("execution", `String "inline") :: fields)
    | _ -> fail "recipe object" in
  let prepare_success, _, prepared = invoke "prepare-nested" Draft.prepare_tool_name input in
  check bool "public prepare accepts nested grammar" true prepare_success;
  check int "preparation is not activation" 0 !calls;
  let open Yojson.Safe.Util in
  let draft_reference = prepared |> member "draft" |> decode_reference in
  let success, result_content, result = invoke "run-nested" Draft.run_tool_name
      (`Assoc [ "sha256", `String draft_reference.sha256 ]) in
  check bool "actual aggregate failure stays failure" (not reject_child) success;
  check int "one admission per attempted child, independent of leaf count" (if reject_child then 3 else 2) !calls;
  let run_reference = result |> member "run_artifact" |> decode_reference in
  let run_binding = read_document ~base_path run_reference in
  let run_id = run_binding |> member "composition_run_id" |> to_string in
  check string "public result retains pre-dispatch run" run_id (result |> member "composition_run_id" |> to_string);
  check bool "run binding retains all exact child mappings" true
    (Yojson.Safe.equal (run_binding |> member "nested_calls") (prepared |> member "nested_calls"));
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
    match activation.invocation with
    | Ledger.Nested_composition_invocation { scope; origin = Ledger.Task_composition { task_ids }; tool_name } ->
      check string "actual child binds original Tool receipt" "run-nested" scope.parent_tool_use_id;
      check string "actual child binds same composition run" run_id scope.composition_run_id;
      check string "actual child records public Tool" Draft.run_tool_name tool_name;
      check (list string) "original task attribution retained" [ "task-nested" ]
        (Ledger.task_id_set_to_list task_ids |> List.map Keeper_id.Task_id.to_string);
      check bool "exact source identity retained" true (Skill_reference.equal_identity reference.identity activation.identity)
    | _ -> fail "canonical nested task origin missing") (Ledger.activations ledger);
  let receipt : Ledger.tool_result_receipt =
    { tool_use_id = "run-nested"; content_bytes = String.length result_content
    ; content_sha256 = Digestif.SHA256.(digest_string result_content |> to_hex) } in
  let delivered = Recorder.observe_delivery ~config recorder ~tool_results:[ receipt ]
      ~boundary:(Ledger.Model_response { agent_core_turn = 2 }) ~runtime_id:"fixture.runtime"
      |> require "deliver actual public result to its children" in
  check int "actual parent result delivers both activated children" 2 (List.length delivered);
  Printf.printf "composition_nested_public_trial rejected_child=%b prepared_scopes=%d admitted_children=%d child_admission_calls=%d actual_leaf_successes=%d blocked_children=%d parent_deliveries=%d exact_run_binding=true original_task_retained=true model_latency_measured=false\n%!"
    reject_child (List.length scopes) (List.length (Ledger.activations ledger)) !calls successful_leaves blocked_children (List.length delivered)
;;

let () = run "exact inline composition compiler"
    [ "composition", [ test_case "repeat exact child, bind params, namespace and map outputs" `Quick test_repeated_child_identity_bindings_and_output_mapping
        ; test_case "whole-child failure barrier with useful independent results" `Quick test_child_failure_blocks_whole_child_consumers_but_keeps_exports
        ; test_case "authority, arguments, cycles and semantic refusals" `Quick test_refusals_preserve_frozen_authority_and_contracts
        ; test_case "frozen nested draft recipe and exact provenance" `Quick test_nested_draft_freezes_and_revalidates_recipe
        ; test_case "public prepare/run admits exact children once and delivers through parent" `Quick
            (test_public_nested_prepare_run_records_only_admitted_children ~reject_child:false)
        ; test_case "public admission failure keeps independent exports and blocked scopes" `Quick
            (test_public_nested_prepare_run_records_only_admitted_children ~reject_child:true) ] ]
