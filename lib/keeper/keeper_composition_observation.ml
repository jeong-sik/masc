module Run = Keeper_composition_nested_run
module Catalog = Keeper_tool_composition_catalog
module Ledger = Keeper_skill_activation_ledger
open Result.Syntax

type admission =
  | Not_attempted
  | Recorded of { tool_use_id : string; frame_sha256 : string; activation : Ledger.activation }
  | Rejected of Yojson.Safe.t
type node_origin = Arguments | Submission | Result | Child_node of string
type node =
  { node_id : string; origin : node_origin
  ; disposition : (unit, unit, unit) Tool_result.disposition option
  ; tool_use_id : string option; effect_disposition : Tool_result.failure_effect_disposition option
  ; validation_error : Yojson.Safe.t option }
type export_value = Available of Yojson.Safe.t | Unavailable of Yojson.Safe.t
type export = { name : string; node_id : string; pointer : string; value : export_value }
type child =
  { alias : string; reference : Skill_reference.t; execution : Catalog.execution_mode
  ; arguments : Yojson.Safe.t; admission : admission; disposition : Run.disposition
  ; cause : Yojson.Safe.t option; nodes : node list; exports : export list }
type reading = Absent | Observed of child list | Stored of Tool_output.artifact_ref | Invalid of string

let fields required optional json =
  Agent_core.Execution_json.object_fields ~context:"nested execution observation" ~required ~optional json
let text = function `String value when String.trim value <> "" -> Ok value | _ -> Error "Expected nonblank nested identity"
let string = function `String value -> Ok value | _ -> Error "Expected nested string"
let nullable = function `Null -> None | value -> Some value
let list decode = function
  | `List values -> List.fold_left (fun acc value -> let* acc = acc in
      let* value = decode value in Ok (value :: acc)) (Ok []) values |> Result.map List.rev
  | _ -> Error "Expected nested observation list"

let admission ~alias ~reference ?run_id = function
  | `Null -> Ok Not_attempted
  | `Assoc ["rejection", rejection] -> Ok (Rejected rejection)
  | json ->
    let* f = fields ["skill_tool_use_id";"activation";"activation_frame_sha256"] [] json in
    let* tool_use_id = text (List.assoc "skill_tool_use_id" f) in
    let* frame_sha256 = text (List.assoc "activation_frame_sha256" f) in
    let* () = Tool_output.validate_sha256 frame_sha256 |> Result.map_error Tool_output.invalid_sha256_to_string in
    let activation_json = List.assoc "activation" f in
    let* turn_json = match activation_json with
      | `Assoc fields -> (match List.assoc_opt "turn_ref" fields with
          | Some value -> Ok value | None -> Error "Child activation has no original turn")
      | _ -> Error "Child activation is not an object" in
    let* turn_ref = Ids.Turn_ref.of_yojson turn_json in
    let expected_trace_id = Keeper_id.Trace_id.of_string (Ids.Turn_ref.trace_id turn_ref) in
    let* activation = Ledger.activation_of_yojson ~expected_trace_id activation_json
        |> Result.map_error Ledger.decode_error_code in
    let* () = match activation.invocation with
      | Ledger.Nested_composition_invocation {scope;_}
        when String.equal scope.alias alias
          && Option.fold ~none:true ~some:(String.equal scope.composition_run_id) run_id
          && String.equal activation.skill_tool_use_id tool_use_id
          && Skill_reference.equal_identity reference.Skill_reference.identity activation.identity
          && reference.content_revision = activation.content_revision
          && String.equal (Ledger.activation_frame_sha256 activation) frame_sha256 -> Ok ()
      | _ -> Error "Child admission differs from its original scope, occurrence or activation frame" in
    Ok (Recorded {tool_use_id;frame_sha256;activation})

let node json =
  let* f = fields ["node_id";"settled";"disposition"]
      ["phase";"source";"tool_use_id";"failure_effect_disposition";"output_validation_error"] json in
  let* node_id = text (List.assoc "node_id" f) in
  let* origin = match List.assoc_opt "phase" f,List.assoc_opt "source" f with
    | Some (`String "arguments"),None -> Ok Arguments
    | Some (`String "submission"),None -> Ok Submission
    | Some (`String "result"),None -> Ok Result
    | None,Some source -> Result.map (fun value -> Child_node value) (text source)
    | _ -> Error "Unknown or ambiguous child node origin" in
  let* disposition = match List.assoc "settled" f,List.assoc "disposition" f with
    | `Bool false,`Null -> Ok None
    | `Bool true,`String value -> Result.map Option.some (Tool_result.unit_disposition_of_string value)
    | _ -> Error "Child node settlement and disposition disagree" in
  let* tool_use_id = match disposition,List.assoc_opt "tool_use_id" f with
    | None,None -> Ok None
    | Some _,Some value -> Result.map Option.some (text value)
    | _ -> Error "Child node occurrence does not match settlement" in
  let* effect_disposition = match List.assoc_opt "failure_effect_disposition" f with
    | None | Some `Null -> Ok None
    | Some (`String value) ->
      (match Tool_result.failure_effect_disposition_of_string value with
       | Some value -> Ok (Some value) | None -> Error "Unknown child effect evidence")
    | Some _ -> Error "Invalid child effect evidence" in
  let validation_error = Option.bind (List.assoc_opt "output_validation_error" f) nullable in
  Ok {node_id;origin;disposition;tool_use_id;effect_disposition;validation_error}

let route observed json =
  let* f = fields ["name";"node";"pointer"] [] json in
  let* name = text (List.assoc "name" f) in
  let* node_id = text (List.assoc "node" f) in
  let* pointer = string (List.assoc "pointer" f) in
  let* value = match List.filter (fun (key,_) -> key=name) observed with
    | [_,json] ->
      let* f = fields ["available"] ["value";"error"] json in
      (match List.assoc "available" f,List.assoc_opt "value" f,List.assoc_opt "error" f with
       | `Bool true,Some value,None -> Ok (Available value)
       | `Bool false,None,Some error -> Ok (Unavailable error)
       | _ -> Error "Invalid child export observation")
    | _ -> Error "Missing or duplicated child export observation" in
  Ok {name;node_id;pointer;value}

let child ?run_id json =
  let* f = fields ["scope";"admission";"disposition";"cause";"nodes";"exports"] [] json in
  let* scope = fields ["alias";"reference";"arguments";"scope";"exports"] [] (List.assoc "scope" f) in
  let* alias = text (List.assoc "alias" scope) in
  let* reference = Skill_reference.of_yojson (List.assoc "reference" scope)
      |> Result.map_error (fun _ -> "Invalid exact child Skill reference") in
  let* execution = match List.assoc "scope" scope with
    | `Assoc mapping ->
      (match List.assoc_opt "kind" mapping with
       | Some (`String "inline") -> Ok Catalog.Inline
       | Some (`String "async") -> Ok Catalog.Async
       | _ -> Error "Unknown child execution mode")
    | _ -> Error "Invalid child execution scope" in
  let arguments = List.assoc "arguments" scope in
  let* a = fields ["kind"] ["value";"input"] arguments in
  let* () = match List.assoc "kind" a,List.assoc_opt "value" a,List.assoc_opt "input" a with
    | `String "fixed",Some _,None -> Ok ()
    | `String "upstream",None,Some _ -> Ok ()
    | _ -> Error "Unknown declared child argument form" in
  let* admission = admission ~alias ~reference ?run_id (List.assoc "admission" f) in
  let* disposition_text = text (List.assoc "disposition" f) in
  let* disposition = Run.disposition_of_string disposition_text in
  let cause = nullable (List.assoc "cause" f) in
  let* nodes = list node (List.assoc "nodes" f) in
  let* exports = match List.assoc "exports" f with
    | `Assoc observed -> list (route observed) (List.assoc "exports" scope)
    | _ -> Error "Invalid observed child exports" in
  Ok {alias;reference;execution;arguments;admission;disposition;cause;nodes;exports}

let direct = function
  | `Assoc f ->
    (match List.filter (fun (key,_) -> key="nested_scopes") f with
     | [] -> Absent
     | [_,json] ->
       let decoded =
         let* run_id = match List.filter (fun (key,_) -> key="composition_run_id") f with
           | [] -> Ok None | [_,value] -> text value |> Result.map Option.some
           | _ -> Error "Duplicate parent run identity" in
         list (child ?run_id) json in
       (match decoded with Ok children -> Observed children | Error detail -> Invalid detail)
     | _ -> Invalid "Duplicate nested scope metadata")
  | _ -> Absent

let of_data json =
  match direct json with
  | (Observed _ | Stored _ | Invalid _) as reading -> reading
  | Absent ->
    (match Tool_output.artifact_manifest_of_json json with
     | Tool_output.Decoded_artifact_manifest manifest -> direct manifest.structured_content
     | Invalid_artifact_manifest {detail} -> Invalid detail
     | Not_artifact_manifest ->
       match json with
       | `Assoc f when List.mem_assoc "artifact_manifest" f ->
         (match fields ["artifact_manifest";"structured_content"] ["content"] json with
          | Ok envelope ->
            let reference=List.assoc "artifact_manifest" envelope in
            let data=List.assoc "structured_content" envelope in
            (match Tool_output.normalized_artifact_ref_of_json reference with
             | Decoded_normalized_artifact_ref reference when reference.mime=Tool_output.artifact_manifest_mime -> direct data
             | Decoded_normalized_artifact_ref _ | Not_normalized_artifact_ref
             | Invalid_normalized_artifact_ref _ -> Invalid "Invalid structured result manifest reference")
          | Error detail -> Invalid detail)
       | `Assoc f when List.mem_assoc "masc.tool_disposition" f ->
         let decoded =
           let* f = fields ["message";"masc.tool_disposition";"failure_class"]
               ["next_move";"data";"masc.payload"] json in
           let* _ = string (List.assoc "message" f) in
           let* class_name = text (List.assoc "failure_class" f) in
           match List.assoc "masc.tool_disposition" f,
                 Tool_result.tool_failure_class_of_string class_name with
           | `String "failed",Some _ ->
               Ok (Option.fold ~none:Absent ~some:direct (List.assoc_opt "data" f))
           | _ -> Error "Invalid original failure result envelope" in
         (match decoded with Ok reading -> reading | Error detail -> Invalid detail)
       | _ -> Absent)

let of_content content =
  match Tool_output.decode_from_agent_core content with
  | Tool_output.Decoded reference ->
    if reference.mime=Tool_output.artifact_manifest_mime then Stored reference else Absent
  | Invalid_marker {detail} -> Invalid detail
  | Not_marker ->
    (match Yojson.Safe.from_string content with json -> of_data json
     | exception Yojson.Json_error _ -> Absent)

let of_blob_response (reference : Tool_output.artifact_ref) json =
  let decoded =
    let* f = fields ["sha256";"bytes";"mime";"content"] [] json in
    let* content = string (List.assoc "content" f) in
    if List.assoc "sha256" f <> `String reference.sha256
       || List.assoc "bytes" f <> `Int reference.bytes
       || List.assoc "mime" f <> `String Tool_output.artifact_manifest_mime
       || reference.mime <> Tool_output.artifact_manifest_mime
       || String.length content <> reference.bytes
       || Agent_core_sha256.(to_hex (digest_string content)) <> reference.sha256
    then Error "Retained nested result manifest bytes or identity differ"
    else match Yojson.Safe.from_string content with
      | json ->
        (match Tool_output.artifact_manifest_of_json json with
         | Decoded_artifact_manifest manifest -> Ok (direct manifest.structured_content)
         | Invalid_artifact_manifest {detail} -> Error detail
         | Not_artifact_manifest -> Error "Retained child result is not a result manifest")
      | exception Yojson.Json_error detail -> Error detail in
  match decoded with Ok reading -> reading | Error detail -> Invalid detail
