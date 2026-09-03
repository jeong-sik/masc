open Alcotest

module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan

let valid_catalog =
  {|[[compositions]]
name = "time-memory-query"
description = "Feed the exact clock result into memory search."
execution = "inline"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["time"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "/now_iso"
|}
;;

let node_id value =
  match Plan.Node_id.make value with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> fail "unexpected empty node id"
;;

let test_catalog_builds_executable_typed_plan () =
  let catalog =
    match Catalog.parse valid_catalog with
    | Ok catalog -> catalog
    | Error _ -> fail "valid composition catalog was rejected"
  in
  check int "one catalog entry" 1 (List.length (Catalog.entries catalog));
  let entry =
    match Catalog.find catalog "time-memory-query" with
    | Some entry -> entry
    | None -> fail "composition lookup missed exact name"
  in
  check
    (option string)
    "description"
    (Some "Feed the exact clock result into memory search.")
    entry.description;
  let layers = Plan.dependency_layers entry.plan in
  check
    (list (list string))
    "typed dependency layers"
    [ [ "time" ]; [ "search" ] ]
    (List.map
       (List.map (fun node -> Plan.Node_id.to_string node.Plan.id))
       layers);
  let run_id = Plan.Run_id.fresh () in
  let time_output =
    match
      Plan.validate_output
        entry.plan
        ~run_id
        ~node_id:(node_id "time")
        (`Assoc
            [ "now_iso", `String "2026-08-14T00:00:00Z"
            ; "now_unix", `Float 0.0
            ])
    with
    | Ok output -> output
    | Error _ -> fail "valid clock output was rejected"
  in
  match
    Plan.resolve_input
      entry.plan
      ~run_id
      ~node_id:(node_id "search")
      ~lookup:(fun id ->
        if Plan.Node_id.equal id (node_id "time") then Some time_output else None)
  with
  | Ok (`Assoc [ ("query", `String "2026-08-14T00:00:00Z") ]) -> ()
  | Ok value ->
    failf "resolved catalog input changed shape: %s" (Yojson.Safe.to_string value)
  | Error _ -> fail "catalog output reference did not resolve"
;;

let test_catalog_rejects_unknown_fields () =
  let document =
    {|[[compositions]]
name = "bad"
execution = "inline"
guess = true
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
input = { kind = "literal", value = {} }
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Unknown_field
        { path = [ "compositions"; "0" ]; field = "guess" }) -> ()
  | Error _ | Ok _ -> fail "unknown composition field was not rejected"
;;

let test_catalog_rejects_malformed_output_pointer () =
  let document =
    {|[[compositions]]
name = "bad-pointer"
execution = "inline"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "now_iso"
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Invalid_json_pointer
        { error = Plan.Json_pointer.Missing_initial_slash; _ }) -> ()
  | Error _ | Ok _ -> fail "non-RFC6901 output pointer was accepted"
;;

let one_node_composition name =
  Printf.sprintf
    {|[[compositions]]
name = %S
execution = "inline"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
    name
;;

let one_node_async_composition name =
  Printf.sprintf
    {|[[compositions]]
name = %S
execution = "async"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
    name
;;

let test_catalog_requires_explicit_execution_mode () =
  let document =
    {|[[compositions]]
name = "missing-execution"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Missing_field
        { path = [ "compositions"; "0" ]; field = "execution" }) ->
    ()
  | Error _ | Ok _ -> fail "composition execution mode was inferred"
;;

let test_catalog_accepts_async_only_for_statically_read_only_tools () =
  let catalog =
    match Catalog.parse (one_node_async_composition "clock-background") with
    | Ok catalog -> catalog
    | Error error -> fail (Catalog.error_to_string error)
  in
  let entry =
    match Catalog.find catalog "clock-background" with
    | Some entry -> entry
    | None -> fail "async composition lookup failed"
  in
  (match entry.execution with
   | Catalog.Async -> ()
   | Catalog.Inline -> fail "async execution mode was rewritten");
  check string "async tool name" "keeper_compose_clock-background" (Catalog.tool_name entry);
  check string "status control name" "keeper_composition_status" Catalog.status_tool_name;
  check string "cancel control name" "keeper_composition_cancel" Catalog.cancel_tool_name
;;

let test_catalog_rejects_async_effectful_tool () =
  let document =
    {|[[compositions]]
name = "write-background"
execution = "async"
[[compositions.nodes]]
id = "write"
tool = "keeper_memory_write"
[compositions.nodes.input]
kind = "literal"
value = { title = "not admitted", content = "effectful async" }
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Async_tool_not_statically_read_only
        { name = "write-background"; node_id; tool_name = "keeper_memory_write" }) ->
    check string "rejected node" "write" (Plan.Node_id.to_string node_id)
  | Error _ | Ok _ -> fail "effectful async composition was admitted"
;;

let test_catalog_projects_stable_tool_name_and_path () =
  let catalog =
    match Catalog.parse (one_node_composition "clock-check") with
    | Ok catalog -> catalog
    | Error _ -> fail "valid named composition was rejected"
  in
  let entry =
    match Catalog.find catalog "clock-check" with
    | Some entry -> entry
    | None -> fail "named composition lookup failed"
  in
  check string "model-visible tool name" "keeper_compose_clock-check"
    (Catalog.tool_name entry)
;;

let test_catalog_rejects_name_outside_tool_alphabet () =
  match Catalog.parse (one_node_composition "clock check") with
  | Error
      (Catalog.Invalid_composition_name_character
        { name = "clock check"; character = ' ' }) -> ()
  | Error _ | Ok _ -> fail "composition name outside the tool alphabet was accepted"
;;

let test_catalog_rejects_name_beyond_provider_limit () =
  let name = String.make 50 'a' in
  match Catalog.parse (one_node_composition name) with
  | Error
      (Catalog.Composition_name_too_long
        { name = actual; maximum_bytes = 49 }) ->
    check string "rejected exact name" name actual
  | Error _ | Ok _ -> fail "composition name beyond provider limit was accepted"
;;

let test_catalog_rejects_duplicate_composition_names () =
  let document = one_node_composition "same" ^ one_node_composition "same" in
  match Catalog.parse document with
  | Error (Catalog.Duplicate_composition_name "same") -> ()
  | Error _ | Ok _ -> fail "duplicate composition name was accepted"
;;

let test_catalog_rejects_unknown_tool_through_plan_authority () =
  let document =
    {|[[compositions]]
name = "unknown-tool"
execution = "inline"
[[compositions.nodes]]
id = "unknown"
tool = "invented_tool"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Plan_rejected
        { error = Plan.Unknown_tool { tool_name = "invented_tool"; _ }; _ }) -> ()
  | Error _ | Ok _ -> fail "catalog bypassed canonical plan tool authority"
;;

let param_composition =
  {|[[compositions]]
name = "memory-probe"
description = "Search durable memory for the caller's query."
execution = "inline"

[[compositions.params]]
name = "query"
type = "string"
description = "What to search durable memory for."

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
|}
;;

let parse_ok document =
  match Catalog.parse document with
  | Ok catalog -> catalog
  | Error error ->
    fail ("valid composition was rejected: " ^ Catalog.error_to_string error)
;;

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec probe index =
    if index + needle_length > haystack_length
    then false
    else if String.equal (String.sub haystack index needle_length) needle
    then true
    else probe (index + 1)
  in
  probe 0
;;

let test_catalog_params_generate_schema_and_bind () =
  let catalog = parse_ok param_composition in
  let entry =
    match Catalog.find catalog "memory-probe" with
    | Some entry -> entry
    | None -> fail "param composition lookup missed exact name"
  in
  check int "one declared param" 1 (List.length entry.Catalog.params);
  let schema =
    Yojson.Safe.to_string (Catalog.input_schema_of_params entry.Catalog.params)
  in
  check
    bool
    "schema requires the declared param"
    true
    (contains ~needle:{|"required":["query"]|} schema);
  check
    bool
    "schema types the declared param"
    true
    (contains ~needle:{|"type":"string"|} schema);
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  (match
     Catalog.instantiate
       ~descriptors
       ~args:(`Assoc [ "query", `String "what changed today" ])
       entry
   with
   | Ok plan ->
     let leftover =
       Plan.nodes plan
       |> List.concat_map (fun (node : Plan.node) ->
         Plan.Json_template.param_names node.input)
     in
     check int "instantiated plan is param-free" 0 (List.length leftover)
   | Error error ->
     fail
       ("instantiation with full args failed: "
        ^ Catalog.instantiation_error_to_string error));
  match Catalog.instantiate ~descriptors ~args:(`Assoc []) entry with
  | Error (Catalog.Missing_argument "query") -> ()
  | Ok _ -> fail "instantiation without args was accepted"
  | Error error ->
    fail ("unexpected error: " ^ Catalog.instantiation_error_to_string error)
;;

let test_zero_param_instantiation_revalidates_turn_surface () =
  let entry =
    let catalog = parse_ok valid_catalog in
    match Catalog.find catalog "time-memory-query" with
    | Some entry -> entry
    | None -> fail "zero-param composition lookup missed exact name"
  in
  let descriptors =
    Masc.Keeper_tool_descriptor.all_descriptors ()
    |> List.filter (fun descriptor ->
      Masc.Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.exists (String.equal "keeper_time_now"))
  in
  match Catalog.instantiate ~descriptors ~args:(`Assoc []) entry with
  | Error
      ((Catalog.Instantiated_plan_rejected
          (Plan.Unknown_tool { tool_name = "keeper_memory_search"; _ })) as
        error) ->
    let projection = Catalog.instantiation_error_to_json error in
    let open Yojson.Safe.Util in
    check string
      "instantiation error kind"
      "instantiated_plan_rejected"
      (projection |> member "kind" |> to_string);
    check string
      "typed plan error survives"
      "unknown_tool"
      (projection |> member "error" |> member "kind" |> to_string);
    check string
      "typed tool identity survives"
      "keeper_memory_search"
      (projection |> member "error" |> member "tool_name" |> to_string)
  | Ok _ -> fail "zero-param composition recovered the global Tool catalog"
  | Error error ->
    fail
      ("wrong zero-param surface rejection: "
       ^ Catalog.instantiation_error_to_string error)
;;

let test_catalog_rejects_param_declaration_mismatches () =
  let undeclared_reference =
    {|[[compositions]]
name = "probe"
description = "d"
execution = "inline"

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
|}
  in
  (match Catalog.parse undeclared_reference with
   | Error (Catalog.Unknown_param_reference { name = "probe"; param = "query" }) -> ()
   | Ok _ -> fail "undeclared param reference was accepted"
   | Error error -> fail ("unexpected error: " ^ Catalog.error_to_string error));
  let unused_declaration =
    {|[[compositions]]
name = "probe"
description = "d"
execution = "inline"

[[compositions.params]]
name = "query"
type = "string"
description = "unused"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
  in
  (match Catalog.parse unused_declaration with
   | Error (Catalog.Unused_param { name = "probe"; param = "query" }) -> ()
   | Ok _ -> fail "unused declared param was accepted"
   | Error error -> fail ("unexpected error: " ^ Catalog.error_to_string error));
  let bad_type =
    {|[[compositions]]
name = "probe"
description = "d"
execution = "inline"

[[compositions.params]]
name = "query"
type = "object"
description = "wrong"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
  in
  (match Catalog.parse bad_type with
   | Error (Catalog.Invalid_param_type { type_name = "object"; _ }) -> ()
   | Ok _ -> fail "invalid param type was accepted"
   | Error error -> fail ("unexpected error: " ^ Catalog.error_to_string error));
  let async_with_params =
    {|[[compositions]]
name = "probe"
description = "d"
execution = "async"

[[compositions.params]]
name = "query"
type = "string"
description = "bound at submission"

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
|}
  in
  (* An async composition binds params at submission — the broker never
     replays a worker closure after a crash, so the bound plan lives exactly
     as long as the run. The read-only gate still applies unchanged. *)
  match Catalog.parse async_with_params with
  | Ok catalog ->
    (match Catalog.find catalog "probe" with
     | Some entry ->
       check string "async execution survives"
         "async"
         (Catalog.execution_mode_to_string entry.Catalog.execution);
       check int "declared param survives" 1 (List.length entry.Catalog.params)
     | None -> fail "async param composition lookup missed exact name")
  | Error error ->
    fail
      ("async composition with params was rejected: "
       ^ Catalog.error_to_string error)
;;

(* A composition tool ships no TOML, so "which file defines this" has to
   resolve to the SKILL.md the catalog read. Composed from the name, which is
   sound only because the tool exists as a consequence of that file. *)
let test_skill_source_names_the_skill_file () =
  match Catalog.skill_source_of_tool_name "keeper_compose_mission-snapshot" with
  | Some rel ->
    Alcotest.(check string)
      "skill definition path"
      "skills/mission-snapshot/SKILL.md"
      rel
  | None -> Alcotest.fail "a composition tool must name its skill file"
;;

let test_skill_source_ignores_other_tools () =
  List.iter
    (fun name ->
      match Catalog.skill_source_of_tool_name name with
      | None -> ()
      | Some rel -> Alcotest.failf "%s is not a composition tool, got %s" name rel)
    [ "keeper_spawn"; "Execute"; Catalog.status_tool_name; "keeper_compose_" ]
;;


(* The failure payload is truncated on the serialized string at
   [Keeper_tool_call_log.max_output_len], so its field order decides what a
   reader can still see. [settled] carries one entry per node with that node's
   whole result; a composition over a task list produced 12KB there, the cut
   landed inside it, and eight failures were recorded with no readable reason
   (2026-09-03). This pins that the diagnosis outlives the cut. *)
let test_failure_payload_keeps_cause_under_truncation () =
  let big_node index =
    `Assoc
      [ "node_id", `String (Printf.sprintf "node-%d" index)
      ; "tool_name", `String "keeper_tasks_list"
      ; "result", `String (String.make 4000 'x')
      ]
  in
  let payload =
    Masc.Keeper_tool_composition_surface.For_testing.failure_payload
      ~tool_name:"keeper_compose_work-intake"
      ~tool_kind:Masc.Keeper_tool_descriptor.Composition_tool
      ~cause:(`Assoc [ "kind", `String "plan_execution_failed" ])
      ~effect_disposition:"no_effect"
      ~settled:(List.init 3 big_node)
  in
  let serialized = Yojson.Safe.to_string payload in
  check
    bool
    "the payload is longer than the durable row keeps"
    true
    (String.length serialized > Masc.Keeper_tool_call_log.max_output_len);
  let kept = String.sub serialized 0 Masc.Keeper_tool_call_log.max_output_len in
  let contains needle haystack =
    let n = String.length needle in
    let rec scan i =
      if i + n > String.length haystack
      then false
      else if String.sub haystack i n = needle
      then true
      else scan (i + 1)
    in
    scan 0
  in
  check bool "cause survives the cut" true (contains "\"cause\"" kept);
  check
    bool
    "effect_disposition survives the cut"
    true
    (contains "\"effect_disposition\"" kept)
;;

let () =
  run
    "keeper_tool_composition_catalog"
    [ ( "catalog"
      , [ test_case
            "builds executable typed plan"
            `Quick
            test_catalog_builds_executable_typed_plan
        ; test_case "rejects unknown fields" `Quick test_catalog_rejects_unknown_fields
        ; test_case
            "rejects malformed pointer"
            `Quick
            test_catalog_rejects_malformed_output_pointer
        ; test_case
            "rejects duplicate names"
            `Quick
            test_catalog_rejects_duplicate_composition_names
        ; test_case
            "requires explicit execution mode"
            `Quick
            test_catalog_requires_explicit_execution_mode
        ; test_case
            "accepts async statically read-only plan"
            `Quick
            test_catalog_accepts_async_only_for_statically_read_only_tools
        ; test_case
            "rejects async effectful tool"
            `Quick
            test_catalog_rejects_async_effectful_tool
        ; test_case
            "projects stable tool name and path"
            `Quick
            test_catalog_projects_stable_tool_name_and_path
        ; test_case
            "rejects unsupported name characters"
            `Quick
            test_catalog_rejects_name_outside_tool_alphabet
        ; test_case
            "rejects name beyond provider limit"
            `Quick
            test_catalog_rejects_name_beyond_provider_limit
        ; test_case
            "rejects unknown tools"
            `Quick
            test_catalog_rejects_unknown_tool_through_plan_authority
        ; test_case
            "params generate the input schema and bind arguments"
            `Quick
            test_catalog_params_generate_schema_and_bind
        ; test_case
            "zero-param instantiation revalidates the turn surface"
            `Quick
            test_zero_param_instantiation_revalidates_turn_surface
        ; test_case
            "param declaration mismatches are rejected"
            `Quick
            test_catalog_rejects_param_declaration_mismatches
        ; test_case
            "a composition tool names its skill file"
            `Quick
            test_skill_source_names_the_skill_file
        ; test_case
            "other tool names resolve to none"
            `Quick
            test_skill_source_ignores_other_tools
        ; test_case
            "a failed composition keeps its cause when the row is truncated"
            `Quick
            test_failure_payload_keeps_cause_under_truncation
        ] )
    ]
;;
