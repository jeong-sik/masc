module Plan = Keeper_tool_plan
open Keeper_tool_execution_journal_types

exception Decode_error of string
let refuse detail = raise (Decode_error detail)
let require condition detail = if not condition then refuse detail
let decode f = try Ok (f ()) with
  | Decode_error detail | Yojson.Json_error detail -> Error detail
let sha text = Agent_core_sha256.(digest_string text |> to_hex)
let json_sha json = sha (Yojson.Safe.to_string json)
let canonical_equal left right = Yojson.Safe.equal (Yojson.Safe.sort left) (Yojson.Safe.sort right)
let nonblank text = String.trim text <> ""
let exact_name text = nonblank text && String.equal text (String.trim text)
let finite value = Float.is_finite value
let option_json encode = function None -> `Null | Some value -> `Assoc ["some", encode value]

let valid_json json =
  match Agent_core.Execution_json.validate ~context:"composition journal" json with
  | Ok () -> ()
  | Error error -> refuse (Agent_core.Execution_json.validation_error_to_string error)

let object_fields expected json =
  match Agent_core.Execution_json.object_fields ~context:"composition journal record"
      ~required:expected ~optional:[] json with
  | Ok fields -> fields
  | Error detail -> refuse detail

let field name fields = match List.assoc_opt name fields with Some value -> value | None -> refuse ("missing " ^ name)
let string = function `String value -> value | _ -> refuse "expected string"
let integer = function `Int value -> value | _ -> refuse "expected integer"
let bool = function `Bool value -> value | _ -> refuse "expected boolean"
let number = function
  | `Float value when finite value -> value
  | `Int value -> float_of_int value
  | _ -> refuse "expected finite number"
let list decode = function `List values -> List.map decode values | _ -> refuse "expected array"
let optional decode = function
  | `Null -> None
  | value -> let fields = object_fields ["some"] value in Some (decode (field "some" fields))
let nonnegative value = let value = integer value in require (value >= 0) "negative count"; value

(* The normalized reference remains the GC edge authority. Fingerprints are
   transport evidence and are preserved separately, never inferred from text. *)
let reference_json (reference : Tool_output.artifact_ref) =
  `Assoc ["reference", Tool_output.normalized_artifact_ref_to_json reference;
          "answer_fingerprint", option_json (fun value -> `String value) reference.answer_fingerprint]
let reference_of_json json =
  let fields = object_fields ["reference"; "answer_fingerprint"] json in
  let reference = match Tool_output.normalized_artifact_ref_of_json (field "reference" fields) with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | Tool_output.Invalid_normalized_artifact_ref {detail} -> refuse detail
    | Tool_output.Not_normalized_artifact_ref -> refuse "missing normalized artifact reference" in
  let fingerprint = optional string (field "answer_fingerprint" fields) in
  match Tool_output.with_answer_fingerprint reference fingerprint with
  | Ok reference -> reference
  | Error error -> refuse (Tool_output.make_error_to_string error)

let named_origin_to_yojson = function
  | Standalone -> `Assoc ["kind",`String "standalone"]
  | Nested origin -> `Assoc
      ["kind",`String "nested";
       "parent_run_id",`String (Plan.Composition_run_id.to_string origin.parent_run_id);
       "parent_node_id",`String (Plan.Node_id.to_string origin.parent_node_id);
       "parent_execution_id",Ids.Execution_id.to_yojson origin.parent_execution_id;
       "parent_occurrence_tool_use_id",`String origin.parent_occurrence_tool_use_id;
       "result_node_id",`String (Plan.Node_id.to_string origin.result_node_id);
       "args",origin.args;
       "activation",Keeper_skill_activation_ledger.activation_frame_to_yojson origin.activation]

let named_origin_of_json ~activation json =
  match json with
  | `Assoc [("kind",`String "standalone")] -> Standalone
  | `Assoc _ ->
    let fields = object_fields ["kind";"parent_run_id";"parent_node_id";"parent_execution_id";
        "parent_occurrence_tool_use_id";"result_node_id";"args";"activation"] json in
    require (field "kind" fields = `String "nested") "unknown named producer origin";
    let bound = match activation with Some context -> context | None -> refuse "nested producer has no original frame" in
    let parent_run_id = match Plan.Composition_run_id.of_string (string (field "parent_run_id" fields)) with
      | Ok id -> id | Error _ -> refuse "invalid nested parent run" in
    let node name = match Plan.Node_id.make (string (field name fields)) with
      | Ok id -> id | Error _ -> refuse "invalid nested parent node" in
    let parent_execution_id = match Ids.Execution_id.of_yojson (field "parent_execution_id" fields) with
      | Ok id -> id | Error detail -> refuse detail in
    let receipt = match Keeper_skill_activation_ledger.activation_of_yojson
        ~expected_trace_id:(Keeper_skill_activation_recorder.bound_trace_id bound) (field "activation" fields) with
      | Ok receipt -> receipt | Error _ -> refuse "invalid original nested activation receipt" in
    let origin = Nested {parent_run_id;parent_node_id=node "parent_node_id";parent_execution_id;
      parent_occurrence_tool_use_id=string (field "parent_occurrence_tool_use_id" fields);
      result_node_id=node "result_node_id";args=field "args" fields;activation=receipt} in
    require (canonical_equal json (named_origin_to_yojson origin)) "noncanonical nested producer origin";
    origin
  | _ -> refuse "named producer origin is not an object"

let producer_json = function
  | Prepared -> `Assoc ["kind",`String "prepared"]
  | Named {tool_name;skill_reference;activation;origin} -> `Assoc
      ["kind",`String "named";"tool_name",`String tool_name;
       "skill_reference",Skill_reference.to_yojson skill_reference;
       "activation",option_json Keeper_skill_activation_recorder.bound_context_to_yojson activation;
       "origin",named_origin_to_yojson origin]

let producer_of_json json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "prepared") -> ignore (object_fields ["kind"] json); Prepared
     | Some (`String "named") ->
       let fields = object_fields ["kind";"tool_name";"skill_reference";"activation";"origin"] json in
       let skill_reference = match Skill_reference.of_yojson (field "skill_reference" fields) with
         | Ok reference -> reference | Error _ -> refuse "invalid exact named Skill reference" in
       let activation = optional (fun json ->
         match Keeper_skill_activation_recorder.bound_context_of_yojson json with
         | Ok context -> context | Error error -> refuse (Keeper_skill_activation_recorder.error_to_string error))
           (field "activation" fields) in
       let origin = named_origin_of_json ~activation (field "origin" fields) in
       Named {tool_name=string (field "tool_name" fields);skill_reference;activation;origin}
     | _ -> refuse "unknown composition producer")
  | _ -> refuse "composition producer is not an object"

let source_json (source : source) =
  `Assoc ["keeper_name", `String source.keeper_name;
    "composition_run_id", `String (Plan.Composition_run_id.to_string source.composition_run_id);
    "draft_reference", reference_json source.draft_reference;
    "run_reference", reference_json source.run_reference;
    "parent_tool_use_id", `String source.parent_tool_use_id;
    "source_turn", `Int source.source_turn;
    "source_task_id", option_json (fun value -> `String value) source.source_task_id;
    "producer",producer_json source.producer]

let same_source left right = canonical_equal (source_json left) (source_json right)

let validate_source source =
  require (exact_name source.keeper_name) "invalid keeper name";
  require (exact_name source.parent_tool_use_id) "invalid parent tool-use identity";
  require (source.source_turn >= 0) "negative source turn";
  Option.iter (fun task -> require (exact_name task) "invalid source task identity") source.source_task_id;
  (match source.producer with
   | Prepared -> ()
   | Named {tool_name;skill_reference;activation;origin} ->
     (* The SDK provider/client ordinal is not the admitted Keeper cycle.
        Both original coordinates are sealed in the source; request ownership
        checks the SDK ordinal and the recorder retains its physical frame. *)
     require (exact_name tool_name) "invalid named producer tool";
     (match origin with
      | Standalone -> ()
      | Nested origin ->
        let bound = match activation with Some bound -> bound | None -> refuse "nested producer has no bound frame" in
        require (exact_name origin.parent_occurrence_tool_use_id) "invalid original parent occurrence";
        require (String.equal source.parent_tool_use_id origin.activation.skill_tool_use_id
          && source.source_turn = origin.activation.agent_core_turn
          && Skill_reference.equal_identity skill_reference.identity origin.activation.identity
          && skill_reference.content_revision = origin.activation.content_revision
          && Ids.Turn_ref.equal (Keeper_skill_activation_recorder.bound_turn_ref bound) origin.activation.turn_ref)
          "nested producer differs from original child activation";
        (match origin.activation.invocation with
         | Keeper_skill_activation_ledger.Nested_composition_invocation {scope;_} ->
           require (String.equal scope.composition_run_id (Plan.Composition_run_id.to_string origin.parent_run_id))
             "nested producer belongs to another parent run"
         | Instruction_invocation _ | Composition_invocation _ -> refuse "producer has no nested admission")));
  match Plan.Composition_run_id.of_string (Plan.Composition_run_id.to_string source.composition_run_id) with
  | Ok _ -> ()
  | Error _ -> refuse "invalid UUIDv7 composition run identity"

let source_of_json json =
  let fields = object_fields ["keeper_name"; "composition_run_id"; "draft_reference"; "run_reference"; "parent_tool_use_id"; "source_turn"; "source_task_id"; "producer"] json in
  let composition_run_id = match Plan.Composition_run_id.of_string (string (field "composition_run_id" fields)) with
    | Ok id -> id | Error _ -> refuse "invalid UUIDv7 composition run identity" in
  let source = {keeper_name = string (field "keeper_name" fields); composition_run_id;
    draft_reference = reference_of_json (field "draft_reference" fields);
    run_reference = reference_of_json (field "run_reference" fields);
    parent_tool_use_id = string (field "parent_tool_use_id" fields);
    source_turn = nonnegative (field "source_turn" fields);
    source_task_id = optional string (field "source_task_id" fields);
    producer=producer_of_json (field "producer" fields)} in
  validate_source source; source

let source_to_yojson = source_json
let source_of_yojson json =
  decode (fun () -> source_of_json json)
  |> Result.map_error (fun detail -> Invalid_source detail)

let source_observation_json (observation : source_observation) =
  `Assoc ["trace_id", option_json (fun id -> `String (Keeper_id.Trace_id.to_string id)) observation.trace_id;
    "session_id", option_json (fun id -> `String id) observation.session_id;
    "keeper_turn_id", option_json (fun id -> `Int id) observation.keeper_turn_id;
    "answer_source_ids", `List (List.map (fun id -> `String id)
      (List.sort_uniq String.compare observation.answer_source_ids))]

let source_observation_of_json json =
  let fields = object_fields ["trace_id";"session_id";"keeper_turn_id";"answer_source_ids"] json in
  let identity json = let id = string json in require (exact_name id) "invalid source observation identity"; id in
  let trace_id = optional (fun json ->
      let id = identity json in match Keeper_id.Trace_id.of_string id with
      | Ok id -> id | Error detail -> refuse detail) (field "trace_id" fields)
  and session_id = optional identity (field "session_id" fields)
  and keeper_turn_id = optional nonnegative (field "keeper_turn_id" fields) in
  let answer_source_ids = match field "answer_source_ids" fields with
    | `List ids -> List.map identity ids |> List.sort_uniq String.compare
    | _ -> refuse "source observation answers are not an array" in
  {trace_id;session_id;keeper_turn_id;answer_source_ids}

let same_source_observation left right = canonical_equal
    (option_json source_observation_json left) (option_json source_observation_json right)

(* Checkpoint's strict codec owns content variants and failure provenance. Its
   wire codec deliberately omits ToolResult.json, so this typed sidecar retains
   that optional value and recursively restores nested result blocks. The
   sidecar value is not checked here: [valid_json] over the whole row, run when
   an attempt settles and when a row is read, refuses non-finite numbers and
   duplicate keys in it. *)
let rec block_json block =
  let checkpoint = match Agent_core.Checkpoint.wire_content_block_to_json_result ~scope:"composition journal content" block with
    | Ok json -> json | Error error -> refuse (Agent_core.Error.to_string error) in
  let parsed_json, children = match block with
    | Llm_provider.Types.ToolResult {json; content_blocks; _} -> json, content_blocks
    | Llm_provider.Types.Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
    | ToolUse _ | Image _ | Document _ | Audio _ -> None, None in
  `Assoc ["checkpoint", checkpoint; "tool_result_json", option_json Fun.id parsed_json;
          "children", option_json (fun blocks -> `List (List.map block_json blocks)) children]

let rec block_of_json json =
  let fields = object_fields ["checkpoint"; "tool_result_json"; "children"] json in
  let block = match Agent_core.Checkpoint.wire_content_block_of_json (field "checkpoint" fields) with
    | Ok block -> block | Error error -> refuse (Agent_core.Error.to_string error) in
  let parsed_json = optional Fun.id (field "tool_result_json" fields) in
  let children = optional (list block_of_json) (field "children" fields) in
  let restored = match block with
  | Llm_provider.Types.ToolResult result ->
    require (Option.is_some result.content_blocks = Option.is_some children) "content sidecar shape mismatch";
    Llm_provider.Types.ToolResult {result with json = parsed_json; content_blocks = children}
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
  | ToolUse _ | Image _ | Document _ | Audio _ ->
    require (parsed_json = None && children = None) "sidecar on non-result content"; block in
  let encoded = block_json restored in
  require (canonical_equal encoded json) "checkpoint/sidecar content identity mismatch";
  restored

let result_json (result : Tool_result.result) =
  let common tool_name duration_ms metadata =
    require (exact_name tool_name) "invalid result tool name";
    require (finite duration_ms && duration_ms >= 0.) "invalid result duration";
    ["tool_name", `String tool_name; "duration_ms", `Float duration_ms;
     "metadata", option_json Fun.id metadata] in
  match result with
  | Tool_result.Completed output | Deferred output ->
    `Assoc (("disposition", `String (Tool_result.string_of_disposition result)) ::
      common output.tool_name output.duration_ms output.metadata @
      ["data", output.data;
       "retained_artifacts", `List (List.map reference_json output.retained_artifacts);
       "content_blocks", option_json (fun blocks -> `List (List.map block_json blocks)) output.content_blocks])
  | Failed failure ->
    let data_source = match failure.data_source with
      | Tool_result.Message_as_data -> `Assoc ["kind", `String "message"]
      | Explicit_data data -> `Assoc ["kind", `String "explicit"; "data", data] in
    `Assoc (("disposition", `String "failed") ::
      common failure.tool_name failure.duration_ms failure.metadata @
      ["class", Tool_result.tool_failure_class_to_yojson failure.class_;
       "effect_disposition", `String (Tool_result.failure_effect_disposition_to_string failure.effect_disposition);
       "message", `String failure.message; "data_source", data_source])

let effect_of_json json = match Tool_result.failure_effect_disposition_of_string (string json) with
  | Some phase -> phase | None -> refuse "unknown effect disposition"
let effect_json phase = `String (Tool_result.failure_effect_disposition_to_string phase)

let result_of_json json : Tool_result.result =
  let disposition = match json with `Assoc fields -> string (field "disposition" fields) | _ -> refuse "expected tool result object" in
  let common = ["disposition"; "tool_name"; "duration_ms"; "metadata"] in
  let fields = object_fields (common @ match disposition with
    | "completed" | "deferred" -> ["data"; "retained_artifacts"; "content_blocks"]
    | "failed" -> ["class"; "effect_disposition"; "message"; "data_source"]
    | _ -> refuse "unknown result disposition") json in
  let tool_name = string (field "tool_name" fields) in
  let duration_ms = number (field "duration_ms" fields) in
  require (exact_name tool_name && duration_ms >= 0.) "invalid tool result identity/duration";
  let metadata = optional Fun.id (field "metadata" fields) in
  match disposition with
  | "completed" | "deferred" ->
    let output : Tool_result.output_payload = {tool_name; duration_ms; metadata;
      data = field "data" fields;
      retained_artifacts = list reference_of_json (field "retained_artifacts" fields);
      content_blocks = optional (list block_of_json) (field "content_blocks" fields)} in
    if disposition = "completed" then Tool_result.Completed output else Deferred output
  | "failed" ->
    let data_source = match field "data_source" fields with
      | `Assoc ["kind", `String "message"] -> Tool_result.Message_as_data
      | `Assoc _ as json ->
        let fields = object_fields ["kind"; "data"] json in
        require (field "kind" fields = `String "explicit") "unknown failure data source";
        Tool_result.Explicit_data (field "data" fields)
      | _ -> refuse "invalid failure data source" in
    let class_ = match Tool_result.tool_failure_class_of_yojson (field "class" fields) with
      | Ok class_ -> class_ | Error detail -> refuse detail in
    Tool_result.Failed {tool_name; duration_ms; metadata; data_source; class_;
      message = string (field "message" fields);
      effect_disposition = effect_of_json (field "effect_disposition" fields)}
  | _ -> refuse "unknown result disposition"
