open Alcotest
open Masc

module Descriptor = Keeper_tool_descriptor
module Memo = Keeper_descriptor_schema
module Observation = Agent_core.Base.Schema_observation

let schema_exn descriptor =
  match Memo.for_descriptor descriptor with
  | Ok schema -> schema
  | Error detail -> fail detail

let descriptor () =
  match Descriptor.find_id "agent.execute" with
  | None -> fail "Execute descriptor missing"
  | Some original ->
    { original with description = "A fresh descriptor definition" }

let test_identity_and_definition_fidelity () =
  let first = descriptor () in
  let schema = schema_exn first in
  check bool "same physical descriptor shares a schema" true
    (schema == schema_exn first);
  check (option bool) "strict stays absent" None schema.strict;
  check string "descriptor projection owns name" first.public_name schema.name;
  check string "descriptor owns description" first.description schema.description;
  let authoritative = match schema.input_schema with
    | Some input -> input
    | None -> fail "authoritative schema was lost" in
  check bool "full authoritative JSON is retained" true
    (Yojson.Safe.equal first.input_schema authoritative);
  let changed = { first with
    description = "Changed metadata under the same ID";
    input_schema = `Assoc ["type", `String "object";
      "properties", `Assoc ["message", `Assoc ["type", `String "string";
        "minLength", `Int 2; "default", `String "한글"]]] } in
  let changed_schema = schema_exn changed in
  check string "IDs are deliberately equal" first.id changed.id;
  check bool "different physical descriptors do not alias" false
    (schema == changed_schema);
  check string "new description survives" changed.description changed_schema.description;
  check bool "new authoritative constraints survive" true
    (changed_schema.input_schema = Some changed.input_schema);
  check bool "old key still has its own value" true (schema == schema_exn first)

let test_projection_owned_by_descriptor () =
  let public = descriptor () in
  let internal = { public with keeper_model_projection = Descriptor.Internal_name } in
  check string "internal projection does not borrow public name"
    internal.internal_name (schema_exn internal).name;
  let hidden = { public with keeper_model_projection = Descriptor.Operator_only } in
  (match Memo.for_descriptor hidden with
   | Error _ -> ()
   | Ok _ -> fail "operator-only descriptor became a model schema");
  let invalid = { public with input_schema = `String "invalid root" } in
  (match Memo.for_descriptor invalid, Memo.for_descriptor invalid with
   | Error _, Error _ -> ()
   | (Ok _, _) | (_, Ok _) -> fail "invalid descriptor acquired a cached schema")

let successful label =
  Tool_result.make_ok ~tool_name:"schema_reuse_probe"
    ~start_time:(Tool_timing.start ()) ~data:(`String label) ()

let test_fresh_handlers_environment_and_projection () =
  let schema = schema_exn (descriptor ()) in
  let first_calls = ref 0 and second_calls = ref 0 in
  let seen_env = ref None and seen_input = ref None in
  let projection_calls = ref 0 in
  let projection = ref (Tool_output.Inline_up_to {maximum_bytes = 4096}) in
  let build counter label =
    Tool_bridge.agent_core_tool_of_schema_with_execution_env ~schema
      ~model_projection:(fun () -> incr projection_calls; !projection)
      (fun env input ->
        incr counter; seen_env := Some env; seen_input := Some input;
        successful label)
  in
  let first = build first_calls "first" and second = build second_calls "second" in
  check bool "fresh tool wrappers" false (first == second);
  check bool "fresh handler closures" false (first.handler == second.handler);
  check bool "only schema is shared" true (first.schema == second.schema);
  check int "projection is not frozen at construction" 0 !projection_calls;
  let env = Agent_core.Tool.Execution_env.create () in
  let input = `Assoc ["message", `String "exact input"] in
  let invoke tool = match tool.Agent_core.Tool.handler env input with
    | Ok _ -> ()
    | Error error -> fail error.Agent_core.Types.message in
  invoke first;
  check int "first context owns first call" 1 !first_calls;
  check int "second context has not run" 0 !second_calls;
  check bool "exact environment forwarded" true
    (match !seen_env with Some observed -> observed == env | None -> false);
  check bool "exact input forwarded" true
    (match !seen_input with Some observed -> observed == input | None -> false);
  projection := Tool_output.Inline_up_to {maximum_bytes = 8192};
  invoke second;
  check int "second context owns second call" 1 !second_calls;
  check int "projection re-evaluated for both calls" 2 !projection_calls;
  let failure = Failure "exact handler exception" in
  let raising = Tool_bridge.agent_core_tool_of_schema_with_execution_env ~schema
      (fun _ _ -> raise failure) in
  match raising.handler env input with
  | Ok _ | Error _ -> fail "handler exception was swallowed"
  | exception observed -> check bool "same exception escapes" true (observed == failure)

let test_concurrent_publication_winner () =
  let definition = descriptor () in
  let start = Atomic.make false in
  let workers = List.init 4 (fun _ -> Domain.spawn (fun () ->
    while not (Atomic.get start) do Domain.cpu_relax () done;
    schema_exn definition)) in
  Atomic.set start true;
  let values = List.map Domain.join workers in
  let winner = schema_exn definition in
  List.iter (fun schema ->
    check bool "all callers receive the published physical winner" true
      (schema == winner)) values

let[@inline never] unowned_pair () =
  let definition = descriptor () in
  let value = schema_exn definition in
  let key = Weak.create 1 and schema = Weak.create 1 in
  Weak.set key 0 (Some definition);
  Weak.set schema 0 (Some value);
  key, schema

let[@inline never] held_value () =
  let definition = descriptor () in
  let value = schema_exn definition in
  let key = Weak.create 1 in
  Weak.set key 0 (Some definition);
  key, value

let collect () = Gc.full_major (); Gc.full_major (); Gc.compact ()

let test_weak_lifetime () =
  let key, value = unowned_pair () in
  collect ();
  check bool "global memo does not root the descriptor" false (Weak.check key 0);
  check bool "unowned cached value is released" false (Weak.check value 0);
  let key, held = held_value () in
  collect ();
  check bool "held schema has no reverse descriptor edge" false (Weak.check key 0);
  check string "external schema remains usable" "A fresh descriptor definition"
    (Sys.opaque_identity held).description

let test_addon_bypass () =
  let owner = Lane_addon_tool_export.create_owner ~instance_id:"schema-reuse-owner" in
  let tool = match Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc [
    "name", `String "schema_reuse_addon";
    "description", `String "Owned Add-on definition";
    "inputSchema", `Assoc ["type", `String "object"; "properties", `Assoc []]]) with
    | Ok tool -> tool | Error detail -> fail detail in
  let export = Lane_addon_tool_export.create ~owner ~tool in
  let definition = Keeper_lane_addon_descriptor.create export in
  let first = schema_exn definition and second = schema_exn definition in
  check bool "same Add-on descriptor is deliberately not memoized" false (first == second);
  check string "Add-on definition remains faithful" tool.name first.name;
  check bool "bypass preserves authoritative input" true
    (first.input_schema = Some tool.input_schema)

let test_constructor_observation_means_actual_work () =
  Eio_main.run @@ fun _ ->
  let observer = Observation.create ~mode:Identity_only in
  let definition = descriptor () in
  Observation.within observer (fun () ->
    let first = schema_exn definition in
    check bool "warm lookup reuses actual first construction" true
      (first == schema_exn definition));
  let report = Observation.snapshot observer |> Observation.report_to_json in
  let open Yojson.Safe.Util in
  let constructors = report |> member "events" |> to_list |> List.filter (fun event ->
    let payload = member "payload" event in
    member "kind" payload = `String "span_finished"
    && member "operation" payload = `String "constructor") in
  check int "one actual constructor, no fake warm-hit constructor" 1
    (List.length constructors)

let () = run "keeper_descriptor_schema"
  [ "schema-only reuse", [
      test_case "physical identity and full definition fidelity" `Quick test_identity_and_definition_fidelity;
      test_case "descriptor-owned projection and invalid input" `Quick test_projection_owned_by_descriptor;
      test_case "fresh handlers, exact env and per-call projection" `Quick test_fresh_handlers_environment_and_projection;
      test_case "concurrent first publication returns one winner" `Quick test_concurrent_publication_winner;
      test_case "weak descriptor and schema lifetime" `Quick test_weak_lifetime;
      test_case "typed Add-on bypass" `Quick test_addon_bypass;
      test_case "only actual constructors are observed" `Quick test_constructor_observation_means_actual_work ] ]
