module Plan = Keeper_tool_plan
module Catalog = Keeper_tool_composition_catalog
module Nested = Keeper_composition_nested

type authored_source =
  { package_id : Skill_reference.package_id
  ; source_text : string
  }

type t =
  { plan : Plan.t
  ; compiled : Nested.t
  ; execution : Catalog.execution_mode
  ; reference : Tool_output.artifact_ref
  ; authored_source : authored_source option
  }

type error =
  | Plan_rejected of Keeper_tool_plan_request.error
  | Inputs_rejected of Plan.Node_id.t * Plan.execution_error
  | Unsupported_node of { node_id : Plan.Node_id.t; tool_name : string }
  | Storage_failed of string
  | Draft_read_failed of Tool_blob_store.fetch_error
  | Draft_not_found
  | Malformed_draft of string
  | Different_keeper
  | Capability_changed
  | Publication_rejected of Keeper_skill_catalog.authored_source_error
  | Skill_not_prepared
  | Different_package
  | Nested_rejected of Nested.error
  | Nested_publication_requires_catalog

let prepare_tool_name = Catalog.prepare_tool_name
let run_tool_name = Catalog.run_tool_name
let ( let* ) = Result.bind

let plan draft = draft.plan
let nested_calls draft = Nested.calls draft.compiled
let execution draft = draft.execution
let reference draft = draft.reference
let authored_source draft = draft.authored_source

let failure_class = function
  | Draft_read_failed (Tool_blob_store.Invalid_sha256 _) -> Tool_result.Policy_rejection
  | Storage_failed _
  | Draft_read_failed
      ( Tool_blob_store.Owned_read_failed _
      | Tool_blob_store.Too_large _
      | Tool_blob_store.Invalid_max_bytes _
      | Tool_blob_store.Integrity_mismatch _ ) -> Tool_result.Runtime_failure
  | Plan_rejected _ | Inputs_rejected _ | Unsupported_node _ | Draft_not_found
  | Malformed_draft _ | Different_keeper | Capability_changed | Publication_rejected _
  | Skill_not_prepared | Different_package | Nested_rejected _
  | Nested_publication_requires_catalog -> Tool_result.Policy_rejection
;;

let error_to_json = function
  | Plan_rejected error -> Keeper_tool_plan_request.error_to_json error
  | Nested_rejected error -> Nested.error_to_json error
  | Nested_publication_requires_catalog -> `Assoc
      [ "kind", `String "nested_publication_requires_catalog"
      ; "detail", `String "Publishable nested recipes require the named catalog grammar; omitting child identities from published flattened plans is refused." ]
  | Inputs_rejected (node_id, error) ->
    `Assoc [ "kind", `String "inputs_rejected"
           ; "node_id", `String (Plan.Node_id.to_string node_id)
           ; "error", Keeper_tool_plan_error_projection.plan_execution_error_to_json error ]
  | Unsupported_node { node_id; tool_name } ->
    `Assoc [ "kind", `String "unsupported_node"
           ; "node_id", `String (Plan.Node_id.to_string node_id)
           ; "tool_name", `String tool_name
           ; "detail", `String "Prepared compositions admit static read-only ordinary tools, durable owned-job launch, and masc_ask; use the direct tool for other effects." ]
  | Storage_failed detail -> `Assoc [ "kind", `String "storage_failed"; "detail", `String detail ]
  | Draft_read_failed error -> `Assoc [ "kind", `String "draft_read_failed"; "detail", `String (Tool_blob_store.fetch_error_to_string error) ]
  | Draft_not_found -> `Assoc [ "kind", `String "draft_not_found" ]
  | Malformed_draft detail -> `Assoc [ "kind", `String "malformed_draft"; "detail", `String detail ]
  | Publication_rejected (Keeper_skill_catalog.Source_too_large { bytes; max_bytes }) ->
    `Assoc [ "kind", `String "source_too_large"; "bytes", `Int bytes; "max_bytes", `Int max_bytes ]
  | Publication_rejected (Keeper_skill_catalog.Invalid_document error) ->
    `Assoc [ "kind", `String (Keeper_skill_catalog.error_code error)
           ; "detail", `String (Keeper_skill_catalog.error_to_string error) ]
  | Skill_not_prepared -> `Assoc [ "kind", `String "skill_not_prepared" ]
  | Different_package -> `Assoc [ "kind", `String "different_package" ]
  | Different_keeper -> `Assoc [ "kind", `String "different_keeper" ]
  | Capability_changed -> `Assoc [ "kind", `String "capability_changed"; "detail", `String "Prepare again against the current frozen tool and Skill surface." ]
;;

(* The canonical plan grammar is a recursive JSON Schema: [$defs.template]
   holds a template whose object fields and array items are templates again.
   A provider that refuses recursive schemas rejects the whole request, not
   just a call to this tool (Muse: 400 "Recursive JSON schemas ..."). The tool
   advertises a non-recursive projection instead: [$defs] is dropped and each
   template position becomes an object that names the four tagged shapes.
   Nothing is enforced by that schema -- [Tool_input_validation] reads [oneOf]
   off the top level only, and [Keeper_tool_plan_request.plan_of_json] below
   remains the one validator of the template grammar. *)
let template_placeholder =
  `Assoc
    [ "type", `String "object"
    ; ( "description"
      , `String
          "Tagged input template, one of {kind:literal,value}, \
           {kind:output,node,pointer}, {kind:object,fields:[{name,value}]} or \
           {kind:array,items:[template]}; each value and each item is itself a \
           template." )
    ]
;;

let is_template_ref fields =
  match List.assoc_opt "$ref" fields with
  | Some (`String "#/$defs/template") -> true
  | Some _ | None -> false
;;

let rec without_recursive_refs = function
  | `Assoc fields when is_template_ref fields -> template_placeholder
  | `Assoc fields ->
    `Assoc
      (List.filter_map
         (fun (key, value) ->
            if String.equal key "$defs" then None else Some (key, without_recursive_refs value))
         fields)
  | `List items -> `List (List.map without_recursive_refs items)
  | other -> other
;;

let prepare_schema : Masc_domain.tool_schema =
  let input_schema =
    match Nested.input_schema |> without_recursive_refs with
    | `Assoc fields ->
      let properties = match List.assoc_opt "properties" fields with
        | Some (`Assoc properties) -> properties | _ -> invalid_arg "canonical plan schema has no properties" in
      let required = match List.assoc_opt "required" fields with
        | Some (`List required) -> required | _ -> invalid_arg "canonical plan schema has no required fields" in
      `Assoc (("properties", `Assoc
          (("execution", `Assoc [ "type", `String "string"; "enum", `List [ `String "inline"; `String "async" ] ])
           :: ("skill", (match Tool_schemas_composition_control.prepare_schema.input_schema with
               | `Assoc schema_fields -> (match List.assoc_opt "properties" schema_fields with
                   | Some (`Assoc schema_properties) -> List.assoc "skill" schema_properties
                   | _ -> invalid_arg "prepare schema has no properties")
               | _ -> invalid_arg "prepare schema is not an object")) :: properties))
        :: ("required", `List (`String "execution" :: required))
        :: List.remove_assoc "required" (List.remove_assoc "properties" fields))
    | _ -> invalid_arg "canonical plan request schema is not an object"
  in
  { Tool_schemas_composition_control.prepare_schema with input_schema }
;;

let run_schema : Masc_domain.tool_schema =
  let schema = Tool_schemas_composition_control.run_schema in
  let input_schema = match schema.input_schema with
    | `Assoc fields ->
      let properties = match List.assoc_opt "properties" fields with
        | Some (`Assoc properties) -> properties
        | _ -> invalid_arg "run schema has no properties" in
      `Assoc (("properties", `Assoc (("recipe", prepare_schema.input_schema)
        :: List.remove_assoc "recipe" properties)) :: List.remove_assoc "properties" fields)
    | _ -> invalid_arg "run schema is not an object" in
  { schema with input_schema }
;;

let map_nested_error result =
  result |> Result.map_error (function
    | Nested.Request_rejected error -> Plan_rejected error
    | Nested.Unsupported_leaf { node_id; tool_name } -> Unsupported_node { node_id; tool_name }
    | Nested.Inputs_rejected (node_id, error) -> Inputs_rejected (node_id, error)
    | ( Nested.Invalid_call_field _ | Nested.Invalid_reference _
      | Nested.Reference_unavailable _ | Nested.Instruction_reference _
      | Nested.Async_child_requires_suspension _ | Nested.Child_policy_mismatch _
      | Nested.Arguments_rejected _ | Nested.Binding_rejected _
      | Nested.Duplicate_alias _ | Nested.Unknown_alias _
      | Nested.Child_output_requires_export _ | Nested.Unknown_child_export _
      | Nested.Expanded_plan_rejected _ ) as error -> Nested_rejected error)
;;

let validate_plan ~execution ~capability_surface json =
  map_nested_error (Nested.compile ~execution ~capability_surface json)
;;

let encoding_error (Keeper_tool_plan_request.Unsubstituted_param {name}) =
  Malformed_draft ("unbound parameter " ^ name)

let node_contracts plan =
  Keeper_tool_plan_request.contracts_to_yojson plan |> Result.map_error encoding_error

let contracts ~capability_surface plan =
  let* tools = node_contracts plan in
  Ok (`Assoc [ "surface_digest", `String (Keeper_capability_surface.digest capability_surface)
            ; "tools", tools ])
;;

let put_document ~base_path json =
  let document = Tool_output.artifact_manifest_to_json ~content:"" ~structured_content:json in
  match Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
      ~bytes:(Yojson.Safe.to_string document) ~mime:Tool_output.artifact_manifest_mime with
  | reference -> Ok (Tool_output.with_preview reference "")
  | exception Sys_error detail -> Error (Storage_failed detail)
;;

let encode_plan plan =
  Keeper_tool_plan_request.to_yojson plan
  |> Result.map_error (fun (Keeper_tool_plan_request.Unsubstituted_param { name }) ->
      Malformed_draft ("unbound parameter " ^ name))
;;

let validate_authored ~capability_surface ~execution ~plan source =
  let* skill = Keeper_skill_catalog.validate_authored_source
      ~descriptors:(Keeper_capability_surface.descriptors capability_surface)
      ~directory:(Skill_reference.package_id_to_string source.package_id) source.source_text
      |> Result.map_error (fun error -> Publication_rejected error) in
  match skill.surface with
  | Keeper_skill_catalog.Instruction -> Error (Malformed_draft "draft Skill must be a composition")
  | Composition entry ->
    let* expected = encode_plan plan in
    let* actual = encode_plan entry.plan in
    if entry.execution = execution && entry.params = []
       && entry.description = Some skill.description
       && Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort actual)
    then Ok source
    else Error (Malformed_draft "Skill source differs from the frozen plan or metadata")
;;

let exact_fields ~names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error (Malformed_draft ("expected exactly " ^ String.concat ", " names))
;;

let package_id fields =
  match List.assoc_opt "package_id" fields with
  | Some (`String directory) -> Skill_reference.package_id_of_directory directory
      |> Result.map_error (fun error -> Malformed_draft (Skill_reference.package_id_error_to_string error))
  | _ -> Error (Malformed_draft "expected string package_id")
;;

let create_authored ~capability_surface ~execution ~plan json =
  let* fields = exact_fields ~names:[ "package_id"; "description" ] json in
  let* package_id = package_id fields in
  let* description = match List.assoc_opt "description" fields with
    | Some (`String value) -> Ok value | _ -> Error (Malformed_draft "expected string description") in
  let* canonical = encode_plan plan in
  let quote value = Yojson.Safe.to_string (`String value) in
  let name = Skill_reference.package_id_to_string package_id in
  let source_text = Printf.sprintf
      "---\nname: %s\ndescription: %s\n---\n\n```toml composition\n[[compositions]]\nname = %s\ndescription = %s\nexecution = %s\nplan_json = %s\n```\n"
      (quote name) (quote description) (quote name) (quote description)
      (quote (Catalog.execution_mode_to_string execution)) (quote (Yojson.Safe.to_string canonical)) in
  validate_authored ~capability_surface ~execution ~plan { package_id; source_text }
;;

let source_to_json source = `Assoc
  [ "package_id", `String (Skill_reference.package_id_to_string source.package_id)
  ; "source_text", `String source.source_text ]
;;

let prepare ~base_path ~capability_surface ~keeper_name ~execution json =
  let* plan_json, metadata = match json with
    | `Assoc fields -> Ok (`Assoc (List.remove_assoc "skill" fields), List.assoc_opt "skill" fields)
    | _ -> Ok (json, None) in
  let* compiled = validate_plan ~execution ~capability_surface plan_json in
  let plan = Nested.plan compiled in
  let* () = match Nested.calls compiled, execution, metadata with
    | [], _, _ | _ :: _, (Catalog.Inline | Catalog.Async), None -> Ok ()
    | _ :: _, (Catalog.Inline | Catalog.Async), Some _ -> Error Nested_publication_requires_catalog in
  let* canonical = encode_plan plan in
  let* authored_source = match metadata with
    | None -> Ok None
    | Some json -> create_authored ~capability_surface ~execution ~plan json |> Result.map Option.some in
  let* frozen_contracts = contracts ~capability_surface plan in
  let document = `Assoc
    [ "keeper", `String keeper_name
    ; "execution", `String (Catalog.execution_mode_to_string execution)
    ; "recipe", plan_json
    ; "plan", canonical
    ; "nested_calls", Nested.calls_to_json compiled
    ; "contracts", frozen_contracts
    ; "skill", (match authored_source with None -> `Null | Some source -> source_to_json source) ] in
  let* reference = put_document ~base_path document in
  Ok { plan; compiled; execution; reference; authored_source }
;;

let draft_fields = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length (List.sort_uniq String.compare names) <> List.length names then Error (Malformed_draft "duplicate field")
    else if List.sort String.compare names <> List.sort String.compare
      [ "keeper"; "execution"; "recipe"; "plan"; "nested_calls"; "contracts"; "skill" ] then
      Error (Malformed_draft "expected keeper, execution, recipe, plan, nested_calls, contracts and skill")
    else Ok fields
  | _ -> Error (Malformed_draft "expected object")
;;

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Malformed_draft ("expected string " ^ name))
;;

type admission_check = Exact_surface | Sealed_continuation

let load_with ~compile_plan ~admission_check ~base_path ~capability_surface ~keeper_name ~sha256 =
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256
      |> Result.map_error (fun error -> Draft_read_failed error) in
  let* bytes = match bytes with Some bytes -> Ok bytes | None -> Error Draft_not_found in
  let* json = match Yojson.Safe.from_string bytes with
    | json -> Ok json | exception Yojson.Json_error detail -> Error (Malformed_draft detail) in
  let* json = match Tool_output.artifact_manifest_of_json json with
    | Tool_output.Decoded_artifact_manifest { structured_content; _ } -> Ok structured_content
    | Tool_output.Not_artifact_manifest -> Error (Malformed_draft "expected canonical draft manifest")
    | Tool_output.Invalid_artifact_manifest { detail } -> Error (Malformed_draft detail) in
  let* fields = draft_fields json in
  let* owner = required_string fields "keeper" in
  let* () = if String.equal owner keeper_name then Ok () else Error Different_keeper in
  let* raw_execution = required_string fields "execution" in
  let* execution = match raw_execution with
    | "inline" -> Ok Catalog.Inline | "async" -> Ok Catalog.Async
    | _ -> Error (Malformed_draft "execution must be inline or async") in
  let* contract_fields = match List.assoc_opt "contracts" fields with
    | Some json -> exact_fields ~names:["surface_digest";"tools"] json
    | None -> Error Capability_changed in
  let* recorded_surface = required_string contract_fields "surface_digest" in
  let* () = match admission_check with
    | Exact_surface ->
      if String.equal recorded_surface (Keeper_capability_surface.digest capability_surface)
      then Ok () else Error Capability_changed
    | Sealed_continuation ->
      if String.length recorded_surface = 64
          && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) recorded_surface
      then Ok () else Error Capability_changed in
  let* compiled = match List.assoc_opt "recipe" fields with
    | Some json -> compile_plan ~execution ~capability_surface json
    | None -> Error (Malformed_draft "missing recipe") in
  let plan = Nested.plan compiled in
  let* canonical = encode_plan plan in
  let same left right = Yojson.Safe.equal (Yojson.Safe.sort left) (Yojson.Safe.sort right) in
  let* () = match List.assoc_opt "plan" fields, List.assoc_opt "nested_calls" fields with
    | Some recorded_plan, Some recorded_calls when same recorded_plan canonical
        && same recorded_calls (Nested.calls_to_json compiled) -> Ok ()
    | _ -> Error (Malformed_draft "recipe differs from frozen plan or child mappings") in
  let* () = match Nested.calls compiled, execution, List.assoc_opt "skill" fields with
    | [], _, _ | _ :: _, (Catalog.Inline | Catalog.Async), Some `Null -> Ok ()
    | _ :: _, (Catalog.Inline | Catalog.Async), _ -> Error Nested_publication_requires_catalog in
  let* current_contracts = node_contracts plan in
  let* () = match List.assoc_opt "tools" contract_fields with
    | Some recorded when same recorded current_contracts -> Ok ()
    | Some _ | None -> Error Capability_changed in
  let* authored_source = match List.assoc_opt "skill" fields with
    | Some `Null -> Ok None
    | Some json ->
      let* source_fields = exact_fields ~names:[ "package_id"; "source_text" ] json in
      let* package_id = package_id source_fields in
      let* source_text = required_string source_fields "source_text" in
      validate_authored ~capability_surface ~execution ~plan { package_id; source_text }
      |> Result.map Option.some
    | None -> Error (Malformed_draft "missing skill") in
  let* reference = Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
      ~preview:"" ~mime:Tool_output.artifact_manifest_mime
      |> Result.map_error (fun error -> Malformed_draft (Tool_output.make_error_to_string error)) in
  Ok { plan; compiled; execution; reference; authored_source }
;;

let load ~base_path ~capability_surface ~keeper_name ~sha256 =
  load_with ~compile_plan:validate_plan ~admission_check:Exact_surface ~base_path ~capability_surface ~keeper_name ~sha256
;;

let validate_request (schema : Masc_domain.tool_schema) input =
  let* () = match input with
    | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names = List.length (List.sort_uniq String.compare names) then Ok ()
      else Error (Malformed_draft "duplicate request field")
    | _ -> Ok () in
  match Tool_input_contract.check_arguments ~contract:Tool_input_contract.Host_tool ~schema:(Some schema.input_schema)
      ~name:schema.name ~args:input with
  | Ok _ -> Ok ()
  | Error rejected -> Error (Malformed_draft rejected.message)
;;

let prepare_request ~base_path ~capability_surface ~keeper_name input =
  let* () = validate_request prepare_schema input in
  match input with
  | `Assoc fields ->
    let* execution = match List.assoc_opt "execution" fields with
      | Some (`String "inline") -> Ok Catalog.Inline
      | Some (`String "async") -> Ok Catalog.Async
      | Some _ | None -> Error (Malformed_draft "execution must be inline or async") in
    prepare ~base_path ~capability_surface ~keeper_name ~execution
      (`Assoc (List.remove_assoc "execution" fields))
  | _ -> Error (Malformed_draft "expected prepare object")
;;

let resolve_run_request ~base_path ~capability_surface ~keeper_name input =
  let* () = validate_request run_schema input in
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "sha256" fields, List.assoc_opt "recipe" fields with
     | Some (`String sha256), None -> load ~base_path ~capability_surface ~keeper_name ~sha256
     | None, Some recipe -> prepare_request ~base_path ~capability_surface ~keeper_name recipe
     | Some _, Some _ | None, None | Some _, None ->
       Error (Malformed_draft "expected exactly one of draft sha256 or recipe"))
  | _ -> Error (Malformed_draft "expected run object")
;;

let load_continuation_with ~compile_plan ~base_path ~capability_surface continuation =
  let* canonical_base =
    try Ok (Fs_compat.realpath base_path) with
    | Sys_error detail -> Error (Storage_failed detail)
    | Unix.Unix_error (code, operation, path) ->
      Error (Storage_failed (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code))) in
  let* () = if String.equal canonical_base (Keeper_tool_execution_journal.continuation_base_path continuation)
    then Ok () else Error (Malformed_draft "continuation belongs to another workspace") in
  let source = Keeper_tool_execution_journal.continuation_source continuation in
  let* draft = load_with ~compile_plan ~admission_check:Sealed_continuation ~base_path ~capability_surface
      ~keeper_name:source.keeper_name ~sha256:source.draft_reference.sha256 in
  match draft.execution with
  | Catalog.Async -> Ok draft
  | Catalog.Inline -> Error (Malformed_draft "owned continuation requires an original async draft")
;;

let load_continuation ~base_path ~capability_surface continuation =
  load_continuation_with ~compile_plan:validate_plan ~base_path ~capability_surface continuation
;;

type continuation_refusal = Current_tool_denied of { node_id : Plan.Node_id.t; tool_name : string }
type continuation_admission = Admitted of t | Refused of t * continuation_refusal

let continuation_refusal_to_json = function
  | Current_tool_denied {node_id;tool_name} -> `Assoc
      ["kind",`String "current_tool_denied";"node_id",`String (Plan.Node_id.to_string node_id);
       "tool_name",`String tool_name]
;;

let load_continuation_admission ~base_path ~capability_surface continuation =
  match load_continuation ~base_path ~capability_surface continuation with
  | Ok draft -> Ok (Admitted draft)
  | Error original_error ->
    let compile_plan ~execution ~capability_surface json =
      map_nested_error (Nested.compile_for_refusal ~execution ~capability_surface json) in
    let* draft = load_continuation_with ~compile_plan ~base_path ~capability_surface continuation in
    let denied = Plan.nodes draft.plan |> List.find_map (fun (node : Plan.node) ->
      match Plan.descriptor draft.plan node.id with
      | None -> None
      | Some descriptor ->
        match Keeper_capability_surface.tool_row_availability capability_surface descriptor with
        | Some Denied_by_profile -> Some (Current_tool_denied {node_id=node.id;tool_name=node.tool_name})
        | None | Some (Active | Outside_skill_surface | Not_model_invocable | Refused_by_sandbox _
            | Node_tools_outside_surface _ | Invalid_definition | Missing_configured_skill) -> None) in
    (match denied with Some refusal -> Ok (Refused (draft,refusal)) | None -> Error original_error)
;;

let load_authored ~base_path ~capability_surface ~keeper_name ~package_id ~sha256 =
  let* draft = load ~base_path ~capability_surface ~keeper_name ~sha256 in
  match draft.authored_source with
  | None -> Error Skill_not_prepared
  | Some source when String.equal (Skill_reference.package_id_to_string package_id)
        (Skill_reference.package_id_to_string source.package_id) -> Ok source
  | Some _ -> Error Different_package
;;

let preview draft =
  let layers = Plan.dependency_layers draft.plan |> List.map (fun nodes ->
    `List (List.map (fun (node : Plan.node) -> `String (Plan.Node_id.to_string node.id)) nodes)) in
  let skill = match draft.authored_source with
    | None -> `Null
    | Some source -> `Assoc
        [ "package_id", `String (Skill_reference.package_id_to_string source.package_id)
        ; "source", `Assoc
            [ "sha256", `String Digestif.SHA256.(digest_string source.source_text |> to_hex)
            ; "bytes", `Int (String.length source.source_text); "filename", `String "SKILL.md" ] ] in
  `Assoc [ "draft", Tool_output.normalized_artifact_ref_to_json draft.reference
         ; "nested_calls", Nested.calls_to_json draft.compiled
         ; "skill", skill
         ; "execution", `String (Catalog.execution_mode_to_string draft.execution)
         ; "branch_failure_policy", `String (Plan.branch_failure_policy_to_string (Plan.branch_failure_policy draft.plan))
         ; "dependency_layers", `List layers
         ; "scheduling", `String "The executor dispatches ready nodes dynamically; these are dependency and descriptor groups, not fixed start times."
         ; "exports", `List (List.map (fun (export : Plan.export) ->
             `Assoc [ "name", `String export.name; "node", `String (Plan.Node_id.to_string export.node_id)
                    ; "pointer", `String (Plan.Json_pointer.to_string export.pointer) ]) (Plan.exports draft.plan)) ]
;;

let record_invocation ~base_path ?nested_activation ~composition_run_id ~invocation draft =
  put_document ~base_path (`Assoc
    [ "draft", Tool_output.normalized_artifact_ref_to_json draft.reference
    ; "nested_activation",(match nested_activation with None -> `Null | Some bound ->
        Keeper_skill_activation_recorder.bound_context_to_yojson bound)
    ; "nested_calls", Nested.calls_to_json draft.compiled
    ; "composition_run_id", `String (Plan.Composition_run_id.to_string composition_run_id)
    ; "tool_use_id", `String (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
    ; "source_turn", `Int (Agent_core.Tool_contract.Invocation.turn invocation) ])
;;

let load_nested_run_fields ~base_path (source : Keeper_tool_execution_journal.source) =
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:source.run_reference.sha256
    |> Result.map_error (fun error -> Draft_read_failed error) in
  let* bytes = match bytes with Some bytes -> Ok bytes | None -> Error Draft_not_found in
  let* () = if source.run_reference.mime = Tool_output.artifact_manifest_mime
      && source.run_reference.bytes = String.length bytes then Ok ()
    else Error (Malformed_draft "original run artifact media or bytes mismatch") in
  let* json = match Yojson.Safe.from_string bytes with
    | json -> Ok json | exception Yojson.Json_error detail -> Error (Malformed_draft detail) in
  let* json = match Tool_output.artifact_manifest_of_json json with
    | Tool_output.Decoded_artifact_manifest {structured_content;_} -> Ok structured_content
    | Tool_output.Not_artifact_manifest | Invalid_artifact_manifest _ ->
      Error (Malformed_draft "original run is not a canonical manifest") in
  let* fields = exact_fields ~names:["draft";"nested_calls";"nested_activation";"composition_run_id";"tool_use_id";"source_turn"] json in
  let* () = if Yojson.Safe.equal (List.assoc "draft" fields) (Tool_output.normalized_artifact_ref_to_json source.draft_reference)
      && List.assoc "composition_run_id" fields = `String (Plan.Composition_run_id.to_string source.composition_run_id)
      && List.assoc "tool_use_id" fields = `String source.parent_tool_use_id
      && List.assoc "source_turn" fields = `Int source.source_turn then Ok ()
    else Error (Malformed_draft "original run invocation mismatch") in
  Ok fields
;;

let nested_activation_from_fields fields =
  match List.assoc "nested_calls" fields,List.assoc "nested_activation" fields with
  | `List [],`Null -> Ok None
  | `List (_::_),json -> Keeper_skill_activation_recorder.bound_context_of_yojson json
      |> Result.map Option.some |> Result.map_error (fun error ->
          Malformed_draft (Keeper_skill_activation_recorder.error_to_string error))
  | _ -> Error (Malformed_draft "original child activation binding is incoherent")
;;

let load_nested_activation ~base_path source =
  let* fields = load_nested_run_fields ~base_path source in
  nested_activation_from_fields fields
;;

let load_nested_result_children ~base_path source ~result =
  let* fields = load_nested_run_fields ~base_path source in
  let* activation = nested_activation_from_fields fields in
  match activation with
  | None -> Ok None
  | Some activation ->
    let malformed detail = Error (Malformed_draft detail) in
    let* calls = match List.assoc "nested_calls" fields with
      | `List calls -> Ok calls | _ -> malformed "original child calls missing" in
    let* scopes = match result with
      | `Assoc result_fields ->
        (match List.filter_map (fun (name,value) -> if String.equal name "nested_scopes" then Some value else None) result_fields with
         | [`List scopes] -> Ok scopes
         | [] | [_] | _::_::_ -> malformed "terminal result has missing, duplicate or invalid child scopes")
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> malformed "terminal result is not an object" in
    let* children,seen = List.fold_left (fun result scope ->
      let* children,seen = result in
      let* fields = exact_fields ~names:["scope";"admission";"disposition";"cause";"nodes";"exports"] scope in
      let frozen = List.assoc "scope" fields in
      let* () = if List.exists (Yojson.Safe.equal frozen) calls && not (List.exists (Yojson.Safe.equal frozen) seen)
        then Ok () else malformed "result child scope differs or repeats the original frozen run" in
      let* call = exact_fields ~names:["alias";"reference";"arguments";"scope";"exports"] frozen in
      let* alias = match List.assoc "alias" call with `String alias -> Ok alias | _ -> malformed "invalid original child alias" in
      let* reference = Skill_reference.of_yojson (List.assoc "reference" call)
        |> Result.map_error (fun _ -> Malformed_draft "invalid original child reference") in
      let* child = match List.assoc "admission" fields with
        | `Null -> Ok None
        | `Assoc [("rejection",_)] -> Ok None
        | `Assoc _ as admission ->
          let* admission = exact_fields ~names:["skill_tool_use_id";"activation";"activation_frame_sha256"] admission in
          let* id = match List.assoc "skill_tool_use_id" admission with
            | `String id when String.trim id <> "" -> Ok id
            | _ -> malformed "invalid original child invocation ID" in
          let* receipt = Keeper_skill_activation_ledger.activation_of_yojson
              ~expected_trace_id:(Keeper_skill_activation_recorder.bound_trace_id activation)
              (List.assoc "activation" admission)
            |> Result.map_error (fun _ -> Malformed_draft "invalid retained original child activation") in
          let activation_frame_sha256 = Keeper_skill_activation_ledger.activation_frame_sha256 receipt in
          let* () = if String.equal id receipt.skill_tool_use_id
              && List.assoc "activation_frame_sha256" admission = `String activation_frame_sha256 then Ok ()
            else malformed "child admission differs from its retained activation frame" in
          Ok (Some Keeper_skill_activation_recorder.{alias;skill_reference=reference;skill_tool_use_id=id;activation_frame_sha256})
        | _ -> malformed "invalid typed child admission" in
      Ok ((match child with None -> children | Some child -> child::children),frozen::seen)) (Ok ([],[])) scopes in
    if List.length seen <> List.length calls then malformed "terminal result omitted an original child scope"
    else Ok (Some (activation,List.rev children))
;;
