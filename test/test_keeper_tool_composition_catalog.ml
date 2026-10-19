open Alcotest

module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan

let valid_catalog =
  {|[[compositions]]
name = "status-memory-query"
description = "Feed the lane profile into memory search."
execution = "inline"

[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["lane"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "lane"
pointer = "/profile"
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
    match Catalog.find catalog "status-memory-query" with
    | Some entry -> entry
    | None -> fail "composition lookup missed exact name"
  in
  check
    (option string)
    "description"
    (Some "Feed the lane profile into memory search.")
    entry.description;
  let layers = Plan.dependency_layers entry.plan in
  check
    (list (list string))
    "typed dependency layers"
    [ [ "lane" ]; [ "search" ] ]
    (List.map
       (List.map (fun node -> Plan.Node_id.to_string node.Plan.id))
       layers);
  let run_id = Plan.Run_id.fresh () in
  let lane_output =
    match
      Plan.validate_output
        entry.plan
        ~run_id
        ~node_id:(node_id "lane")
        (`Assoc
            [ "profile", `String "docker"
            ; "lane", `Null
            ; "endpoint", `Null
            ; "operator_action", `Null
            ])
    with
    | Ok output -> output
    | Error _ -> fail "valid lane output was rejected"
  in
  match
    Plan.resolve_input
      entry.plan
      ~run_id
      ~node_id:(node_id "search")
      ~lookup:(fun id ->
        if Plan.Node_id.equal id (node_id "lane") then Some lane_output else None)
  with
  | Ok (`Assoc [ ("query", `String "docker") ]) -> ()
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
id = "lane"
tool = "keeper_lane_status"
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
id = "lane"
tool = "keeper_lane_status"
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
node = "lane"
pointer = "profile"
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
id = "lane"
tool = "keeper_lane_status"
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
id = "lane"
tool = "keeper_lane_status"
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
id = "lane"
tool = "keeper_lane_status"
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

let test_catalog_accepts_async_readonly_tools () =
  let catalog =
    match Catalog.parse (one_node_async_composition "lane-background") with
    | Ok catalog -> catalog
    | Error error -> fail (Catalog.error_to_string error)
  in
  let entry =
    match Catalog.find catalog "lane-background" with
    | Some entry -> entry
    | None -> fail "async composition lookup failed"
  in
  (match entry.execution with
   | Catalog.Async -> ()
   | Catalog.Inline -> fail "async execution mode was rewritten");
  check string "async tool name" "keeper_compose_lane-background" (Catalog.tool_name entry);
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
      (Catalog.Async_leaf_not_admitted
        { name = "write-background"; node_id; tool_name = "keeper_memory_write" }) ->
    check string "rejected node" "write" (Plan.Node_id.to_string node_id)
  | Error _ | Ok _ -> fail "effectful async composition was admitted"
;;

let test_catalog_projects_stable_tool_name_and_path () =
  let catalog =
    match Catalog.parse (one_node_composition "lane-check") with
    | Ok catalog -> catalog
    | Error _ -> fail "valid named composition was rejected"
  in
  let entry =
    match Catalog.find catalog "lane-check" with
    | Some entry -> entry
    | None -> fail "named composition lookup failed"
  in
  check string "model-visible tool name" "keeper_compose_lane-check"
    (Catalog.tool_name entry)
;;

let test_catalog_rejects_name_outside_tool_alphabet () =
  match Catalog.parse (one_node_composition "lane check") with
  | Error
      (Catalog.Invalid_composition_name_character
        { name = "lane check"; character = ' ' }) -> ()
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

(* A composition declares [defer_loading] in its own block, as a tool file
   does. Absent or false is always loaded; a value that is not a boolean is
   refused rather than read as either answer. *)
let composition_with_line line =
  Printf.sprintf
    {|[[compositions]]
name = "lane-check"
execution = "inline"
%s
[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
    line
;;

let test_catalog_reads_defer_loading () =
  let loading_of document =
    match Catalog.parse document with
    | Error error -> fail ("valid composition was rejected: " ^ Catalog.error_to_string error)
    | Ok catalog ->
      (match Catalog.find catalog "lane-check" with
       | Some entry -> entry.Catalog.loading
       | None -> fail "named composition lookup failed")
  in
  check bool "true defers" true
    (loading_of (composition_with_line "defer_loading = true")
     = Tool_definition_toml.Deferrable);
  check bool "false stays loaded" true
    (loading_of (composition_with_line "defer_loading = false")
     = Tool_definition_toml.Always_loaded);
  check bool "absent stays loaded" true
    (loading_of (composition_with_line "") = Tool_definition_toml.Always_loaded);
  match Catalog.parse (composition_with_line {|defer_loading = "yes"|}) with
  | Error (Catalog.Wrong_value_kind { field = "defer_loading"; expected = Catalog.Bool_value; _ }) ->
    ()
  | Error error -> fail ("string defer_loading: " ^ Catalog.error_to_string error)
  | Ok _ -> fail "a string defer_loading was accepted"
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
    match Catalog.find catalog "status-memory-query" with
    | Some entry -> entry
    | None -> fail "zero-param composition lookup missed exact name"
  in
  let descriptors =
    Masc.Keeper_tool_descriptor.all_descriptors ()
    |> List.filter (fun descriptor ->
      Masc.Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.exists (String.equal "keeper_lane_status"))
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
id = "lane"
tool = "keeper_lane_status"
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
id = "lane"
tool = "keeper_lane_status"
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

(* One read whose mode the caller picks from a closed set. [param_lines] is
   spliced between the param's name and description so each case varies only
   the declaration under test. *)
let read_mode_composition ~param_lines =
  {|[[compositions]]
name = "read-mode"
description = "Read one automation tab in the chosen mode."
execution = "inline"

[[compositions.params]]
name = "mode"
|}
  ^ param_lines
  ^ {|
description = "Which read to return."

[[compositions.nodes]]
id = "read"
tool = "BrowserRead"
input = { kind = "object", fields = [
  { name = "lane", value = { kind = "literal", value = "automation" } },
  { name = "tabId", value = { kind = "literal", value = 1 } },
  { name = "mode", value = { kind = "param", name = "mode" } }
] }
|}
;;

let read_mode_entry () =
  let catalog =
    parse_ok
      (read_mode_composition
         ~param_lines:{|type = "string"
enum = ["scene", "regions"]|})
  in
  match Catalog.find catalog "read-mode" with
  | Some entry -> entry
  | None -> fail "enum param composition lookup missed exact name"
;;

let test_enum_param_projects_members_and_binds () =
  let entry = read_mode_entry () in
  (match entry.Catalog.params with
   | [ { Catalog.param_type = Catalog.Enum_param [ "scene"; "regions" ]; _ } ] -> ()
   | _ -> fail "enum param did not keep its members in declared order");
  let schema = Catalog.input_schema_of_params entry.Catalog.params in
  let open Yojson.Safe.Util in
  let property = schema |> member "properties" |> member "mode" in
  check string "enum property is a string" "string" (property |> member "type" |> to_string);
  check
    (list string)
    "schema lists the members"
    [ "scene"; "regions" ]
    (property |> member "enum" |> to_list |> List.map to_string);
  (* The composition handler checks its arguments again with masc's own input
     validation before binding, so a member has to pass that check too. *)
  (match
     Masc.Tool_input_validation.validate_args
       ~schema
       ~name:"keeper_compose_read-mode"
       ~args:(`Assoc [ "mode", `String "regions" ])
       ()
   with
   | Ok _ -> ()
   | Error _ -> fail "input validation refused a declared member");
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  (match
     Catalog.instantiate ~descriptors ~args:(`Assoc [ "mode", `String "regions" ]) entry
   with
   | Ok plan ->
     let bound_mode =
       Plan.nodes plan
       |> List.find_map (fun (node : Plan.node) ->
         match node.input with
         | Plan.Json_template.Object fields -> List.assoc_opt "mode" fields
         | Plan.Json_template.Literal _
         | Plan.Json_template.Output _
         | Plan.Json_template.Param _
         | Plan.Json_template.Array _ -> None)
     in
     (match bound_mode with
      | Some (Plan.Json_template.Literal (`String "regions")) -> ()
      | Some _ | None -> fail "the chosen member was not bound as a literal")
   | Error error ->
     fail ("a declared member failed to bind: " ^ Catalog.instantiation_error_to_string error));
  match Catalog.instantiate ~descriptors ~args:(`Assoc []) entry with
  | Error (Catalog.Missing_argument "mode") -> ()
  | Ok _ -> fail "a missing enum argument was bound"
  | Error error ->
    fail ("wrong refusal for a missing value: " ^ Catalog.instantiation_error_to_string error)
;;

let test_enum_param_declaration_errors () =
  let parse_error param_lines =
    match Catalog.parse (read_mode_composition ~param_lines) with
    | Error error -> error
    | Ok _ -> fail ("declaration was accepted: " ^ param_lines)
  in
  (match parse_error {|type = "integer"
enum = ["scene", "regions"]|} with
   | Catalog.Param_enum_requires_string_type { type_name = "integer"; _ } -> ()
   | error -> fail ("enum on integer: " ^ Catalog.error_to_string error));
  (match parse_error {|type = "string"
enum = []|} with
   | Catalog.Empty_param_enum _ -> ()
   | error -> fail ("empty enum: " ^ Catalog.error_to_string error));
  (match parse_error {|type = "string"
enum = ["scene", "scene"]|} with
   | Catalog.Duplicate_param_enum_value { value = "scene"; _ } -> ()
   | error -> fail ("repeated member: " ^ Catalog.error_to_string error));
  List.iter
    (fun (label, members, expected_value, expected_fault) ->
       match parse_error ("type = \"string\"\nenum = " ^ members) with
       | Catalog.Unsendable_param_enum_value { value; fault; _ }
         when String.equal value expected_value && fault = expected_fault -> ()
       | error -> fail (label ^ ": " ^ Catalog.error_to_string error))
    [ "empty member", {|["scene", ""]|}, "", Catalog.Empty_value
    ; "leading whitespace", {|[" scene", "regions"]|}, " scene", Catalog.Padded_value
    ; "trailing whitespace", {|["scene", "regions "]|}, "regions ", Catalog.Padded_value
    ; "line feed inside", {|["scene", "re\ngions"]|}, "re\ngions", Catalog.Line_break_in_value
    ; ( "carriage return inside"
      , {|["scene", "re\rgions"]|}
      , "re\rgions"
      , Catalog.Line_break_in_value )
    ; ( "spaced separator inside"
      , {|["scene | regions", "text"]|}
      , "scene | regions"
      , Catalog.Separator_in_value )
    ; "separator ending a member", {|["x |", "y"]|}, "x |", Catalog.Separator_in_value
    ; ( "padding is reported before a separator"
      , {|[" x|y", "z"]|}
      , " x|y"
      , Catalog.Padded_value )
    ];
  (match parse_error {|type = "string"
enum = "scene"|} with
   | Catalog.Wrong_value_kind { field = "enum"; expected = Catalog.String_array_value; _ } ->
     ()
   | error -> fail ("scalar enum: " ^ Catalog.error_to_string error));
  match parse_error {|type = "string"
values = ["scene", "regions"]|} with
  | Catalog.Unknown_field { field = "values"; _ } -> ()
  | error -> fail ("unknown member field: " ^ Catalog.error_to_string error)
;;

(* A composition tool ships no TOML, so "which file defines this" has to
   resolve to the SKILL.md the catalog read. Composed from the name, which is
   sound only because the tool exists as a consequence of that file. *)
let test_skill_source_names_the_skill_file () =
  match Catalog.skill_source_of_tool_name "keeper_compose_work-intake" with
  | Some rel ->
    Alcotest.(check string)
      "skill definition path"
      "skills/work-intake/SKILL.md"
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

let export_catalog_fixture = {|[[compositions]]
name = "read-path"
execution = "inline"
branch_failure_policy = "continue_independent"

[[compositions.params]]
name = "file"
type = "string"
description = "File to read."

[[compositions.exports]]
name = "path"
node = "read"
pointer = "/path"

[[compositions.nodes]]
id = "read"
tool = "Read"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "file_path"
[compositions.nodes.input.fields.value]
kind = "param"
name = "file"
|}

let test_export_contract_survives_public_authoring_and_binding () =
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let catalog = match Catalog.parse ~descriptors export_catalog_fixture with
    | Ok catalog -> catalog | Error error -> fail (Catalog.error_to_string error) in
  let entry = match Catalog.entries catalog with
    | [ entry ] -> entry | _ -> fail "expected one composition" in
  let plan = match Catalog.instantiate ~descriptors ~args:(`Assoc [ "file", `String "probe.txt" ]) entry with
    | Ok plan -> plan | Error error -> fail (Catalog.instantiation_error_to_string error) in
  check bool "binding retains failure policy" true (Plan.branch_failure_policy plan = Plan.Continue_independent);
  check int "binding retains exports" 1 (List.length (Plan.exports plan));
  let encoded = match Masc.Keeper_tool_plan_request.to_yojson plan with
    | Ok json -> json | Error _ -> fail "bound plan was not serializable" in
  let decoded = match Masc.Keeper_tool_plan_request.plan_of_json ~descriptors encoded with
    | Ok plan -> plan | Error error -> fail (Masc.Keeper_tool_plan_request.error_message error) in
  check bool "durable recipe retains failure policy" true (Plan.branch_failure_policy decoded = Plan.Continue_independent);
  check int "durable recipe retains selected fields" 1 (List.length (Plan.exports decoded));
  let invalid = match encoded with
    | `Assoc fields -> `Assoc (("exports", `List [ `Assoc [ "name", `String "missing"; "node", `String "read"; "pointer", `String "/undeclared" ] ]) :: List.remove_assoc "exports" fields)
    | _ -> fail "encoded plan is not an object" in
  match Masc.Keeper_tool_plan_request.plan_of_json ~descriptors invalid with
  | Error (Masc.Keeper_tool_plan_request.Plan_rejected (Plan.Invalid_export_pointer _)) -> ()
  | Error _ | Ok _ -> fail "invalid export survived public plan admission"
;;

module Draft = Masc.Keeper_composition_draft

let draft_surface ?(tool_deny = []) () =
  let snapshot = Skill_catalog_snapshot.config_unreadable ~detail:"draft test has no shared Skill source" in
  Masc.Keeper_capability_surface.create ~tool_deny
    ~sandbox_profile:Masc.Keeper_types_profile.Docker ~skill_names:None
    ~global_skill_catalog:Masc.Keeper_skill_catalog.empty
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot snapshot) ~task_skills:[]
;;

let with_draft_base f =
  let base_path = Filename.temp_file "masc-composition-draft-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> f base_path)
;;

let draft_request = `Assoc
  [ "nodes", `List [ `Assoc [ "id", `String "lane"; "tool", `String "keeper_lane_status";"args",`Assoc [] ] ]
  ; "exports", `List [ `Assoc [ "name", `String "profile"; "node", `String "lane"; "pointer", `String "/profile" ] ] ]
;;

let test_draft_prepare_and_exact_run_binding () =
  Eio_main.run @@ fun _env ->
  with_draft_base @@ fun base_path ->
  let capability_surface = draft_surface () in
  let draft = match Draft.prepare ~base_path ~capability_surface ~keeper_name:"fixture"
      ~execution:Catalog.Async draft_request with
    | Ok draft -> draft | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error)) in
  let reference = Draft.reference draft in
  let loaded = match Draft.load ~base_path ~capability_surface ~keeper_name:"fixture" ~sha256:reference.sha256 with
    | Ok draft -> draft | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error)) in
  check bool "preview mode is execution mode" true (Draft.execution loaded = Catalog.Async);
  check int "exact exports retained" 1 (List.length (Plan.exports (Draft.plan loaded)));
  (match Draft.load ~base_path ~capability_surface ~keeper_name:"another" ~sha256:reference.sha256 with
   | Error Draft.Different_keeper -> () | Error _ | Ok _ -> fail "draft crossed Keeper ownership");
  let changed = draft_surface ~tool_deny:[ "keeper_tasks_list" ] () in
  (match Draft.load ~base_path ~capability_surface:changed ~keeper_name:"fixture" ~sha256:reference.sha256 with
   | Error Draft.Capability_changed -> () | Error _ | Ok _ -> fail "draft was silently rebound to a changed surface");
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"draft-run-fixture"
      ~turn:7 ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Agent_core.Tool_contract.Serial }
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let run = match Draft.record_invocation ~base_path ~composition_run_id:(Plan.Composition_run_id.fresh ()) ~invocation loaded with
    | Ok reference -> reference | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error)) in
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:run.sha256 with
  | Ok (Some raw) ->
    (match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string raw) with
     | Tool_output.Decoded_artifact_manifest { structured_content; _ } ->
       check string "source invocation durably bound before execution" "draft-run-fixture"
         Yojson.Safe.Util.(structured_content |> member "tool_use_id" |> to_string)
     | Tool_output.Not_artifact_manifest -> fail "run binding is not a canonical manifest"
     | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
  | Ok None | Error _ -> fail "pre-dispatch run binding is not durable"
;;

let draft_single_node_request ?input tool =
  let literal value = [ "input", `Assoc [ "kind", `String "literal"; "value", value ] ] in
  `Assoc [ "nodes", `List [ `Assoc ([ "id", `String "n"; "tool", `String tool ]
    @ Option.fold ~none:[] ~some:literal input) ] ]
;;

let draft_write_input = `Assoc [ "file_path", `String "a.txt"; "content", `String "x" ]

(* #43445: an inline draft may mutate an owned file, so Write is admitted at the
   leaf and only its inputs are checked. The refusal test below keeps the
   effects that stay refused. *)
let test_draft_admits_inline_owned_file_write () =
  Eio_main.run @@ fun _env ->
  with_draft_base @@ fun base_path ->
  let capability_surface = draft_surface () in
  let prepare json = Draft.prepare ~base_path ~capability_surface ~keeper_name:"fixture" ~execution:Catalog.Inline json in
  (match prepare (draft_single_node_request "Write") with
   | Error (Draft.Inputs_rejected _) -> ()
   | Error _ | Ok _ -> fail "inline Write without inputs was not rejected for its inputs");
  match prepare (draft_single_node_request ~input:draft_write_input "Write") with
  | Ok _ -> ()
  | Error error -> fail (Yojson.Safe.to_string (Draft.error_to_json error))
;;

let test_draft_rejects_effects_and_bad_fixed_inputs () =
  Eio_main.run @@ fun _env ->
  with_draft_base @@ fun base_path ->
  let capability_surface = draft_surface () in
  let prepare ?(execution = Catalog.Inline) json = Draft.prepare ~base_path ~capability_surface ~keeper_name:"fixture" ~execution json in
  (match prepare ~execution:Catalog.Async (draft_single_node_request ~input:draft_write_input "Write") with
   | Error (Draft.Unsupported_node { tool_name = "Write"; _ }) -> ()
   | Error _ | Ok _ -> fail "async draft admitted an owned file mutation");
  (match prepare (draft_single_node_request ~input:(`Assoc [ "command", `String "true" ]) "Execute") with
   | Error (Draft.Unsupported_node { tool_name = "Execute"; _ }) -> ()
   | Error _ | Ok _ -> fail "transient draft admitted an effectful node");
  let invalid_read = `Assoc [ "nodes", `List [ `Assoc [ "id", `String "read"; "tool", `String "Read"
      ; "input", `Assoc [ "kind", `String "literal"; "value", `Assoc [ "file_path", `Int 3 ] ] ] ] ] in
  match prepare invalid_read with
  | Error (Draft.Inputs_rejected _ as error) ->
    let open Yojson.Safe.Util in
    let projected = Draft.error_to_json error in
    check string "fixed input rejection keeps its public error kind" "inputs_rejected"
      (projected |> member "kind" |> to_string);
    check string "fixed input rejection identifies its node" "read"
      (projected |> member "node_id" |> to_string);
    check string "fixed input rejection keeps canonical validation detail" "input_validation_failed"
      (projected |> member "error" |> member "kind" |> to_string)
  | Error _ | Ok _ -> fail "invalid fixed input survived prepare"
;;

let test_public_draft_run_preserves_one_execution_identity ?(observe = true) ?(single_call=false) () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_draft_base @@ fun base_path ->
  let module Surface = Masc.Keeper_tool_composition_surface in
  let module Call_log = Masc.Keeper_tool_call_log in
  let module T = Agent_core.Types in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "fixture"; "activation_mode", `String "manual" ])
    |> Result.get_ok in
  let capability_surface = draft_surface () in
  let ctx_snapshot = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"draft identity fixture" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    { provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider
    ; keeper_name = meta.name } in
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  Call_log.init ~base_path ();
  let turn_ctx_cell = if observe then Some (Call_log.create_turn_ctx_cell ()) else None in
  Option.iter (fun cell -> Call_log.set_turn_context ~cell ~agent_name:meta.name
    ~turn:7 ~keeper_turn_id:1 ()) turn_ctx_cell;
  let tools = Surface.make_tools ~capability_surface ~config ~meta ~publication_recovery
      ~ctx_snapshot ?turn_ctx_cell () in
  let find name =
    match List.find_opt (fun (tool, _, _) ->
      String.equal tool.Agent_core.Tool.schema.name name) tools with
    | Some (tool, _, _) -> tool | None -> failf "public draft control missing: %s" name in
  let invoke id name input =
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:id ~turn:7
        ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1
                  ; execution_mode = Agent_core.Tool_contract.Serial }
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    let output = match Agent_core.Tool.execute ~invocation (find name) input with
      | Ok output -> output | Error error -> fail error.Agent_core.Types.message in
    let message : T.message =
      { role = T.Tool
      ; content = [ T.ToolResult { tool_use_id = id; content = output.content
                                ; outcome = T.Tool_succeeded; json = None; content_blocks = None } ]
      ; name = None; tool_call_id = Some id; metadata = [] } in
    let content = match Llm_provider.Backend_openai_serialize.openai_messages_of_message message with
      | [ wire ] -> Yojson.Safe.Util.(wire |> member "content" |> to_string)
      | _ -> fail "provider did not serialize one public draft result" in
    check string "provider carries exact public tool result" output.content content;
    check bool "small draft result is immediately readable" false (Tool_output.is_marker content);
    let envelope = Yojson.Safe.from_string content in
    check bool "readable provider result retains its manifest root" true
      Yojson.Safe.Util.(envelope |> member "artifact_manifest" <> `Null);
    Yojson.Safe.Util.(envelope |> member "structured_content") in
  let decode_reference value = match Tool_output.normalized_artifact_ref_of_json value with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
      fail "public control lost its normalized reference" in
  let document reference =
    match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.Tool_output.sha256 with
    | Ok (Some raw) ->
      (match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string raw) with
       | Tool_output.Decoded_artifact_manifest { structured_content; _ } -> structured_content
       | Tool_output.Not_artifact_manifest -> fail "public draft artifact is not a canonical manifest"
       | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
    | Ok None -> fail "advertised public draft artifact is absent"
    | Error error -> fail (Tool_blob_store.fetch_error_to_string error) in
  let prepared = invoke "prepare-fixture" Draft.prepare_tool_name
      (match draft_request with
       | `Assoc fields -> `Assoc (("execution", `String "inline") :: fields)
       | _ -> fail "fixture plan is not an object") in
  let open Yojson.Safe.Util in
  let preview_node = match prepared |> member "schedule_preview" |> to_list with
    | [ `List [ node ] ] -> node
    | _ -> fail "public prepare lost its single-node schedule preview" in
  check string "public preview keeps the admitted node" "lane"
    (preview_node |> member "node_id" |> to_string);
  let preview_schedule = preview_node |> member "schedule" in
  check int "public preview keeps the canonical planned index" 0
    (preview_schedule |> member "planned_index" |> to_int);
  check int "public preview keeps the canonical batch index" 0
    (preview_schedule |> member "batch_index" |> to_int);
  check int "public preview keeps the descriptor batch size" 1
    (preview_schedule |> member "batch_size" |> to_int);
  check string "public preview keeps concurrent descriptor execution" "concurrent"
    (preview_schedule |> member "execution_mode" |> to_string);
  let draft_reference = prepared |> member "draft" |> decode_reference in
  let run_parent = "public-draft-run" in
  let result = invoke run_parent Draft.run_tool_name
      (if single_call then `Assoc ["recipe",(match draft_request with
         | `Assoc fields -> `Assoc (("execution",`String "inline") :: fields)
         | _ -> fail "fixture plan object")]
       else `Assoc [ "sha256", `String draft_reference.sha256 ]) in
  let run_reference = result |> member "run_artifact" |> decode_reference in
  let binding = document run_reference in
  let run_id = binding |> member "composition_run_id" |> to_string in
  check string "result names the persisted pre-dispatch run" run_id
    (result |> member "composition_run_id" |> to_string);
  check string "pre-dispatch binding names the original public invocation" run_parent
    (binding |> member "tool_use_id" |> to_string);
  check string "run binds the exact prepared draft" draft_reference.sha256
    (binding |> member "draft" |> decode_reference).sha256;
  check bool "public run exposes its selected profile" true
    (result |> member "exports" |> member "profile" |> member "available" |> to_bool);
  let execution_reference = result |> member "execution_artifact" |> decode_reference in
  let raw_execution = document execution_reference in
  let leaf = match raw_execution |> member "nodes" |> to_list with
    | [ leaf ] -> leaf | _ -> fail "public run did not execute its single leaf" in
  let expected_leaf_id = Printf.sprintf "composition:%d:%s:%d:%s:4:lane"
      (String.length run_id) run_id (String.length run_parent) run_parent in
  check string "actual leaf invocation belongs to the pre-dispatch run" expected_leaf_id
    (leaf |> member "tool_use_id" |> to_string);
  Call_log.flush_now ();
  let rows = Call_log.read_recent ~keeper_name:meta.name () |> Result.get_ok in
  let row name = match List.find_opt (fun row -> member "tool" row = `String name) rows with
    | Some row -> row | None -> failf "missing actual composition observation: %s" name in
  if observe then (
    let observed_leaf = row "keeper_lane_status" in
    check string "observer preserves the actual leaf invocation" expected_leaf_id
      (observed_leaf |> member "tool_use_id" |> to_string);
    check string "leaf observation names the same durable run" run_id
      (observed_leaf |> member "composition_run_id" |> to_string));
  check string "run summary names the same durable run" run_id
    (row Surface.composition_run_summary_tool_name |> member "composition_run_id" |> to_string)
;;

let test_read_only_outer_invocations_overlap_without_identity_mixing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_draft_base @@ fun base_path ->
  let module Surface = Masc.Keeper_tool_composition_surface in
  let module Call_log = Masc.Keeper_tool_call_log in
  let module Recorder = Masc.Keeper_skill_activation_recorder in
  let module Ledger = Masc.Keeper_skill_activation_ledger in
  let module Causal = Masc.Keeper_gate_causal_context in
  let config = Masc.Workspace.default_config base_path in
  (* Sandbox configuration is TOML-owned, outside the runtime JSON codec. *)
  let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "overlap"; "activation_mode", `String "manual" ]) with
    | Ok meta ->
      { meta with Masc.Keeper_meta_contract.sandbox_profile = Masc.Keeper_types_profile.Docker
                ; sandbox_image = Some "base" }
    | Error detail -> failf "overlap fixture Keeper meta decode failed: %s" detail in
  let image_reference = "composition-overlap:test" in
  Masc_test_deps.write_sandbox_image_catalog ~base_path [ "base", image_reference ];
  let read_root = Masc.Keeper_tool_shared_runtime.keeper_playground_root ~config ~meta in
  (* The public composition and Read authority remain real. Only the Docker
     transport is synthetic: it runs Read's command on the same fixture
     bytes after applying the sandbox mount translation. This proves causal
     overlap and identities, not execution inside a real Docker container. *)
  let docker_path = Filename.concat base_path "read-docker-fixture" in
  let script = Printf.sprintf {|#!/bin/sh
case "$1" in
  info|image) printf '[]\n'; exit 0;;
  run)
    shift
    while [ "$#" -gt 0 ] && [ "$1" != %s ]; do shift; done
    [ "$#" -gt 0 ] || exit 2
    shift
    [ "$#" -eq 7 ] && [ "$1" = sh ] && [ "$2" = -c ] && [ "$4" = sh ] || exit 2
    fixture_root=%s
    fixture_container_root=%s
    case "$6" in
      "$fixture_container_root"/*)
        fixture_path="$fixture_root/${6#"$fixture_container_root"/}"
        exec "$1" "$2" "$3" "$4" "$5" "$fixture_path" "$7";;
      *) exit 2;;
    esac;;
  *) exit 2;;
esac
|} (Filename.quote image_reference) (Filename.quote read_root)
      (Filename.quote (Masc.Keeper_sandbox.container_root meta.name)) in
  Out_channel.with_open_bin docker_path (fun channel -> output_string channel script);
  Unix.chmod docker_path 0o700;
  let fake_docker_key = "MASC_TEST_FAKE_DOCKER_PATH" in
  let prior_fake_docker = Env_config_core.raw_value_opt fake_docker_key in
  Unix.putenv fake_docker_key docker_path;
  Fun.protect ~finally:(fun () ->
    Unix.putenv fake_docker_key (Option.value ~default:"" prior_fake_docker)) @@ fun () ->
  let catalog = Catalog.parse export_catalog_fixture |> Result.get_ok in
  let entry = match Catalog.entries catalog with
    | [ entry ] -> entry | _ -> fail "expected the read composition" in
  let source_id = Skill_source_config.source_id_of_string "workspace" |> Result.get_ok in
  let package_id = Skill_reference.package_id_of_directory "read-path" |> Result.get_ok in
  let reference = Skill_reference.make
      ~identity:(Skill_reference.make_identity ~source_id ~package_id ~name:"read-path")
      ~content_revision:(Skill_reference.content_revision_of_string (String.make 64 'a') |> Result.get_ok) in
  let trace_id = meta.runtime.trace_id in
  ignore (Masc.Keeper_fs.ensure_dir
    (Masc.Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id)));
  let activation_context = Recorder.make ~trace_id
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string trace_id) ~absolute_turn:1)
      ~runtime_id:(fun () -> Some "overlap.runtime")
      ~snapshot_revision:(Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'f') |> Result.get_ok)
      ~task_selection:Masc.Keeper_task_skill_turn.empty |> Result.get_ok in
  let ctx_snapshot = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"outer overlap fixture" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    { provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider
    ; keeper_name = meta.name } in
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  Call_log.init ~base_path ();
  let turn_ctx_cell = Call_log.create_turn_ctx_cell () in
  Call_log.set_turn_context ~cell:turn_ctx_cell ~agent_name:meta.name ~turn:7 ~keeper_turn_id:1 ();
  let causal = Causal.create ~turn_id:(Some 1) ~origin:Keeper_approval_origin.unavailable ~initial:(`Assoc []) in
  let both_read, release = Eio.Promise.create () in
  let arrivals = Atomic.make 0 in
  let record_gate_result ~operation ~input result =
    Causal.record_tool_result causal ~operation ~input result;
    if Atomic.fetch_and_add arrivals 1 = 1 then Eio.Promise.resolve release ();
    (* The first real leaf has returned, but its outer invocation cannot
       finish until the second invocation has dispatched its own leaf. *)
    Eio.Promise.await both_read in
  let tools = Surface.make_tools ~capability_surface:(draft_surface ())
      ~skill_compositions:[ Surface.{ reference; entry } ] ~config ~meta ~publication_recovery
      ~ctx_snapshot ~turn_ctx_cell ~gate_causal_context:causal
      ~gate_context:(fun () -> Causal.snapshot causal) ~record_gate_result
      ~record_composition_activation:(fun ~invocation ~tool_name ~reference ->
        Recorder.record_composition ~config activation_context ~invocation ~tool_name reference) () in
  let tool = match List.find_opt (fun (tool, _, _) ->
      String.equal tool.Agent_core.Tool.schema.name (Catalog.tool_name entry)) tools with
    | Some (tool, _, _) -> tool | None -> fail "read composition not materialized" in
  check bool "read-only outer contract permits overlap" true
    (Agent_core.Tool.execution_mode tool ~input:(`Assoc []) = Agent_core.Tool_contract.Concurrent);
  let callback_only = Surface.make_tools ~capability_surface:(draft_surface ())
      ~skill_compositions:[ Surface.{ reference; entry } ] ~config ~meta ~publication_recovery
      ~ctx_snapshot ~gate_context:(fun () -> Causal.snapshot causal) () in
  let callback_only_tool = match List.find_opt (fun (tool, _, _) ->
      String.equal tool.Agent_core.Tool.schema.name (Catalog.tool_name entry)) callback_only with
    | Some (tool, _, _) -> tool | None -> fail "callback-only composition not materialized" in
  check bool "a mutable callback without its causal cell stays serial" true
    (Agent_core.Tool.execution_mode callback_only_tool ~input:(`Assoc []) = Agent_core.Tool_contract.Serial);
  let files = [ "left", "left evidence"; "right", "right evidence" ] in
  List.iter (fun (file, content) ->
    let channel = open_out (Filename.concat read_root file) in
    Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel content)) files;
  let run index file =
    let id = "outer-" ^ file in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:id ~turn:7
        ~schedule:{ planned_index = index; batch_index = 0; batch_size = 2
                  ; execution_mode = Agent_core.Tool_contract.Concurrent }
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    let output = match Agent_core.Tool.execute ~invocation tool
        (`Assoc [ "file", `String (Filename.concat read_root file) ]) with
      | Ok output -> output | Error error -> fail error.Agent_core.Types.message in
    let open Yojson.Safe.Util in
    let selected = Yojson.Safe.from_string output.content |> member "structured_content"
        |> member "exports" |> member "path" in
    check bool (file ^ " selected result available") true (selected |> member "available" |> to_bool);
    check string (file ^ " receives its own path") (Filename.concat read_root file)
      (selected |> member "value" |> to_string)
  in
  Eio.Fiber.both (fun () -> run 0 "left") (fun () -> run 1 "right");
  Printf.printf "composition_outer_trial invocations=2 dispatches=%d overlap_proven_by_barrier=true container_transport=fixture model_latency_measured=false\n%!"
    (Atomic.get arrivals);
  check int "two actual leaf dispatches overlapped" 2 (Atomic.get arrivals);
  let open Yojson.Safe.Util in
  check int "owning turn retains both completions" 2
    ((Causal.snapshot causal).snapshot |> member "completed_tool_calls" |> to_list |> List.length);
  let ledger = Ledger.load ~config ~trace_id |> Result.get_ok in
  check (list string) "durable activations keep separate outer identities" [ "outer-left"; "outer-right" ]
    (Ledger.activations ledger |> List.map (fun activation ->
      Ledger.activation_to_yojson activation |> member "skill_tool_use_id" |> to_string) |> List.sort String.compare);
  Call_log.flush_now ();
  let rows = Call_log.read_recent ~keeper_name:meta.name () |> Result.get_ok in
  let summaries = List.filter (fun row -> member "tool" row = `String Surface.composition_run_summary_tool_name) rows in
  check int "each overlapping invocation has one run summary" 2 (List.length summaries);
  let run_ids = List.map (fun row -> row |> member "composition_run_id" |> to_string) summaries in
  check int "overlapping invocations have distinct run identities" 2 (List.sort_uniq String.compare run_ids |> List.length);
  List.iter (fun summary ->
    let run_id = summary |> member "composition_run_id" |> to_string in
    let parent = summary |> member "tool_use_id" |> to_string in
    let leaf = List.filter (fun row -> member "composition_run_id" row = `String run_id
        && member "tool" row <> `String Surface.composition_run_summary_tool_name) rows in
    match leaf with
    | [ row ] -> check string "leaf observation keeps its own outer parent" parent
        (row |> member "parent_tool_use_id" |> to_string)
    | _ -> fail "overlapping run mixed or lost its leaf observations") summaries
;;

let test_causal_forks_keep_invocation_owned_history () =
  let module Causal = Masc.Keeper_gate_causal_context in
  let parent = Causal.create ~turn_id:(Some 1) ~origin:Keeper_approval_origin.unavailable ~initial:(`Assoc []) in
  let record cell operation = Causal.record_tool_result cell ~operation ~input:(`Assoc [])
      (Tool_result.make_ok ~tool_name:operation ~start_time:(Tool_timing.start ()) ()) in
  record parent "prior";
  let left = Causal.fork parent in
  let right = Causal.fork parent in
  record left "left";
  record right "right";
  record parent "later";
  let operations cell = let open Yojson.Safe.Util in
    (Causal.snapshot cell).snapshot |> member "completed_tool_calls" |> to_list
    |> List.map (fun call -> call |> member "operation" |> to_string) in
  check (list string) "left has its own causal continuation" [ "prior"; "left" ] (operations left);
  check (list string) "right has its own causal continuation" [ "prior"; "right" ] (operations right);
  check (list string) "parent retains its own continuation" [ "prior"; "later" ] (operations parent)
;;

(* A provider that refuses recursive JSON Schemas rejects the whole request,
   not only a call to the tool that carries one (Muse: 400 "Recursive JSON
   schemas ..."). The advertised prepare schema therefore holds no [$ref] and no
   [$defs] at any depth; the grammar is still checked by [plan_of_json]. *)
let test_prepare_schema_has_no_recursive_references () =
  let rec has_reference_keyword = function
    | `Assoc fields ->
      List.exists
        (fun (key, value) ->
           String.equal key "$ref" || String.equal key "$defs" || has_reference_keyword value)
        fields
    | `List items -> List.exists has_reference_keyword items
    | _ -> false
  in
  let schema = Draft.prepare_schema.Masc_domain.input_schema in
  Alcotest.(check bool)
    "no $ref or $defs in the advertised prepare schema"
    false
    (has_reference_keyword schema);
  let member key = function
    | `Assoc fields -> List.assoc_opt key fields
    | _ -> None
  in
  (* Node fields are defined once on the shared node object; each [oneOf] row
     only names the fields it requires and forbids (#43452). *)
  let items =
    Option.bind (member "properties" schema) (member "nodes")
    |> fun nodes -> Option.bind nodes (member "items")
    |> function
    | Some items -> items
    | None -> Alcotest.fail "prepare schema has no node items"
  in
  let shared_properties =
    match member "properties" items with
    | Some properties -> properties
    | None -> Alcotest.fail "prepare schema node items have no shared properties"
  in
  List.iter (fun field ->
    let field_type = Option.bind (member field shared_properties) (member "type") in
    Alcotest.(check (option string))
      (Printf.sprintf "node field %s advertises an object" field)
      (Some "object")
      (match field_type with
       | Some (`String type_name) -> Some type_name
       | _ -> None)) [ "input"; "args" ];
  let alternatives =
    match member "oneOf" items with
    | Some (`List (_ :: _ as alternatives)) -> alternatives
    | _ -> Alcotest.fail "prepare schema has no node alternatives"
  in
  List.iteri (fun index alternative ->
    match member "required" alternative with
    | Some (`List (_ :: _)) -> ()
    | _ -> Alcotest.failf "node alternative %d does not name its required fields" index)
    alternatives
;;

(* A provider that refuses recursive JSON Schemas rejects the whole request,
   not only a call to a tool that carries one (Muse: 400 "Recursive JSON
   schemas ..."), so the schemas a request advertises must hold no [$ref] and
   no [$defs] at any depth. This sweep over-approximates that wire set:
   [all_descriptors ()] unions public and private descriptors — a superset of
   what one provider request carries — and the prepare/run projections ride
   along (#43150 follow-up, task-2359). *)
let test_every_advertised_schema_holds_no_recursive_references () =
  let rec has_reference_keyword = function
    | `Assoc fields ->
      List.exists
        (fun (key, value) ->
           String.equal key "$ref" || String.equal key "$defs"
           || has_reference_keyword value)
        fields
    | `List items -> List.exists has_reference_keyword items
    | _ -> false
  in
  let offenders =
    Masc.Keeper_tool_descriptor.all_descriptors ()
    |> List.filter (fun ({ input_schema; _ } : Masc.Keeper_tool_descriptor.t) ->
           has_reference_keyword input_schema)
    |> List.map (fun ({ id; public_name; _ } : Masc.Keeper_tool_descriptor.t) ->
           Printf.sprintf "%s (%s)" id public_name)
  in
  Alcotest.(check (list string))
    "no advertised descriptor schema carries a $ref or $defs at any depth"
    [] offenders;
  List.iter
    (fun (name, schema) ->
       Alcotest.(check bool)
         (Printf.sprintf "composition projection %s holds no $ref or $defs" name)
         false
         (has_reference_keyword schema))
    [ Draft.prepare_tool_name, Draft.prepare_schema.Masc_domain.input_schema
    ; Draft.run_tool_name, Draft.run_schema.Masc_domain.input_schema ];
  (* Positive control: the detector must flag a deliberately recursive
     fixture, so an empty offender list can only mean a clean catalog. *)
  let recursive_fixture =
    `Assoc
      [ "type", `String "object"
      ; "$defs", `Assoc [ "template", `Assoc [ "type", `String "object" ] ]
      ; "properties", `Assoc
          [ "value", `Assoc [ "$ref", `String "#/$defs/template" ] ] ]
  in
  Alcotest.(check bool)
    "positive control: the detector flags a deliberately recursive schema"
    true
    (has_reference_keyword recursive_fixture)
;;

let test_without_recursive_refs_matches_ref_string_not_key_order () =
  (* Generator output that attaches sibling keywords (description, title) in
     either key order alongside [$ref = "#/$defs/template"] must still be
     replaced by the non-recursive placeholder, while unrelated fields and
     non-template refs remain intact. *)
  let schema = `Assoc
    [ "$defs", `Assoc [ "template", `String "recursive" ]
    ; "properties", `Assoc
        [ "value", `Assoc
            [ "description", `String "nested template before $ref"
            ; "$ref", `String "#/$defs/template"
            ]
        ; "second", `Assoc
            [ "$ref", `String "#/$defs/template"
            ; "title", `String "nested template after $ref"
            ]
        ; "other_ref", `Assoc [ "$ref", `String "#/$defs/other" ]
        ; "label", `String "plain string, not a ref" ]
    ; "required", `List [ `String "value" ] ] in
  let projected = Masc.Keeper_composition_draft.without_recursive_refs schema in
  let member key = function
    | `Assoc fields -> List.assoc_opt key fields
    | _ -> None in
  let check_placeholder name = function
    | Some (`Assoc inner) ->
      Alcotest.(check (option string))
        (name ^ " $ref removed")
        None
        (match List.assoc_opt "$ref" inner with
         | Some (`String s) -> Some s
         | _ -> None);
      Alcotest.(check (option string))
        (name ^ " replaced by object placeholder")
        (Some "object")
        (match List.assoc_opt "type" inner with
         | Some (`String s) -> Some s
         | _ -> None)
    | _ -> Alcotest.fail (name ^ " is not an object")
  in
  Alcotest.(check bool)
    "$defs dropped from the projected schema"
    true
    (match member "$defs" projected with None -> true | Some _ -> false);
  (match member "properties" projected with
   | Some (`Assoc fields) ->
     check_placeholder "value" (List.assoc_opt "value" fields);
     check_placeholder "second" (List.assoc_opt "second" fields);
     Alcotest.(check (option string))
       "non-template $ref preserved"
       (Some "#/$defs/other")
       (match List.assoc_opt "other_ref" fields with
        | Some (`Assoc inner) ->
          (match List.assoc_opt "$ref" inner with
           | Some (`String s) -> Some s
           | _ -> None)
        | _ -> None);
     Alcotest.(check (option string))
       "plain label field preserved"
       (Some "plain string, not a ref")
       (match List.assoc_opt "label" fields with
        | Some (`String s) -> Some s
        | _ -> None)
   | _ -> Alcotest.fail "projected schema has no properties")
;;

let test_frozen_plan_json_preserves_values_and_rejects_mixed_forms () =
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  (* Compile fidelity, not an assertion that these fixture values are valid
     inputs for a runtime call. Input preflight remains a separate boundary. *)
  let request = `Assoc
    [ "nodes", `List [ `Assoc [ "id", `String "lane"; "tool", `String "keeper_lane_status"
        ; "args", `Assoc
            [ "kind",`String "output";"node",`String "literal argument, not a dependency"
            ; "nullable", `Null; "mixed", `List [ `String "검사\n\"quoted\""; `Int 2; `Bool true ] ] ] ]
    ; "exports", `List [ `Assoc [ "name", `String "profile"; "node", `String "lane"; "pointer", `String "/profile" ] ]
    ; "branch_failure_policy", `String "continue_independent" ] in
  let plan = Masc.Keeper_tool_plan_request.plan_of_json ~descriptors request |> Result.get_ok in
  let canonical = Masc.Keeper_tool_plan_request.to_yojson plan |> Result.get_ok in
  let header = "[[compositions]]\nname = \"frozen\"\nexecution = \"inline\"\n" in
  let document = header ^ "plan_json = " ^ Yojson.Safe.to_string (`String (Yojson.Safe.to_string canonical)) ^ "\n" in
  let catalog = Catalog.parse ~descriptors document |> Result.get_ok in
  let restored = match Catalog.entries catalog with [ entry ] -> entry.plan | _ -> fail "one entry" in
  check bool "null, mixed arrays and escaped UTF-8 preserve exact JSON" true
    (Yojson.Safe.equal canonical (Masc.Keeper_tool_plan_request.to_yojson restored |> Result.get_ok));
  List.iter (fun (field, extra) -> match Catalog.parse ~descriptors (document ^ extra) with
    | Error (Catalog.Conflicting_plan_field { field = found; path }) ->
      check string "mixed form identifies its forbidden field" field found;
      check (list string) "mixed form identifies its composition" [ "compositions"; "0" ] path
    | Error error -> fail (Catalog.error_to_string error)
    | Ok _ -> fail "mixed plan accepted")
    [ "nodes", "nodes = []\n"; "params", "params = []\n"; "params", "params = \"invalid\"\n"
    ; "exports", "exports = []\n"; "branch_failure_policy", "branch_failure_policy = \"fail_fast\"\n" ];
  (match Catalog.parse ~descriptors (header ^ "params = []\n") with
   | Error (Catalog.Wrong_value_kind { field = "params"; expected = Catalog.Table_array_value; _ }) -> ()
   | Error error -> fail (Catalog.error_to_string error)
   | Ok _ -> fail "ordinary TOML parameter validation was bypassed");
  (match Catalog.parse ~descriptors (header ^ "plan_json = \"invalid\"\n") with
   | Error (Catalog.Plan_json_syntax _) -> () | _ -> fail "invalid encoded JSON accepted");
  (match Catalog.parse ~descriptors (header ^ "plan_json = \"{}\"\n") with
   | Error (Catalog.Plan_json_rejected _) -> () | _ -> fail "invalid structured plan accepted")
;;

let () =
  run
    "keeper_tool_composition_catalog"
    [ ( "catalog"
      , [ test_case "frozen JSON preserves values and rejects mixed forms" `Quick test_frozen_plan_json_preserves_values_and_rejects_mixed_forms
        ; test_case "draft prepare and exact run binding" `Quick test_draft_prepare_and_exact_run_binding
        ; test_case "read-only outer invocations overlap without identity mixing" `Quick
            test_read_only_outer_invocations_overlap_without_identity_mixing
        ; test_case "causal forks keep invocation-owned history" `Quick
            test_causal_forks_keep_invocation_owned_history
        ; test_case "public draft run keeps one execution identity and readable references" `Quick
            (test_public_draft_run_preserves_one_execution_identity ~observe:true)
        ; test_case "public draft run records its summary without optional turn context" `Quick
            (test_public_draft_run_preserves_one_execution_identity ~observe:false ~single_call:true)
        ; test_case "draft admits inline owned file write" `Quick test_draft_admits_inline_owned_file_write
        ; test_case "draft rejects effects and bad fixed inputs" `Quick test_draft_rejects_effects_and_bad_fixed_inputs
        ; test_case "export contract survives binding and durable encoding" `Quick test_export_contract_survives_public_authoring_and_binding
        ; test_case
            "builds executable typed plan"
            `Quick
            test_catalog_builds_executable_typed_plan
        ; test_case "rejects unknown fields" `Quick test_catalog_rejects_unknown_fields
        ; test_case "reads defer_loading" `Quick test_catalog_reads_defer_loading
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
            test_catalog_accepts_async_readonly_tools
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
            "an enum param projects its members and binds a member"
            `Quick
            test_enum_param_projects_members_and_binds
        ; test_case
            "enum param declarations are checked at load"
            `Quick
            test_enum_param_declaration_errors
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
        ; test_case
            "prepare schema advertises no recursive references"
            `Quick
            test_prepare_schema_has_no_recursive_references
        ; test_case
            "every advertised schema holds no recursive references"
            `Quick
            test_every_advertised_schema_holds_no_recursive_references
        ; test_case
            "without_recursive_refs matches the $ref string, not key order"
            `Quick
            test_without_recursive_refs_matches_ref_string_not_key_order
        ] )
    ]
;;
