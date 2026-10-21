(* One append authority for an immutable prepared source, its async owners and
   node occurrences. Kept below the existing durable async consumer tree so the
   full typed results retain their artifact roots independently of transcripts. *)
module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)

let ( let* ) = Result.bind

type nested_origin =
  { parent_run_id : Plan.Composition_run_id.t
  ; parent_node_id : Plan.Node_id.t
  ; parent_execution_id : Ids.Execution_id.t
  ; parent_occurrence_tool_use_id : string
  ; result_node_id : Plan.Node_id.t
  ; args : Yojson.Safe.t
  ; activation : Keeper_skill_activation_ledger.activation
  }
type named_origin = Standalone | Nested of nested_origin

type producer =
  | Prepared
  | Named of
      { tool_name : string
      ; skill_reference : Skill_reference.t
      ; activation : Keeper_skill_activation_recorder.bound_context option
      ; origin : named_origin
      }

type source =
  { keeper_name : string
  ; composition_run_id : Plan.Composition_run_id.t
  ; draft_reference : Tool_output.artifact_ref
  ; run_reference : Tool_output.artifact_ref
  ; parent_tool_use_id : string
  ; source_turn : int
  ; source_task_id : string option
  ; producer : producer
  }

type source_observation = {
  trace_id : Keeper_id.Trace_id.t option;
  session_id : string option;
  keeper_turn_id : int option;
  answer_source_ids : string list;
}

type completed =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; result : Tool_result.result
  ; result_bytes : int
  ; truncated_to : int option
  }

type recheck = { execution_id : Ids.Execution_id.t; tool_use_id : string }
type launch_invocation =
  { trace_id : string; turn_ref : Ids.Turn_ref.t; keeper_turn_id : int option }
type recheck_launch =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; invocation : launch_invocation
  }
type replay =
  | Dispatch
  | Reuse_completed of completed
  | Recheck_result of recheck
  | Recheck_launch of recheck_launch
  | Recheck_child_submission of recheck

type error =
  | Invalid_source of string
  | Missing_journal
  | Unreadable_journal of string
  | Corrupt_journal of string
  | Source_conflict
  | Queued_request_rejected of string
  | Prior_owner_not_terminal of { request_id : string; reason : string }
  | Ownership_changed
  | Node_identity_conflict of Plan.Node_id.t
  | Replay_not_proven of Plan.Node_id.t
  | Attempt_conflict of Plan.Node_id.t
  | Plan_identity_conflict
  | Draft_unavailable of string
  | Invalid_result of string
  | Invalid_continuation_marker of string
  | Persistence_failed of string

let error_to_json error =
  let kind, details = match error with
    | Invalid_source detail -> "invalid_source", ["detail", `String detail]
    | Missing_journal -> "missing_journal", []
    | Unreadable_journal detail -> "unreadable_journal", ["detail", `String detail]
    | Corrupt_journal detail -> "corrupt_journal", ["detail", `String detail]
    | Source_conflict -> "source_conflict", []
    | Queued_request_rejected detail -> "queued_request_rejected", ["detail", `String detail]
    | Prior_owner_not_terminal {request_id; reason} ->
      "prior_owner_not_terminal", ["request_id", `String request_id; "detail", `String reason]
    | Ownership_changed -> "ownership_changed", []
    | Node_identity_conflict node -> "node_identity_conflict", ["node_id", `String (Plan.Node_id.to_string node)]
    | Replay_not_proven node -> "replay_not_proven", ["node_id", `String (Plan.Node_id.to_string node)]
    | Attempt_conflict node -> "attempt_conflict", ["node_id", `String (Plan.Node_id.to_string node)]
    | Plan_identity_conflict -> "plan_identity_conflict", []
    | Draft_unavailable detail -> "draft_unavailable", ["detail", `String detail]
    | Invalid_result detail -> "invalid_result", ["detail", `String detail]
    | Invalid_continuation_marker detail -> "invalid_continuation_marker", ["detail", `String detail]
    | Persistence_failed detail -> "persistence_failed", ["detail", `String detail]
  in
  `Assoc (("kind", `String kind) :: details)

let error_to_string error = Yojson.Safe.to_string (error_to_json error)

let failure_class = function
  | Invalid_source _ | Source_conflict | Queued_request_rejected _
  | Prior_owner_not_terminal _ | Ownership_changed | Node_identity_conflict _
  | Replay_not_proven _ | Attempt_conflict _ | Plan_identity_conflict -> Tool_result.Workflow_rejection
  | Missing_journal | Unreadable_journal _ | Corrupt_journal _
  | Invalid_result _ | Persistence_failed _ | Draft_unavailable _ -> Tool_result.Runtime_failure
  | Invalid_continuation_marker _ -> Tool_result.Runtime_failure

exception Decode_error of string
let refuse detail = raise (Decode_error detail)
let require condition detail = if not condition then refuse detail
let decode f = try Ok (f ()) with
  | Decode_error detail | Yojson.Json_error detail -> Error detail
let sha text = Digestif.SHA256.(digest_string text |> to_hex)
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
  let checkpoint = match Agent_core.Checkpoint.content_block_to_json_result ~scope:"composition journal content" block with
    | Ok json -> json | Error error -> refuse (Agent_core.Error.to_string error) in
  let parsed_json, children = match block with
    | Llm_provider.Types.ToolResult {json; content_blocks; _} -> json, content_blocks
    | Llm_provider.Types.Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
    | ToolUse _ | Image _ | Document _ | Audio _ -> None, None in
  `Assoc ["checkpoint", checkpoint; "tool_result_json", option_json Fun.id parsed_json;
          "children", option_json (fun blocks -> `List (List.map block_json blocks)) children]

let rec block_of_json json =
  let fields = object_fields ["checkpoint"; "tool_result_json"; "children"] json in
  let block = match Agent_core.Checkpoint.content_block_of_json (field "checkpoint" fields) with
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

type binding = {request_id : string; generation : int}
type launch_mode = Initial_launch | Existing_only
type occurrence =
  { node_id : Plan.Node_id.t; tool_name : string; input : Yojson.Safe.t;
    input_sha : string; owner : binding; sequence : int;
    execution_id : Ids.Execution_id.t; tool_use_id : string; readonly : bool;
    launch_invocation : launch_invocation option; launch_mode : launch_mode }
type node_record =
  | Attempting of occurrence
  | Settled of occurrence * completed * Tool_result.failure_effect_disposition option
      * Dependency.t option
type child_link =
  { occurrence : occurrence
  ; result_node_id : Plan.Node_id.t
  ; child_source : source
  ; accepted : Dependency.composition option
  }
type resolution_decision = Reject | Cancel
type resolution =
  { owner : binding; decision : resolution_decision; requested_by : string
  ; reason : string; resolved_at : float; expected_version : string
  ; marker_version : string }
type resolution_observation =
  { request : Async.entry; version : string; resolution : resolution option }
type resolution_report =
  { resolution : resolution; marker_retired : bool; retirement_error : error option }

type state =
  { source : source; source_sha : string; source_observation : source_observation option; owner : binding option
  ; prior_owners : (binding * node_record Nodes.t) list; nodes : node_record Nodes.t
  ; children : child_link Nodes.t; resolution : resolution option }
type t = {base_path : string; root : string; path : string; immutable_source : source; source_sha : string;
          immutable_observation : source_observation option}
type request_observation =
  { journal : t; request_entry : Async.entry; observed_owner : binding
  ; observed_resolution : resolution option; journal_version : string; observed_at : float }
type worker = {journal : t; binding : binding}
type attempt = {worker : worker; occurrence : occurrence}
type child_submission = {attempt : attempt; link : child_link}
type continuation =
  { journal : t; expected_owner : binding
  ; terminal_entry : Async.entry
  ; predecessor_terminals : Async.entry list
  ; suspended_nodes : node_record Nodes.t
  ; suspended_children : child_link Nodes.t
  ; dependencies : Dependency.t list }
type readiness = Waiting_for_results | Results_ready

let binding_json binding = `Assoc ["request_id", `String binding.request_id; "generation", `Int binding.generation]
let binding_of_json json =
  let fields = object_fields ["request_id"; "generation"] json in
  let request_id = string (field "request_id" fields) and generation = integer (field "generation" fields) in
  require (exact_name request_id && generation > 0) "invalid worker binding";
  {request_id; generation}
let same_binding a b = String.equal a.request_id b.request_id && a.generation = b.generation
let same_owner a b = match a, b with None, None -> true | Some a, Some b -> same_binding a b | _ -> false

let resolution_decision_json = function Reject -> `String "rejected" | Cancel -> `String "cancelled"
let resolution_to_json (resolution : resolution) = `Assoc
  ["owner", binding_json resolution.owner; "decision", resolution_decision_json resolution.decision;
   "requested_by", `String resolution.requested_by; "reason", `String resolution.reason;
   "resolved_at", `Float resolution.resolved_at; "expected_version", `String resolution.expected_version;
   "marker_version", `String resolution.marker_version]

let resolution_of_json json =
  let fields = object_fields
      ["owner";"decision";"requested_by";"reason";"resolved_at";"expected_version";"marker_version"] json in
  let owner = binding_of_json (field "owner" fields) in
  let decision = match string (field "decision" fields) with
    | "rejected" -> Reject | "cancelled" -> Cancel | _ -> refuse "invalid resolution decision" in
  let requested_by = string (field "requested_by" fields)
  and reason = string (field "reason" fields)
  and expected_version = string (field "expected_version" fields)
  and marker_version = string (field "marker_version" fields)
  and resolved_at = number (field "resolved_at" fields) in
  let digest text = String.length text = 64 && String.for_all
      (function '0'..'9' | 'a'..'f' -> true | _ -> false) text in
  require (exact_name requested_by && nonblank reason && finite resolved_at
    && resolved_at >= 0. && digest expected_version && digest marker_version)
    "invalid resolution evidence";
  {owner;decision;requested_by;reason;resolved_at;expected_version;marker_version}

let resolution_observation_to_json (observation : resolution_observation) = `Assoc
  ["request", Async.entry_to_json observation.request; "expected_version", `String observation.version;
   "resolution", option_json resolution_to_json observation.resolution]

let resolution_report_to_json (report : resolution_report) = `Assoc
  ["resolution", resolution_to_json report.resolution; "marker_retired", `Bool report.marker_retired;
   "retirement_error", option_json error_to_json report.retirement_error]

let request_observation_to_json (observation : request_observation) =
  let source = observation.journal.immutable_source in
  `Assoc ["composition_run_id",`String (Plan.Composition_run_id.to_string source.composition_run_id);
    "source_task_id",(match source.source_task_id with None -> `Null | Some id -> `String id);
    "owner",binding_json observation.observed_owner;
    "journal_version",`String observation.journal_version;
    "observed_at",`Float observation.observed_at;
    "resolution",(match observation.observed_resolution with
      | None -> `Null | Some resolution -> resolution_to_json resolution)]

let request_observation_resolution observation = observation.observed_resolution

let same_request_observation (left : request_observation) (right : request_observation) =
  String.equal left.journal.base_path right.journal.base_path
  && Async.same_entry_record left.request_entry right.request_entry
  && String.equal left.journal_version right.journal_version
let occurrence_of_record = function Attempting occurrence | Settled (occurrence, _, _, _) -> occurrence
let launch_invocation_json (invocation : launch_invocation) =
  `Assoc ["trace_id", `String invocation.trace_id;
    "turn_ref", `String (Ids.Turn_ref.to_string invocation.turn_ref);
    "keeper_turn_id", option_json (fun value -> `Int value) invocation.keeper_turn_id]
let launch_invocation_of_json json =
  let fields = object_fields ["trace_id"; "turn_ref"; "keeper_turn_id"] json in
  let keeper_turn_id = optional integer (field "keeper_turn_id" fields) in
  require (Option.fold ~none:true ~some:(fun value -> value >= 0) keeper_turn_id) "invalid launch keeper turn";
  let trace_id = string (field "trace_id" fields) in
  match Ids.Turn_ref.of_string (string (field "turn_ref" fields)) with
  | Some turn_ref when exact_name trace_id
      && String.equal trace_id (Ids.Turn_ref.trace_id turn_ref) -> {trace_id; turn_ref; keeper_turn_id}
  | Some _ | None -> refuse "invalid launch invocation identity"
let occurrence_json occurrence =
  `Assoc ["node_id", `String (Plan.Node_id.to_string occurrence.node_id); "tool_name", `String occurrence.tool_name;
    "input", occurrence.input; "input_sha", `String occurrence.input_sha; "owner", binding_json occurrence.owner;
    "sequence", `Int occurrence.sequence; "execution_id", Ids.Execution_id.to_yojson occurrence.execution_id;
    "tool_use_id", `String occurrence.tool_use_id; "readonly", `Bool occurrence.readonly;
    "launch_invocation", option_json launch_invocation_json occurrence.launch_invocation;
    "launch_mode", `String (match occurrence.launch_mode with
      | Initial_launch -> "initial" | Existing_only -> "existing_only")]
let occurrence_of_json json =
  let fields = object_fields ["node_id"; "tool_name"; "input"; "input_sha"; "owner"; "sequence"; "execution_id"; "tool_use_id"; "readonly"; "launch_invocation"; "launch_mode"] json in
  let node_id = match Plan.Node_id.make (string (field "node_id" fields)) with Ok id -> id | Error _ -> refuse "invalid node identity" in
  let execution_id = match Ids.Execution_id.of_yojson (field "execution_id" fields) with Ok id -> id | Error detail -> refuse detail in
  let occurrence = {node_id; execution_id; tool_name = string (field "tool_name" fields);
    input = field "input" fields; input_sha = string (field "input_sha" fields);
    owner = binding_of_json (field "owner" fields); sequence = integer (field "sequence" fields);
    tool_use_id = string (field "tool_use_id" fields); readonly = bool (field "readonly" fields);
    launch_invocation = optional launch_invocation_of_json (field "launch_invocation" fields);
    launch_mode = (match field "launch_mode" fields with
      | `String "initial" -> Initial_launch
      | `String "existing_only" -> Existing_only
      | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
          refuse "invalid launch replay mode")} in
  require (exact_name occurrence.tool_name && exact_name occurrence.tool_use_id
    && exact_name (Ids.Execution_id.to_string execution_id) && occurrence.sequence > 0) "invalid occurrence identity";
  require (String.equal occurrence.input_sha (json_sha occurrence.input)) "input fingerprint mismatch";
  occurrence
let same_occurrence a b = occurrence_json a = occurrence_json b
let same_node_identity occurrence ~node_id ~tool_name ~input =
  Plan.Node_id.equal occurrence.node_id node_id && String.equal occurrence.tool_name tool_name
  && occurrence.input = input && String.equal occurrence.input_sha (json_sha input)

let child_link_json (link : child_link) = `Assoc
  ["occurrence",occurrence_json link.occurrence;
   "result_node_id",`String (Plan.Node_id.to_string link.result_node_id);
   "child_source",source_json link.child_source;
   "accepted",option_json Dependency.composition_to_json link.accepted]

let same_children left right =
  (* Sealed contexts reconstruct runtime closures; their persisted immutable
     coordinates, not OCaml function identity, are the ownership authority. *)
  Nodes.equal (fun left right -> canonical_equal (child_link_json left) (child_link_json right)) left right

let child_binding_matches (link : child_link) (binding : Dependency.composition) =
  let source = link.child_source in
  Plan.Composition_run_id.equal source.composition_run_id binding.Dependency.composition_run_id
  && String.equal source.parent_tool_use_id binding.parent_tool_use_id
  && source.source_turn = binding.source_turn
  && source.source_task_id = binding.source_task_id
  && match source.producer with
     | Prepared -> false
     | Named {tool_name;skill_reference;activation=_;origin=_} ->
       String.equal tool_name binding.composition_tool && Skill_reference.equal skill_reference binding.skill_reference

let child_occurrence_matches (link : child_link) (occurrence : occurrence) =
  Ids.Execution_id.equal link.occurrence.execution_id occurrence.execution_id
  && String.equal link.occurrence.tool_use_id occurrence.tool_use_id
  && same_node_identity link.occurrence ~node_id:occurrence.node_id
      ~tool_name:occurrence.tool_name ~input:occurrence.input

let child_intent_proven children (occurrence : occurrence) =
  match Nodes.find_opt (Plan.Node_id.to_string occurrence.node_id) children with
  | None -> false
  | Some link -> child_occurrence_matches link occurrence

let child_ack_proven children (occurrence : occurrence) =
  match Nodes.find_opt (Plan.Node_id.to_string occurrence.node_id) children with
  | None -> false
  | Some link -> Option.is_some link.accepted && child_occurrence_matches link occurrence

let completed_json (completed : completed) =
  `Assoc ["execution_id", Ids.Execution_id.to_yojson completed.execution_id;
    "tool_use_id", `String completed.tool_use_id; "result", result_json completed.result;
    "result_bytes", `Int completed.result_bytes; "truncated_to", option_json (fun value -> `Int value) completed.truncated_to]
let completed_of_json json =
  let fields = object_fields ["execution_id"; "tool_use_id"; "result"; "result_bytes"; "truncated_to"] json in
  let execution_id = match Ids.Execution_id.of_yojson (field "execution_id" fields) with Ok id -> id | Error detail -> refuse detail in
  let completed = {execution_id; tool_use_id = string (field "tool_use_id" fields);
    result = result_of_json (field "result" fields); result_bytes = nonnegative (field "result_bytes" fields);
    truncated_to = optional nonnegative (field "truncated_to" fields)} in
  require (exact_name completed.tool_use_id && exact_name (Ids.Execution_id.to_string execution_id)) "invalid completed occurrence";
  require (canonical_equal (completed_json completed) json) "noncanonical completed payload";
  completed

let event kind source_sha fields = `Assoc (["schema", `Int 3; "kind", `String kind; "source_sha", `String source_sha] @ fields)
let row json = Yojson.Safe.to_string json ^ "\n"
let source_event source = event "source" (json_sha (source_json source)) ["source", source_json source]
let source_observation_event source_sha observation =
  event "source_observation" source_sha ["observation",source_observation_json observation]
let attempt_event source_sha occurrence = event "attempting" source_sha ["occurrence", occurrence_json occurrence]

let dependency_wait_json = option_json Dependency.to_json
let dependency_wait_of_json = optional (fun json ->
  match Dependency.of_json json with
  | Ok dependency -> dependency | Error detail -> refuse detail)

let result_read_dependency children (occurrence : occurrence) =
  if not occurrence.readonly then None
  else if String.equal occurrence.tool_name Tool_schemas_composition_control.result_schema.name then
    match Nodes.bindings children |> List.find_map (fun (_,link) ->
      if Plan.Node_id.equal link.result_node_id occurrence.node_id && occurrence.input = `Assoc []
      then link.accepted else None) with
    | Some binding -> Some (Dependency.Composition_result binding)
    | None ->
    match Agent_core.Execution_json.object_fields ~context:"composition result journal input"
        ~required:["binding"] ~optional:[] occurrence.input with
    | Error _ -> None
    | Ok fields ->
      (match Dependency.composition_of_json (List.assoc "binding" fields) with
       | Ok binding when binding.request_id <> occurrence.owner.request_id ->
         Some (Dependency.Composition_result binding)
       | Ok _ | Error _ -> None)
  else
    let readonly_action = match Tool_schemas_owned_job.find_definition occurrence.tool_name with
      | Some {action=Tool_schemas_owned_job.Read_result;read_only;_} -> read_only
      | Some {action=(Start | Status | Cancel);_} | None -> false in
    if not readonly_action then None
    else match occurrence.input with
      | `Assoc ["job_id", `String id] ->
        (match Keeper_owned_job_store.Job_id.of_string id with
         | Ok job_id -> Some (Dependency.Owned_job job_id) | Error _ -> None)
      | _ -> None

let valid_dependency_wait children occurrence result phase dependency =
  result_read_dependency children occurrence = Some dependency
  && phase = Some Tool_result.Proven_pre_effect
  && (match result with Tool_result.Deferred _ -> true | Completed _ | Failed _ -> false)

let owned_job_launch occurrence =
  match Tool_schemas_owned_job.find_definition occurrence.tool_name with
  | Some {action=Tool_schemas_owned_job.Start;_} -> true
  | Some {action=(Tool_schemas_owned_job.Status | Cancel | Read_result);_} | None -> false

(* A launch leaf replays only through the exact invocation identity its
   durable occurrence recorded: re-calling with it makes the owned-job
   invocation binding return Existing, never a replacement launch. Without
   the recorded identity the fail-closed rule below still refuses replay. *)
let recheck_launch_for occurrence = match occurrence.launch_invocation with
  | Some invocation -> Some {execution_id=occurrence.execution_id; tool_use_id=occurrence.tool_use_id; invocation}
  | None -> None

let replay_for children binding node_id record =
  let refuse () = Error (Replay_not_proven node_id) in
  let recheck (occurrence : occurrence) =
    Ok (Recheck_result
      {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
  in
  let recheck_or_dispatch (occurrence : occurrence) =
    match result_read_dependency children occurrence with
    | Some _ -> recheck occurrence
    | None -> Ok Dispatch
  in
  match record with
  | None -> Ok Dispatch
  | Some (Attempting occurrence) ->
    if child_ack_proven children occurrence && not (same_binding occurrence.owner binding)
    then Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
    else if occurrence.readonly && not (same_binding occurrence.owner binding)
    then recheck_or_dispatch occurrence
    else if owned_job_launch occurrence then
      (match recheck_launch_for occurrence with
       | Some replay -> Ok (Recheck_launch replay)
       | None -> refuse ())
    else refuse ()
  | Some (Settled (occurrence, completed, phase, job)) ->
    (match completed.result with
     | Tool_result.Completed _ -> Ok (Reuse_completed completed)
     | Tool_result.Deferred _ ->
       if child_ack_proven children occurrence && not (same_binding occurrence.owner binding)
       then Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
       else
       (match job with
        | Some job_id when valid_dependency_wait children occurrence completed.result phase job_id ->
          recheck occurrence
        | None | Some _ -> refuse ())
     | Tool_result.Failed _ ->
       if child_ack_proven children occurrence && not (same_binding occurrence.owner binding)
       then Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
       else
       (match phase with
        | Some Tool_result.Proven_pre_effect ->
          if child_intent_proven children occurrence then
            Ok (Recheck_child_submission {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
          else if owned_job_launch occurrence && occurrence.launch_mode = Existing_only then
            (match recheck_launch_for occurrence with
             | Some original -> Ok (Recheck_launch original)
             | None -> refuse ())
          else recheck_or_dispatch occurrence
        | Some Tool_result.Effect_outcome_unknown when owned_job_launch occurrence ->
          (match recheck_launch_for occurrence with
           | Some replay -> Ok (Recheck_launch replay)
           | None -> refuse ())
        | None | Some (Tool_result.Proven_post_effect | Effect_outcome_unknown) -> refuse ()))

let decode_state bytes = decode (fun () ->
  require (bytes <> "" && bytes.[String.length bytes - 1] = '\n') "missing or incomplete journal identity";
  let lines = String.split_on_char '\n' bytes in
  let lines = match List.rev lines with "" :: rest -> List.rev rest | _ -> refuse "incomplete journal" in
  let jsons = List.mapi (fun index line ->
    require (String.trim line <> "") (Printf.sprintf "blank journal row %d" (index + 1));
    let json = Yojson.Safe.from_string line in valid_json json; json) lines in
  let header, events = match jsons with header :: events -> header, events | [] -> refuse "missing source header" in
  let fields = object_fields ["schema"; "kind"; "source_sha"; "source"] header in
  require (field "schema" fields = `Int 3 && field "kind" fields = `String "source") "invalid source header schema";
  let source = source_of_json (field "source" fields) in
  let source_sha = string (field "source_sha" fields) in
  require (String.equal source_sha (json_sha (source_json source))) "source fingerprint mismatch";
  let source_observation, events = match events with
    | (`Assoc fields as json) :: rest
      when List.assoc_opt "kind" fields = Some (`String "source_observation") ->
        let fields = object_fields ["schema";"kind";"source_sha";"observation"] json in
        require (field "schema" fields = `Int 3 && field "source_sha" fields = `String source_sha)
          "source observation belongs to another source";
        Some (source_observation_of_json (field "observation" fields)), rest
    | _ -> None, events in
  List.fold_left (fun state json ->
    require (state.resolution = None) "journal event follows a terminal operator resolution";
    let kind = match json with `Assoc fields -> string (field "kind" fields) | _ -> refuse "invalid journal row" in
    let extras = match kind with
      | "binding" -> ["expected_owner"; "owner"]
      | "attempting" -> ["occurrence"]
      | "settled" -> ["occurrence"; "completed"; "failure_effect_disposition"; "dependency_wait"]
      | "child_intent" -> ["occurrence";"result_node_id";"child_source"]
      | "child_accepted" -> ["node_id";"binding"]
      | "resolution" -> ["resolution"]
      | _ -> refuse "unknown journal event" in
    let fields = object_fields (["schema"; "kind"; "source_sha"] @ extras) json in
    require (field "schema" fields = `Int 3 && field "source_sha" fields = `String source_sha) "event source/schema mismatch";
    match kind with
    | "resolution" ->
      let resolution = resolution_of_json (field "resolution" fields) in
      require (same_owner state.owner (Some resolution.owner)) "resolution owner mismatch";
      {state with resolution=Some resolution}
    | "child_intent" ->
      let occurrence = occurrence_of_json (field "occurrence" fields) in
      let key = Plan.Node_id.to_string occurrence.node_id in
      require (same_owner state.owner (Some occurrence.owner) && not occurrence.readonly) "child intent has no effectful current owner";
      require (match Nodes.find_opt key state.nodes with
        | Some (Attempting current) -> same_occurrence current occurrence
        | None | Some (Settled _) -> false) "child intent has no exact parent attempt";
      require (not (Nodes.mem key state.children)) "child intent already exists";
      let result_node_id = match Plan.Node_id.make (string (field "result_node_id" fields)) with
        | Ok id -> id | Error _ -> refuse "invalid child result node" in
      let child_source = source_of_json (field "child_source" fields) in
      let origin = match child_source.producer with
        | Named {origin=Nested origin;_} -> origin
        | Named {origin=Standalone;_} | Prepared -> refuse "child intent lacks original Nested origin" in
      require (Plan.Composition_run_id.equal origin.parent_run_id state.source.composition_run_id
        && Plan.Node_id.equal origin.parent_node_id occurrence.node_id
        && Plan.Node_id.equal origin.result_node_id result_node_id
        && Ids.Execution_id.equal origin.parent_execution_id occurrence.execution_id
        && String.equal origin.parent_occurrence_tool_use_id occurrence.tool_use_id
        && String.equal child_source.keeper_name state.source.keeper_name
        && child_source.source_turn = state.source.source_turn
        && child_source.source_task_id = state.source.source_task_id) "child intent differs from its original parent occurrence";
      {state with children=Nodes.add key {occurrence;result_node_id;child_source;accepted=None} state.children}
    | "child_accepted" ->
      let key = string (field "node_id" fields) in
      let link = match Nodes.find_opt key state.children with Some link -> link | None -> refuse "acceptance has no original child intent" in
      require (link.accepted = None) "child acceptance is already committed";
      require (match Nodes.find_opt key state.nodes with
        | Some (Attempting current) -> same_owner state.owner (Some current.owner)
            && child_occurrence_matches link current
        | None | Some (Settled _) -> false) "child acceptance has no original parent attempt";
      let binding = match Dependency.composition_of_json (field "binding" fields) with
        | Ok binding -> binding | Error detail -> refuse detail in
      require (child_binding_matches link binding) "child acceptance differs from its original source";
      {state with children=Nodes.add key {link with accepted=Some binding} state.children}
    | "binding" ->
      let expected = optional binding_of_json (field "expected_owner" fields) in
      let owner = binding_of_json (field "owner" fields) in
      require (same_owner state.owner expected) "binding predecessor mismatch";
      require (owner.generation = (match expected with None -> 1 | Some prior -> prior.generation + 1)) "binding generation mismatch";
      require (match expected with None -> true | Some prior -> prior.request_id <> owner.request_id) "duplicate binding event";
      {state with owner = Some owner;
        prior_owners = Option.to_list (Option.map (fun prior -> prior, state.nodes) expected)
          @ state.prior_owners}
    | "attempting" | "settled" ->
      let occurrence = occurrence_of_json (field "occurrence" fields) in
      require (same_owner state.owner (Some occurrence.owner)) "node event outside current owner";
      let key = Plan.Node_id.to_string occurrence.node_id in
      let prior = Nodes.find_opt key state.nodes in
      Option.iter (fun record -> require (same_node_identity (occurrence_of_record record)
        ~node_id:occurrence.node_id ~tool_name:occurrence.tool_name ~input:occurrence.input) "node identity changed") prior;
      let record = if kind = "attempting" then (
        require (occurrence.sequence = (match prior with None -> 1 | Some record -> (occurrence_of_record record).sequence + 1)) "attempt sequence mismatch";
        require (match replay_for state.children occurrence.owner occurrence.node_id prior with
          | Ok Dispatch -> occurrence.launch_mode = Initial_launch
          | Ok (Recheck_result stored) -> occurrence.launch_mode = Initial_launch && occurrence.readonly
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
          | Ok (Recheck_launch stored) -> occurrence.launch_mode = Existing_only && owned_job_launch occurrence
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
              && occurrence.launch_invocation = Some stored.invocation
          | Ok (Recheck_child_submission stored) -> occurrence.launch_mode = Initial_launch && not occurrence.readonly
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
          | Ok (Reuse_completed _) | Error _ -> false) "unproven replay event";
        Attempting occurrence)
      else (
        require (match prior with Some (Attempting current) -> same_occurrence current occurrence
                | Some (Settled _) | None -> false) "settlement without exact attempt";
        let completed = completed_of_json (field "completed" fields) in
        require (Ids.Execution_id.equal completed.execution_id occurrence.execution_id && completed.tool_use_id = occurrence.tool_use_id
          && String.equal (Tool_result.tool_name completed.result) occurrence.tool_name) "settlement identity mismatch";
        let phase = optional effect_of_json (field "failure_effect_disposition" fields) in
        let dependency_wait = dependency_wait_of_json (field "dependency_wait" fields) in
        Option.iter (fun job_id -> require (valid_dependency_wait state.children occurrence completed.result phase job_id)
          "dependency wait does not match the exact read-only result leaf") dependency_wait;
        Settled (occurrence, completed, phase, dependency_wait)) in
      {state with nodes = Nodes.add key record state.nodes}
    | _ -> refuse "unknown journal event")
    {source; source_sha; source_observation; owner = None; prior_owners = []; nodes = Nodes.empty;
     children=Nodes.empty;resolution=None} events)

let source journal = journal.immutable_source
let source_observation journal = journal.immutable_observation
let worker_source (worker : worker) = worker.journal.immutable_source
let worker_source_observation (worker : worker) = worker.journal.immutable_observation
let path_for ~base_path ~keeper_name ~composition_run_id =
  let root = Common.masc_dir_from_base_path ~base_path in
  let directory = Filename.concat (Filename.concat (Filename.concat root "keeper_msg_requests") "execution_journals") (sha keeper_name) in
  root, Filename.concat directory (Plan.Composition_run_id.to_string composition_run_id ^ ".jsonl")

let validate_owned_path_blocking ~root ~path ~create =
  match Fs_compat.owned_directory_paths ~ownership_root:root (Filename.dirname path) with
  | Error rejection -> Error (Unreadable_journal (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  | Ok paths ->
    let inspect expected_kind location =
      match Unix.lstat location with
      | stats ->
        Result.map_error (fun detail -> Unreadable_journal detail) (decode (fun () ->
          require (stats.st_kind = expected_kind && stats.st_uid = Unix.getuid () && stats.st_perm land 0o022 = 0)
            ("unowned filesystem entry " ^ location);
          if expected_kind = Unix.S_REG then require (stats.st_nlink = 1) "non-unique journal file"))
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> if create then Ok () else Error Missing_journal in
    let* () = List.fold_left (fun prior directory -> let* () = prior in inspect Unix.S_DIR directory) (Ok ()) (root :: paths) in
    inspect Unix.S_REG path

let validate_owned_path ~root ~path ~create =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> validate_owned_path_blocking ~root ~path ~create
  | Fs_compat.Eio_fiber ->
    Eio_unix.run_in_systhread ~label:"composition-journal-owned-path"
      (fun () -> validate_owned_path_blocking ~root ~path ~create)

let filesystem f = try f () with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Unix.Unix_error (code, operation, path) -> Error (Persistence_failed (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code)))
  | Sys_error detail -> Error (Persistence_failed detail)

let read_manifest ~base_path (reference : Tool_output.artifact_ref) =
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256
    |> Result.map_error (fun error -> Draft_unavailable (Tool_blob_store.fetch_error_to_string error)) in
  let* bytes = match bytes with Some bytes -> Ok bytes | None -> Error (Draft_unavailable "original artifact absent") in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () ->
    require (reference.mime = Tool_output.artifact_manifest_mime && String.length bytes = reference.bytes)
      "original artifact media type or byte identity mismatch";
    let json = Yojson.Safe.from_string bytes in valid_json json;
    match Tool_output.artifact_manifest_of_json json with
    | Tool_output.Decoded_artifact_manifest {structured_content; _} -> structured_content
    | Tool_output.Invalid_artifact_manifest {detail} -> refuse detail
    | Tool_output.Not_artifact_manifest -> refuse "expected canonical prepared artifact manifest"))

let frozen_draft ~base_path immutable_source =
  let* draft = read_manifest ~base_path immutable_source.draft_reference in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () ->
    let fields = object_fields ["keeper"; "execution"; "recipe"; "plan"; "nested_calls"; "contracts"; "skill"] draft in
    require (field "keeper" fields = `String immutable_source.keeper_name) "draft keeper identity mismatch";
    require (field "execution" fields = `String "async") "journal requires a prepared async draft";
    fields))

let frozen_plan ~base_path immutable_source =
  let* fields = frozen_draft ~base_path immutable_source in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () -> field "plan" fields))

let validate_artifacts ~base_path immutable_source =
  let* draft = frozen_draft ~base_path immutable_source in
  let* run = read_manifest ~base_path immutable_source.run_reference in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () ->
    let fields = object_fields ["draft"; "nested_calls"; "nested_activation"; "composition_run_id"; "tool_use_id"; "source_turn"] run in
    require (canonical_equal (field "draft" fields) (Tool_output.normalized_artifact_ref_to_json immutable_source.draft_reference))
      "run artifact draft identity mismatch";
    require (canonical_equal (field "nested_calls" fields) (field "nested_calls" draft))
      "run artifact frozen child mapping mismatch";
    (match field "nested_calls" fields,field "nested_activation" fields with
     | `List [],`Null -> ()
     | `List (_::_),binding ->
       (match Keeper_skill_activation_recorder.bound_context_of_yojson binding with
        | Ok _ -> () | Error error -> refuse (Keeper_skill_activation_recorder.error_to_string error))
     | _ -> refuse "run artifact original child activation binding mismatch");
    require (field "composition_run_id" fields = `String (Plan.Composition_run_id.to_string immutable_source.composition_run_id)
      && field "tool_use_id" fields = `String immutable_source.parent_tool_use_id
      && field "source_turn" fields = `Int immutable_source.source_turn) "run artifact original invocation mismatch"))

let strict_read ~root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ()) ~ownership_root:root path with
  | Error error -> Error (Unreadable_journal (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Error Missing_journal
  | Ok (Some contents) -> Result.map_error (fun detail -> Corrupt_journal detail) (decode_state contents.content)

let check_source (journal : t) (state : state) =
  if source_json journal.immutable_source = source_json state.source && journal.source_sha = state.source_sha
     && same_source_observation journal.immutable_observation state.source_observation
  then Ok () else Error Source_conflict

let cleanup_warning path failure =
  (* Logging cannot turn the transaction's known primary outcome into a write
     failure. Cancellation still propagates; ordinary sink I/O is observational. *)
  try
    Log.Keeper.warn "composition journal primary transaction outcome preserved; descriptor cleanup failed for %s: %s"
      path (Fs_compat.private_jsonl_operation_failure_to_string failure)
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Sys_error _ | Unix.Unix_error _ -> ()

let update_existing_with_bytes journal decide = filesystem (fun () ->
  let* () = validate_owned_path ~root:journal.root ~path:journal.path ~create:false in
  let callback bytes =
    match validate_owned_path ~root:journal.root ~path:journal.path ~create:false with
    | Error error -> None, Error error
    | Ok () ->
      match Result.map_error (fun detail -> Corrupt_journal detail) (decode_state bytes) with
      | Error error -> None, Error error
      | Ok state -> match check_source journal state with Error error -> None, Error error | Ok () -> decide bytes state in
  let unpack = function None -> Error Missing_journal | Some result -> result in
  match Fs_compat.update_existing_private_file_durable_locked_result journal.path callback with
  | Fs_compat.Private_file_succeeded value -> unpack value
  | Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} ->
    cleanup_warning journal.path cleanup_failure; unpack value
  | Private_file_failed error -> Error (Persistence_failed (Fs_compat.private_jsonl_transaction_error_to_string error))
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
    Error (Persistence_failed (Fs_compat.private_jsonl_transaction_error_to_string error ^ "; cleanup=" ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let update_existing journal decide = update_existing_with_bytes journal (fun _ state -> decide state)

let prepare ?observation ~base_path immutable_source = filesystem (fun () ->
  let* () = Result.map_error (fun detail -> Invalid_source detail) (decode (fun () -> validate_source immutable_source)) in
  let base_path = Fs_compat.realpath base_path in
  let* () = validate_artifacts ~base_path immutable_source in
  let root, path = path_for ~base_path ~keeper_name:immutable_source.keeper_name ~composition_run_id:immutable_source.composition_run_id in
  let journal = {base_path; root; path; immutable_source; source_sha = json_sha (source_json immutable_source);
                 immutable_observation=observation} in
  let* () = validate_owned_path ~root ~path ~create:true in
  Fs_compat.mkdir_p (Filename.dirname path);
  let* () = validate_owned_path ~root ~path ~create:true in
  let existing = strict_read ~root path in
  let* absent = match existing with
    | Error Missing_journal -> Ok true
    | Error (Invalid_source _ | Unreadable_journal _ | Corrupt_journal _ | Source_conflict
        | Queued_request_rejected _ | Prior_owner_not_terminal _ | Ownership_changed
        | Node_identity_conflict _ | Replay_not_proven _ | Attempt_conflict _ | Plan_identity_conflict
        | Draft_unavailable _ | Invalid_result _ | Invalid_continuation_marker _
        | Persistence_failed _ as error) -> Error error
    | Ok state ->
        let* () = check_source {journal with immutable_observation=state.source_observation} state in
        Ok false in
  let callback bytes =
    match validate_owned_path ~root ~path ~create:false with
    | Error error -> None, Error error
    | Ok () ->
      if bytes = "" && absent then
        (match decode (fun () -> Option.map (fun observation ->
            source_observation_of_json (source_observation_json observation)) observation) with
         | Error detail -> None, Error (Invalid_source detail)
         | Ok observation ->
             let bytes = row (source_event immutable_source)
               ^ (match observation with None -> "" | Some observation ->
                   row (source_observation_event journal.source_sha observation)) in
             Some bytes, Ok {journal with immutable_observation=observation})
      else match Result.map_error (fun detail -> Corrupt_journal detail) (decode_state bytes) with
        | Error error -> None, Error error
        | Ok state ->
            let journal = {journal with immutable_observation=state.source_observation} in
            None, Result.map (fun () -> journal) (check_source journal state) in
  match Fs_compat.update_private_file_durable_locked_result path callback with
  | Fs_compat.Private_file_succeeded value -> value
  | Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} -> cleanup_warning path cleanup_failure; value
  | Private_file_failed error -> Error (Persistence_failed (Fs_compat.durable_append_error_to_string error))
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
    Error (Persistence_failed (Fs_compat.durable_append_error_to_string error ^ "; cleanup=" ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let load_authority_state ~base_path ~keeper_name ~composition_run_id = filesystem (fun () ->
  if not (exact_name keeper_name) then Error (Invalid_source "invalid keeper name") else
  let base_path = Fs_compat.realpath base_path in
  let root, path = path_for ~base_path ~keeper_name ~composition_run_id in
  let* state = strict_read ~root path in
  if not (String.equal state.source.keeper_name keeper_name && Plan.Composition_run_id.equal state.source.composition_run_id composition_run_id)
  then Error Source_conflict else
  Ok ({base_path; root; path; immutable_source = state.source; source_sha = state.source_sha;
       immutable_observation=state.source_observation},state))

let load_authority ~base_path ~keeper_name ~composition_run_id =
  load_authority_state ~base_path ~keeper_name ~composition_run_id |> Result.map fst

let load ~base_path ~keeper_name ~composition_run_id =
  let* journal = load_authority ~base_path ~keeper_name ~composition_run_id in
  let* () = filesystem (fun () -> validate_artifacts ~base_path:journal.base_path journal.immutable_source) in
  Ok journal

let entry_matches_source source (entry : Async.entry) = decode (fun () ->
  require (String.equal entry.keeper_name source.keeper_name && String.equal entry.submitted_by source.keeper_name) "request caller/keeper mismatch";
  let fields = match entry.request_context with Some fields -> fields | None -> refuse "missing prepared request context" in
  valid_json (`Assoc fields);
  let unique name = match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
    | [value] -> value | _ -> refuse ("missing or duplicate context " ^ name) in
  require (unique "composition_run_id" = `String (Plan.Composition_run_id.to_string source.composition_run_id)) "request run identity mismatch";
  let reference name expected = match Tool_output.normalized_artifact_ref_of_json (unique name) with
    | Tool_output.Decoded_normalized_artifact_ref found ->
      require (Tool_output.normalized_artifact_ref_to_json found = Tool_output.normalized_artifact_ref_to_json expected) ("request " ^ name ^ " mismatch")
    | Tool_output.Invalid_normalized_artifact_ref {detail} -> refuse detail
    | Tool_output.Not_normalized_artifact_ref -> refuse ("invalid context reference " ^ name) in
  reference "draft_reference" source.draft_reference; reference "run_artifact" source.run_reference;
  (match source.producer with
   | Prepared -> require (unique "composition_tool" = `String Keeper_tool_composition_catalog.run_tool_name)
       "prepared producer tool mismatch"
   | Named {tool_name;skill_reference;activation=_;origin=_} ->
     require (unique "composition_tool" = `String tool_name
       && canonical_equal (unique "skill_reference") (Skill_reference.to_yojson skill_reference))
       "named producer identity mismatch");
  require (unique "parent_tool_use_id" = `String source.parent_tool_use_id && unique "source_turn" = `Int source.source_turn) "original invocation mismatch";
  let task_fields = List.filter_map (fun (name, value) -> if name = "source_task_id" then Some value else None) fields in
  require (task_fields = (match source.source_task_id with None -> [] | Some task -> [`String task])) "source task identity mismatch")

let validate_request journal (entry : Async.entry) = filesystem (fun () ->
  if not (String.equal (Fs_compat.realpath entry.base_path) journal.base_path)
  then Error Source_conflict
  else
    let* () = entry_matches_source journal.immutable_source entry
      |> Result.map_error (fun detail -> Invalid_source detail) in
    let* state = strict_read ~root:journal.root journal.path in
    let* () = check_source journal state in
    let belongs (binding : binding) = String.equal binding.request_id entry.request_id in
    if Option.exists belongs state.owner
       || List.exists (fun (binding,_) -> belongs binding) state.prior_owners
    then Ok () else Error (Invalid_source "canonical request was not admitted to this prepared run"))

let canonical_queued journal request_id =
  let* proof = Async.load_canonical_durable_queued ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id
    |> Result.map_error (fun error -> Queued_request_rejected (Async.canonical_queued_error_to_string error)) in
  Result.map_error (fun detail -> Queued_request_rejected detail)
    (entry_matches_source journal.immutable_source (Async.durable_queued_entry proof))

type continuation_marker =
  { request_id : string; keeper_name : string
  ; composition_run_id : Plan.Composition_run_id.t }

let continuation_directory ~base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path)
    "keeper_msg_requests") "prepared_continuations"
let continuation_filename request_id = sha request_id ^ ".json"
let continuation_marker_json (marker : continuation_marker) =
  `Assoc ["schema", `String "keeper.prepared_continuation.v1";
    "request_id", `String marker.request_id; "keeper_name", `String marker.keeper_name;
    "composition_run_id", `String (Plan.Composition_run_id.to_string marker.composition_run_id)]
let decode_continuation_marker bytes =
  Result.map_error (fun detail -> Invalid_continuation_marker detail) (decode (fun () ->
    let fields = object_fields ["schema";"request_id";"keeper_name";"composition_run_id"]
        (Yojson.Safe.from_string bytes) in
    require (field "schema" fields = `String "keeper.prepared_continuation.v1") "unknown continuation marker schema";
    let request_id = string (field "request_id" fields)
    and keeper_name = string (field "keeper_name" fields) in
    require (exact_name request_id && exact_name keeper_name) "invalid continuation marker owner";
    let composition_run_id = match Plan.Composition_run_id.of_string
        (string (field "composition_run_id" fields)) with
      | Ok identity -> identity
      | Error (Plan.Composition_run_id.Invalid_uuid_v7 detail) -> refuse detail in
    {request_id;keeper_name;composition_run_id}))

let continuation_receipt path (receipt : 'a Fs_compat.private_jsonl_success_receipt) =
  (match receipt.settlement_error with
   | None -> ()
   | Some error ->
     (try Log.Keeper.warn "prepared continuation primary outcome preserved; settlement failed path=%s detail=%s"
        path (Fs_compat.private_jsonl_transaction_error_to_string error)
      with Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
        | Sys_error _ | Unix.Unix_error _ -> ()));
  receipt.value

let continuation_snapshot ~root path =
  let* () = validate_owned_path ~root ~path ~create:true in
  let* () = validate_owned_path ~root ~path:(Fs_compat.private_jsonl_lock_path path) ~create:true in
  let* receipt = Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
    |> Fs_compat.private_jsonl_snapshot_success_receipt
    |> Result.map_error (fun error -> Persistence_failed
        (Fs_compat.private_jsonl_transaction_error_to_string error)) in
  let* () = validate_owned_path ~root ~path ~create:true in
  let* () = validate_owned_path ~root ~path:(Fs_compat.private_jsonl_lock_path path) ~create:false in
  Ok (continuation_receipt path receipt)

let prepare_continuation_marker journal ~request_id = filesystem (fun () ->
  let source = journal.immutable_source in
  let marker = {request_id;keeper_name=source.keeper_name;composition_run_id=source.composition_run_id} in
  let path = Filename.concat (continuation_directory ~base_path:journal.base_path)
      (continuation_filename request_id) in
  let* () = validate_owned_path ~root:journal.root ~path ~create:true in
  Fs_compat.mkdir_p (Filename.dirname path);
  let* snapshot = continuation_snapshot ~root:journal.root path in
  if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then
    let* receipt = Fs_compat.append_private_jsonl_durable_locked_at_cursor_result path
        ~expected:snapshot.cursor (row (continuation_marker_json marker))
      |> Fs_compat.private_jsonl_cursor_success_receipt
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.private_jsonl_transaction_error_to_string error)) in
    ignore (continuation_receipt path receipt); Ok ()
  else
    let* found = decode_continuation_marker snapshot.bytes in
    if continuation_marker_json found = continuation_marker_json marker then Ok ()
    else Error (Invalid_continuation_marker "marker changed request/run/owner identity"))

let marker_version (snapshot : Fs_compat.private_jsonl_snapshot) =
  json_sha (`List [`String snapshot.bytes;
    `String (Fs_compat.Private_jsonl_cursor.fingerprint snapshot.cursor)])

let resolution_marker journal request_id =
  let path = Filename.concat (continuation_directory ~base_path:journal.base_path)
      (continuation_filename request_id) in
  let* snapshot = continuation_snapshot ~root:journal.root path in
  let* () = if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok () else
    let* marker = decode_continuation_marker snapshot.bytes in
    if String.equal marker.request_id request_id
        && String.equal marker.keeper_name journal.immutable_source.keeper_name
        && Plan.Composition_run_id.equal marker.composition_run_id journal.immutable_source.composition_run_id
    then Ok () else Error (Invalid_continuation_marker "resolution marker differs from the original source") in
  Ok (path,snapshot)

let retire_resolution_marker ~root ~path ~snapshot (resolution : resolution) =
  if Fs_compat.Private_jsonl_cursor.is_missing snapshot.Fs_compat.cursor then Ok ()
  else if not (String.equal (marker_version snapshot) resolution.marker_version)
  then Error (Invalid_continuation_marker "resolved marker was replaced; replacement retained")
  else
    let* () = validate_owned_path ~root ~path ~create:true in
    let* receipt = Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_result path
        ~expected:snapshot
      |> Fs_compat.private_jsonl_cursor_success_receipt
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.private_jsonl_transaction_error_to_string error)) in
    ignore (continuation_receipt path receipt);
    match receipt.settlement_error with
    | None -> Ok ()
    | Some error -> Error (Persistence_failed
        ("resolved marker primary retirement committed; settlement incomplete: " ^
          Fs_compat.private_jsonl_transaction_error_to_string error))

let with_resolution_terminal journal request_id f =
  match Async.with_canonical_durable_terminal ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id ~f:(fun proof ->
        let entry = Async.durable_terminal_entry proof in
        let* () = entry_matches_source journal.immutable_source entry
          |> Result.map_error (fun detail -> Invalid_source detail) in
        match entry.status with
        | Async.Waiting_for_dependencies _ | Lost _ -> f entry
        | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _ | Done _ ->
          Error (Invalid_result "explicit continuation resolution requires a waiting or lost physical owner")) with
  | Ok result -> result
  | Error error -> Error (Prior_owner_not_terminal
      {request_id;reason=Async.canonical_terminal_error_to_string error})

let resolution_version bytes snapshot entry =
  json_sha (`List [`String bytes; `String (marker_version snapshot); Async.entry_to_json entry])

let observe_resolution ~base_path ~keeper_name ~composition_run_id ~request_id = filesystem (fun () ->
  (* This loader can only observe or revoke future work. Missing dependency or
     artifact authority must not prevent an explicit revocation, and is never
     upgraded into replay permission. The journal and physical owner remain strict. *)
  let* journal = load_authority ~base_path ~keeper_name ~composition_run_id in
  with_resolution_terminal journal request_id (fun request ->
    let* _,snapshot = resolution_marker journal request_id in
    update_existing_with_bytes journal (fun bytes state -> None,
      let* () = match state.owner with
        | Some owner when String.equal owner.request_id request_id -> Ok ()
        | None | Some _ -> Error Ownership_changed in
      match state.resolution with
      | Some resolution -> Ok {request;version=resolution.expected_version;resolution=Some resolution}
      | None when Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor ->
        Error (Invalid_continuation_marker "unresolved owner has no pending marker")
      | None -> Ok {request;version=resolution_version bytes snapshot request;resolution=None})))

let resolve_continuation ~base_path ~keeper_name ~composition_run_id ~request_id
    ~expected_version ~decision ~requested_by ~reason ~now = filesystem (fun () ->
  let* () = if exact_name requested_by && nonblank reason && finite now && now >= 0.
    then Ok () else Error (Invalid_source "resolution requires an actor, reason and finite timestamp") in
  let* journal = load_authority ~base_path ~keeper_name ~composition_run_id in
  with_resolution_terminal journal request_id (fun request ->
    let* path,snapshot = resolution_marker journal request_id in
    let* resolution = update_existing_with_bytes journal (fun bytes state ->
      match state.owner with
      | None -> None, Error Ownership_changed
      | Some owner when not (String.equal owner.request_id request_id) -> None, Error Ownership_changed
      | Some owner ->
        match state.resolution with
        | Some resolution ->
          if String.equal resolution.expected_version expected_version
              && resolution.decision = decision && String.equal resolution.requested_by requested_by
              && String.equal resolution.reason reason
          then None, Ok resolution else None, Error Ownership_changed
        | None ->
          if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor
              || not (String.equal (resolution_version bytes snapshot request) expected_version)
          then None, Error Ownership_changed else
          let resolution = {owner;decision;requested_by;reason;resolved_at=now;
            expected_version;marker_version=marker_version snapshot} in
          Some (row (event "resolution" journal.source_sha
            ["resolution",resolution_to_json resolution])), Ok resolution) in
    (* The journal append has durably committed before marker retirement. Any
       interruption here leaves a terminal decision that a same-command retry
       or discovery can observe; it never reopens the original effect lane. *)
    let retirement_error = match retire_resolution_marker ~root:journal.root ~path ~snapshot resolution with
      | Ok () -> None | Error error -> Some error in
    Ok {resolution;marker_retired=Option.is_none retirement_error;retirement_error}))

let observe_request ~base_path ~composition_run_id (request_entry : Async.entry) = filesystem (fun () ->
  let* journal = load_authority ~base_path ~keeper_name:request_entry.keeper_name ~composition_run_id in
  let* () = if String.equal (Fs_compat.realpath request_entry.base_path) journal.base_path
    then Ok () else Error Source_conflict in
  let* () = entry_matches_source journal.immutable_source request_entry
    |> Result.map_error (fun detail -> Invalid_source detail) in
  let* observation = update_existing_with_bytes journal (fun bytes state -> None,
    let belongs (binding : binding) = String.equal binding.request_id request_entry.request_id in
    let* owner = match state.owner with
      | Some owner when belongs owner || List.exists (fun (prior,_) -> belongs prior) state.prior_owners -> Ok owner
      | None | Some _ -> Error Ownership_changed in
    Ok {journal;request_entry;observed_owner=owner;observed_resolution=state.resolution;
      journal_version=sha bytes;observed_at=Time_compat.now ()}) in
  let* () = match request_entry.status with
    | Async.Queued | Running | Cancelling _ ->
      (match Async.load_canonical_request ~base_path:journal.base_path
          ~caller:request_entry.keeper_name request_entry.request_id with
       | Found current when Async.same_entry_record current request_entry -> Ok ()
       | Found _ | Absent -> Error Ownership_changed
       | Unreadable detail -> Error (Invalid_result detail)
       | Rejected rejection -> Error (Invalid_result (Yojson.Safe.to_string (Async.access_rejection_to_json rejection))))
    | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
      let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
          ~caller:request_entry.keeper_name request_entry.request_id
        |> Result.map_error (fun error -> Prior_owner_not_terminal
            {request_id=request_entry.request_id;reason=Async.canonical_terminal_error_to_string error}) in
      if Async.same_entry_record request_entry (Async.durable_terminal_entry proof)
      then Ok () else Error Ownership_changed in
  let* () = match observation.observed_resolution with
    | None -> Ok ()
    | Some resolution -> with_resolution_terminal journal resolution.owner.request_id (fun _ -> Ok ()) in
  Ok observation)

let canonical_entry journal request_id =
  let* entry = match Async.load_canonical_request ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id with
    | Found entry -> Ok entry
    | Absent -> Error (Invalid_result "named journal owner request is absent")
    | Unreadable detail -> Error (Invalid_result detail)
    | Rejected rejection -> Error (Invalid_result (Yojson.Safe.to_string (Async.access_rejection_to_json rejection))) in
  let* () = entry_matches_source journal.immutable_source entry
    |> Result.map_error (fun detail -> Invalid_source detail) in
  Ok entry

let original_named_binding journal state =
  let* () = match journal.immutable_source.producer with
    | Named _ -> Ok () | Prepared -> Error (Invalid_source "prepared run has no named result binding") in
  let* owner = match List.rev state.prior_owners,state.owner with
    | (owner,_)::_,_ | [],Some owner -> Ok owner
    | [],None -> Error (Invalid_source "named run has no admitted original owner") in
  let* entry = canonical_entry journal owner.request_id in
  let* binding = match entry.request_context with
    | None -> Error (Invalid_source "named original source is missing")
    | Some fields -> Dependency.composition_of_request_context ~request_id:owner.request_id fields
        |> Result.map_error (fun detail -> Invalid_source detail) in
  let* () = Keeper_composition_named_run.validate ~base_path:journal.base_path
      ~keeper_name:journal.immutable_source.keeper_name binding
    |> Result.map_error (fun detail -> Invalid_source detail) in
  Ok binding

let named_admission journal = filesystem (fun () ->
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  match state.source.producer with
  | Prepared -> Error (Invalid_source "prepared run has no named admission")
  | Named _ ->
    match state.owner,state.prior_owners with
    | None,[] -> Ok None
    | (Some _ | None),_ -> original_named_binding journal state |> Result.map Option.some)

let named_binding journal =
  let* admission = named_admission journal in
  match admission with
  | Some binding -> Ok binding
  | None -> Error (Invalid_source "named run has no admitted original owner")

let resolved_named_result journal state (binding : Dependency.composition) =
  match state.resolution with
  | None -> Ok None
  | Some resolution ->
    let* original = original_named_binding journal state in
    let* () = if canonical_equal (Dependency.composition_to_json original) (Dependency.composition_to_json binding)
      then Ok () else Error (Invalid_source "resolved result differs from the original named binding") in
    with_resolution_terminal journal resolution.owner.request_id (fun entry ->
      Ok (Some (entry,resolution)))

let validate_nested_producer journal =
  match journal.immutable_source.producer with
  | Prepared | Named {origin=Standalone;_} -> Ok ()
  | Named {origin=Nested origin;activation;skill_reference;tool_name=_} ->
    let* bound = match activation with Some bound -> Ok bound
      | None -> Error (Invalid_source "nested producer has no sealed original recorder") in
    let* parent_tool_name,logical_parent,alias = match origin.activation.invocation with
      | Keeper_skill_activation_ledger.Nested_composition_invocation {tool_name;scope;_} ->
        Ok (tool_name,scope.parent_tool_use_id,scope.alias)
      | Instruction_invocation _ | Composition_invocation _ -> Error (Invalid_source "nested producer lost its original invocation") in
    let child : Keeper_skill_activation_recorder.result_child =
      {alias;skill_reference;skill_tool_use_id=origin.activation.skill_tool_use_id;
       activation_frame_sha256=Keeper_skill_activation_ledger.activation_frame_sha256 origin.activation} in
    Keeper_skill_activation_recorder.find_bound_result_children
      ~config:(Workspace.default_config journal.base_path) bound ~composition_run_id:origin.parent_run_id
      ~logical_parent_tool_use_id:logical_parent ~source_turn:journal.immutable_source.source_turn
      ~tool_name:parent_tool_name [child]
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun error -> Invalid_source (Keeper_skill_activation_recorder.error_to_string error))

type child_observation = Acceptance_recovery | Result_observation

let accepted_child_binding ~observation ~base_path (link : child_link) =
  let source = link.child_source in
  let* child = load ~base_path ~keeper_name:source.keeper_name ~composition_run_id:source.composition_run_id in
  let* () = if same_source source child.immutable_source then Ok () else Error Source_conflict in
  let* () = validate_nested_producer child in
  let* binding = named_binding child in
  let* () = if child_binding_matches link binding then Ok () else Error Source_conflict in
  let* original = canonical_entry child binding.request_id in
  let* () = match observation,original.status with
    | Acceptance_recovery,Async.Persistence_failed {attempted_status=Async.Acceptance_callback;_} ->
      Error (Invalid_result "original child acceptance callback failed")
    | Acceptance_recovery,Persistence_failed {attempted_status=State_transition _;_}
    | Result_observation,Persistence_failed _
    | (Acceptance_recovery | Result_observation),(Queued | Running | Cancelling _ | Waiting_for_dependencies _ | Done _ | Lost _ | Cancelled _) -> Ok () in
  Ok binding

let validate_child_links journal children nodes =
  Nodes.fold (fun key link prior ->
    let* () = prior in
    match link.accepted with
    | None -> Ok ()
    | Some expected ->
      let observation = match Nodes.find_opt key nodes with
        | Some (Settled (_,completed,_,_)) -> (match completed.result with
            | Tool_result.Completed _ -> Result_observation
            | Failed _ | Deferred _ -> Acceptance_recovery)
        | None | Some (Attempting _) -> Acceptance_recovery in
      let* actual = accepted_child_binding ~observation ~base_path:journal.base_path link in
      if canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json actual)
      then Ok () else Error Source_conflict) children (Ok ())

let nested_parent_accepted journal =
  match journal.immutable_source.producer with
  | Prepared | Named {origin=Standalone;_} -> Ok false
  | Named {origin=Nested origin;_} ->
    let* parent = load ~base_path:journal.base_path ~keeper_name:journal.immutable_source.keeper_name
        ~composition_run_id:origin.parent_run_id in
    let* state = strict_read ~root:parent.root parent.path in
    let* () = check_source parent state in
    match Nodes.find_opt (Plan.Node_id.to_string origin.parent_node_id) state.children with
    | Some link when same_source link.child_source journal.immutable_source ->
      (match link.accepted with
       | None -> Error (Invalid_result "original parent has not committed child acceptance")
       | Some expected ->
         let* actual = named_binding journal in
         if canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json actual)
         then Ok true else Error Source_conflict)
    | Some _ | None -> Error (Invalid_source "nested child has no original parent submission intent")

let bind_expected_owner journal ~request_id ~(expected : binding option) ~expected_terminal ~expected_nodes ~expected_children =
  let* () = match expected with
    | None -> Ok ()
    | Some prior when String.equal prior.request_id request_id -> Ok ()
    | Some prior ->
      (match Async.load_canonical_durable_terminal ~base_path:journal.base_path ~caller:journal.immutable_source.keeper_name prior.request_id with
       | Error error -> Error (Prior_owner_not_terminal {request_id = prior.request_id; reason = Async.canonical_terminal_error_to_string error})
       | Ok proof ->
         let entry = Async.durable_terminal_entry proof in
         if Option.fold ~none:false ~some:(fun expected -> not (Async.same_entry_record expected entry)) expected_terminal
         then Error Ownership_changed
         else Result.map_error (fun reason -> Prior_owner_not_terminal {request_id = prior.request_id; reason})
           (entry_matches_source journal.immutable_source entry)) in
  (* on_accepted holds the new request before its worker starts. Terminal
     publication is immutable. Only run ownership needs a CAS under this lock. *)
  let* () = canonical_queued journal request_id in
  update_existing journal (fun state ->
    if state.resolution <> None || not (same_owner state.owner expected)
        || Option.fold ~none:false ~some:(fun nodes -> nodes <> state.nodes) expected_nodes
        || Option.fold ~none:false ~some:(fun children -> not (same_children children state.children)) expected_children
    then None, Error Ownership_changed
    else match prepare_continuation_marker journal ~request_id with
      | Error error -> None, Error error
      | Ok () -> match state.owner with
      | Some binding when binding.request_id = request_id -> None, Ok {journal; binding}
      | prior ->
        let binding = {request_id; generation = (match prior with None -> 1 | Some prior -> prior.generation + 1)} in
        Some (row (event "binding" journal.source_sha ["expected_owner", option_json binding_json prior; "owner", binding_json binding])), Ok {journal; binding})

let bind_request journal ~request_id =
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = validate_nested_producer journal in
  let* () = canonical_queued journal request_id in
  let* expected = update_existing journal (fun state -> None, Ok state.owner) in
  match journal.immutable_source.producer,expected with
  | Named _,Some owner when not (String.equal owner.request_id request_id) ->
    Error (Invalid_source "named successor requires its sealed original continuation")
  | (Prepared | Named _),(None | Some _) ->
    bind_expected_owner journal ~request_id ~expected ~expected_terminal:None ~expected_nodes:None ~expected_children:None

let validate_predecessor_terminals (continuation : continuation) =
  let journal = continuation.journal in
  List.fold_left (fun prior (expected : Async.entry) ->
    let* () = prior in
    let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name expected.request_id
      |> Result.map_error (fun error -> Prior_owner_not_terminal
          {request_id=expected.request_id;reason=Async.canonical_terminal_error_to_string error}) in
    if Async.same_entry_record expected (Async.durable_terminal_entry proof) then Ok ()
    else Error Ownership_changed) (Ok ()) continuation.predecessor_terminals

let bind_continuation (continuation : continuation) ~request_id =
  let journal = continuation.journal in
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = validate_nested_producer journal in
  let* () = validate_child_links journal continuation.suspended_children continuation.suspended_nodes in
  let* _ = nested_parent_accepted journal in
  let* () = validate_predecessor_terminals continuation in
  let* () = canonical_queued journal request_id in
  bind_expected_owner journal ~request_id ~expected:(Some continuation.expected_owner)
    ~expected_terminal:(Some continuation.terminal_entry)
    ~expected_nodes:(Some continuation.suspended_nodes)
    ~expected_children:(Some continuation.suspended_children)

let continuation_base_path (continuation : continuation) = continuation.journal.base_path
let continuation_source (continuation : continuation) = source continuation.journal
let continuation_request_id (continuation : continuation) = continuation.expected_owner.request_id
let continuation_dependencies (continuation : continuation) = continuation.dependencies

type child_admission_history = Untouched_child | Admitted_child | Admission_unconfirmed

let nodes_child_admission nodes ~node_ids =
  List.fold_left (fun history id ->
    let current = match Nodes.find_opt (Plan.Node_id.to_string id) nodes with
      | None -> Untouched_child
      | Some (Attempting _) -> Admission_unconfirmed
      | Some (Settled (_,completed,effect_disposition,wait)) ->
        (match completed.result,effect_disposition,wait with
         | Tool_result.Completed _,_,_ | Tool_result.Deferred _,_,Some _
         | Tool_result.Failed _,Some Tool_result.Proven_post_effect,_ -> Admitted_child
         | Tool_result.Failed _,(None | Some Tool_result.Proven_pre_effect
             | Some Tool_result.Effect_outcome_unknown),_
         | Tool_result.Deferred _,_,None -> Admission_unconfirmed) in
    match history,current with
    | Admitted_child,_ | _,Admitted_child -> Admitted_child
    | Admission_unconfirmed,_ | _,Admission_unconfirmed -> Admission_unconfirmed
    | Untouched_child,Untouched_child -> Untouched_child) Untouched_child node_ids

let continuation_child_admission continuation ~node_ids =
  nodes_child_admission continuation.suspended_nodes ~node_ids

let child_admission journal ~node_ids =
  update_existing journal (fun state -> None, Ok (nodes_child_admission state.nodes ~node_ids))

let normalize_dependencies = Dependency.normalize

let exact_waiting_dependencies children ~expected_owner nodes dependencies =
  let* recorded = Nodes.fold (fun _ record prior ->
    let* ids = prior in
    match record with
    | Attempting _ ->
      Error (Invalid_result "waiting owner has an unsettled or non-result-wait journal node")
    | Settled (occurrence, completed, phase, job) ->
      let refuse () =
        Error (Invalid_result "waiting owner has an unsettled or non-result-wait journal node")
      in
      (match completed.result with
       | Tool_result.Completed _ ->
         (match job with None -> Ok ids | Some _ -> refuse ())
       | Tool_result.Failed _ -> refuse ()
       | Tool_result.Deferred _ ->
         (match job with
          | Some job_id when same_binding occurrence.owner expected_owner
              && valid_dependency_wait children occurrence completed.result phase job_id -> Ok (job_id :: ids)
          | None | Some _ -> refuse ()))) nodes (Ok []) in
  let recorded = normalize_dependencies recorded in
  if recorded = [] || recorded <> normalize_dependencies dependencies
  then Error (Invalid_result "canonical waiting dependencies differ from the current journal occurrences")
  else Ok recorded

let prior_result_wait journal children prior_owners =
  let rec read terminals = function
    | [] -> Ok None
    | ((prior : binding), nodes) :: rest ->
      let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
          ~caller:journal.immutable_source.keeper_name prior.request_id
        |> Result.map_error (fun error -> Prior_owner_not_terminal
            {request_id=prior.request_id;reason=Async.canonical_terminal_error_to_string error}) in
      let entry = Async.durable_terminal_entry proof in
      let* () = entry_matches_source journal.immutable_source entry
        |> Result.map_error (fun reason -> Prior_owner_not_terminal
            {request_id=prior.request_id;reason}) in
      match entry.status with
      | Async.Waiting_for_dependencies {dependencies;_} ->
        (match exact_waiting_dependencies children ~expected_owner:prior nodes dependencies with
         | Ok dependencies -> Ok (Some (dependencies,List.rev (entry :: terminals)))
         | Error error ->
           (* A no-dispatch successor may stop with the exact predecessor wait.
              Binding snapshots prove that it changed no node ownership or
              result; the canonical terminal proves the same waiting jobs. *)
           match rest with
           | (_,predecessor_nodes)::_ when nodes = predecessor_nodes ->
             let* original = read (entry :: terminals) rest in
             (match original with
              | Some (original_jobs,_) when original_jobs = normalize_dependencies dependencies -> Ok original
              | Some _ | None -> Error error)
           | _ -> Error error)
      | Lost _ -> read (entry :: terminals) rest
      | Cancelled _ | Persistence_failed _ | Done _ -> Ok None
      | Queued | Running | Cancelling _ ->
        Error (Prior_owner_not_terminal {request_id=prior.request_id;
          reason="predecessor terminal proof has an active status"})
  in read [] prior_owners

let launch_replay_proven occurrence =
  owned_job_launch occurrence && Option.is_some occurrence.launch_invocation

let recoverable_lost_nodes children nodes dependencies =
  let* recorded_jobs = Nodes.fold (fun _ record prior ->
    let* jobs = prior in
    let occurrence = occurrence_of_record record in
    let job = result_read_dependency children occurrence in
    let replay_proven = child_ack_proven children occurrence || match record with
      | Attempting occurrence -> occurrence.readonly || launch_replay_proven occurrence
      | Settled (occurrence, completed, phase, job) ->
        (match job with
         | Some job_id -> valid_dependency_wait children occurrence completed.result phase job_id
         | None ->
           (match completed.result with
            | Tool_result.Completed _ -> true
            | Tool_result.Deferred _ -> false
            | Tool_result.Failed _ ->
              (match phase with
               | Some Tool_result.Proven_pre_effect ->
                 occurrence.readonly || child_intent_proven children occurrence || launch_replay_proven occurrence
               | Some Tool_result.Effect_outcome_unknown -> launch_replay_proven occurrence
               | None | Some Tool_result.Proven_post_effect -> false))) in
    if not replay_proven then Error (Invalid_result
        "lost continuation has a deferred or unproven node that cannot replay")
    else Ok (Option.to_list job @ jobs)) nodes (Ok []) in
  let recorded_jobs = normalize_dependencies recorded_jobs in
  if List.for_all (fun job_id -> List.mem job_id recorded_jobs) dependencies then Ok ()
  else Error (Invalid_result "original waiting dependencies are absent from the lost journal")

let validate_lost_without_wait children expected_owner nodes =
  Nodes.fold (fun _ record prior ->
    let* () = prior in
    let occurrence = occurrence_of_record record in
    if child_ack_proven children occurrence then Ok () else match record with
    | Attempting occurrence when occurrence.readonly || launch_replay_proven occurrence -> Ok ()
    | Attempting _ -> Error (Replay_not_proven occurrence.node_id)
    | Settled _ -> replay_for children expected_owner occurrence.node_id (Some record)
        |> Result.map (fun _ -> ())) nodes (Ok ())

let waiting_continuation journal = filesystem (fun () ->
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  if state.resolution <> None then Ok None else
  let* () = validate_nested_producer journal in
  match state.owner with
  | None -> Ok None
  | Some expected_owner ->
    match Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name expected_owner.request_id with
    | Error (Async.Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) -> Ok None
    | Error ((Async.Canonical_terminal_absent | Canonical_terminal_unreadable _
             | Canonical_terminal_access_rejected _ | Canonical_terminal_publication_ambiguous _
             | Canonical_terminal_noncanonical_location _) as error) -> Error (Prior_owner_not_terminal
        {request_id=expected_owner.request_id;reason=Async.canonical_terminal_error_to_string error})
    | Ok proof ->
      let entry = Async.durable_terminal_entry proof in
      let* () = entry_matches_source journal.immutable_source entry
        |> Result.map_error (fun reason -> Prior_owner_not_terminal {request_id=expected_owner.request_id;reason}) in
      match entry.status with
      | Async.Waiting_for_dependencies {dependencies;_} ->
        let* () = validate_child_links journal state.children state.nodes in
        let* dependencies,predecessor_terminals =
          match exact_waiting_dependencies state.children ~expected_owner state.nodes dependencies with
          | Ok jobs -> Ok (jobs,[])
          | Error error ->
            (match state.prior_owners with
             | (_,predecessor_nodes)::_ when state.nodes = predecessor_nodes ->
               let* original = prior_result_wait journal state.children state.prior_owners in
               (match original with
                | Some (jobs,proofs) when jobs = normalize_dependencies dependencies ->
                  let* () = recoverable_lost_nodes state.children state.nodes jobs in
                  Ok (jobs,proofs)
                | Some _ | None -> Error error)
             | _ -> Error error) in
        Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals;
          suspended_nodes=state.nodes;suspended_children=state.children;dependencies})
      | Lost _ ->
        let* () = validate_child_links journal state.children state.nodes in
        let* original_wait = prior_result_wait journal state.children state.prior_owners in
        (match original_wait with
         | None ->
           (* No recorded wait is not proof of absent effects. Preserve the
              unresolved first owner before discovery considers retirement or
              a public resume falls back to ordinary request admission. *)
           let* () = validate_lost_without_wait state.children expected_owner state.nodes in
           let* child_admitted = nested_parent_accepted journal in
           let has_accepted_child = Nodes.exists (fun _ link -> Option.is_some link.accepted) state.children in
           let has_recheck_launch = Nodes.exists (fun _ record ->
             launch_replay_proven (occurrence_of_record record)) state.nodes in
           if child_admitted || has_accepted_child || has_recheck_launch then
             Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals=[];
               suspended_nodes=state.nodes;suspended_children=state.children;dependencies=[]})
           else Ok None
         | Some (dependencies,predecessor_terminals) ->
           let* () = recoverable_lost_nodes state.children state.nodes dependencies in
           Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals;
             suspended_nodes=state.nodes;suspended_children=state.children;dependencies}))
      | Queued | Running | Cancelling _ | Cancelled _
      | Persistence_failed _ | Done _ -> Ok None)

type read_composition_result =
  base_path:string -> keeper_name:string -> Dependency.composition -> (Dependency.readiness,string) result

type completion_disposition =
  | Canonical_completion
  | Recovery_pending
  | Unadmitted_attempt

let completion_disposition ~base_path (entry : Async.entry) = filesystem (fun () ->
  let fields = Option.value ~default:[] entry.request_context in
  let values name = List.filter_map (fun (key,value) ->
    if String.equal key name then Some value else None) fields in
  match values "draft_reference", values "run_artifact" with
  | [],[] ->
    if values "composition_tool" = [`String Keeper_tool_composition_catalog.run_tool_name]
    then Error (Invalid_source "prepared completion lacks its journal artifact envelope")
    else Ok Canonical_completion
  | [_],[_] ->
    let* composition_run_id = match values "composition_run_id" with
      | [`String identity] -> Plan.Composition_run_id.of_string identity
          |> Result.map_error (fun _ -> Invalid_source "completion has an invalid run identity")
      | [] | _::_ -> Error (Invalid_source "completion lacks its exact run identity") in
    let* journal = load ~base_path ~keeper_name:entry.keeper_name ~composition_run_id in
    let* () = if String.equal (Fs_compat.realpath entry.base_path) journal.base_path
      then Ok () else Error Source_conflict in
    let* () = entry_matches_source journal.immutable_source entry
      |> Result.map_error (fun detail -> Invalid_source detail) in
    let rec observe () =
      let* before = strict_read ~root:journal.root journal.path in
      let* () = check_source journal before in
      let belongs (binding : binding) = String.equal binding.request_id entry.request_id in
      let member = Option.exists belongs before.owner
        || List.exists (fun (binding,_) -> belongs binding) before.prior_owners in
      let* disposition = if not member then Ok Unadmitted_attempt else
        match entry.status with
        | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
        | Waiting_for_dependencies _ | Done _ -> Ok Canonical_completion
        | Lost _ ->
          match before.owner with
          | Some owner when not (belongs owner) -> Ok Recovery_pending
          | Some _ -> waiting_continuation journal |> Result.map (function
              | Some _ -> Recovery_pending | None -> Canonical_completion)
          | None -> Error Ownership_changed in
      let* after = strict_read ~root:journal.root journal.path in
      let* () = check_source journal after in
      if same_owner before.owner after.owner then Ok disposition else observe () in
    observe ()
  | ([],_::_) | (_::_,[]) | (_::_,_::_) ->
    Error (Invalid_source "completion has a partial or duplicate journal artifact envelope"))

let completion_pending ~base_path entry =
  completion_disposition ~base_path entry |> Result.map (function
    | Canonical_completion -> false
    | Recovery_pending | Unadmitted_attempt -> true)

let continuation_readiness ~read_composition_result (continuation : continuation) = filesystem (fun () ->
  let journal = continuation.journal in
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  if state.resolution <> None || not (same_owner state.owner (Some continuation.expected_owner))
      || state.nodes <> continuation.suspended_nodes
      || not (same_children state.children continuation.suspended_children) then Error Ownership_changed
  else
  let* () = validate_nested_producer journal in
  let* () = validate_child_links journal state.children state.nodes in
  let* _ = nested_parent_accepted journal in
  let* () = validate_predecessor_terminals continuation in
  let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name continuation.expected_owner.request_id
    |> Result.map_error (fun error -> Prior_owner_not_terminal
        {request_id=continuation.expected_owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
  if not (Async.same_entry_record continuation.terminal_entry (Async.durable_terminal_entry proof))
  then Error Ownership_changed
  else List.fold_left (fun prior dependency ->
    let* readiness = prior in
    let* ready = match dependency with
      | Dependency.Owned_job job_id ->
        let* record = Keeper_owned_job_store.load ~base_path:journal.base_path
            ~keeper_name:journal.immutable_source.keeper_name job_id
          |> Result.map_error (fun error -> Invalid_result (Keeper_owned_job_store.error_to_string error)) in
        Ok (Keeper_owned_job_store.result_ready record)
      | Dependency.Composition_result binding ->
        let* result = read_composition_result ~base_path:journal.base_path
            ~keeper_name:journal.immutable_source.keeper_name binding
          |> Result.map_error (fun detail -> Invalid_result detail) in
        Ok (result = Dependency.Ready) in
    match readiness, ready with
    | Results_ready, true -> Ok Results_ready
    | (Waiting_for_results | Results_ready), false
    | Waiting_for_results, true -> Ok Waiting_for_results)
      (Ok Results_ready) continuation.dependencies)

let named_result_owner_state journal binding = filesystem (fun () ->
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  let* original = original_named_binding journal state in
  let* () = if canonical_equal (Dependency.composition_to_json original) (Dependency.composition_to_json binding)
    then Ok () else Error (Invalid_source "result binding is not the original named owner") in
  let rec validate_prior = function
  | [] -> Ok ()
  | ((owner : binding),nodes)::older ->
    let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name owner.request_id
      |> Result.map_error (fun error -> Prior_owner_not_terminal
          {request_id=owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
    let entry = Async.durable_terminal_entry proof in
    let* () = entry_matches_source journal.immutable_source entry
      |> Result.map_error (fun detail -> Invalid_source detail) in
    let* () = match entry.status with
    | Waiting_for_dependencies {dependencies;_} ->
      (match exact_waiting_dependencies state.children ~expected_owner:owner nodes dependencies with
       | Ok _ -> Ok ()
       | Error error ->
         (* A successor that stops before dispatch can carry an unchanged
            predecessor's wait; its binding and canonical status stay explicit. *)
         match older with
         | (_,prior_nodes)::_ when nodes = prior_nodes ->
           let* inherited = prior_result_wait journal state.children older in
           (match inherited with
            | Some (original,_) when original = normalize_dependencies dependencies ->
              recoverable_lost_nodes state.children nodes original
            | Some _ | None -> Error error)
         | _ -> Error error)
    | Lost _ -> Ok ()
    | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _ | Done _ ->
      Error (Invalid_result "named successor has no resumable canonical predecessor") in
    validate_prior older in
  let* () = validate_prior state.prior_owners in
  let* owner = match state.owner with Some owner -> Ok owner | None -> Error Ownership_changed in
  let* entry = canonical_entry journal owner.request_id in
  let* () = match entry.status with
    | Queued | Running | Cancelling _ -> Ok ()
    | Waiting_for_dependencies _ | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
      let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
          ~caller:journal.immutable_source.keeper_name owner.request_id
        |> Result.map_error (fun error -> Prior_owner_not_terminal
            {request_id=owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
      if Async.same_entry_record entry (Async.durable_terminal_entry proof)
      then Ok () else Error Ownership_changed in
  let* current = strict_read ~root:journal.root journal.path in
  let* () = check_source journal current in
  if same_owner current.owner state.owner && current.prior_owners = state.prior_owners && current.nodes = state.nodes
  then Ok (entry,current) else Error Ownership_changed)

let named_result_owner journal binding = named_result_owner_state journal binding |> Result.map fst

let observe_named_result ~base_path ~keeper_name (binding : Dependency.composition) = filesystem (fun () ->
  let* journal,state = load_authority_state ~base_path ~keeper_name ~composition_run_id:binding.composition_run_id in
  let* resolved = resolved_named_result journal state binding in
  match resolved with
  | Some (entry,resolution) -> Ok (journal,entry,Some resolution)
  | None ->
    let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
    let* entry,state = named_result_owner_state journal binding in
    (* Reuse the owner reader's final source snapshot: a concurrent resolution
       must not be hidden by its physical waiting status. *)
    let* resolved = resolved_named_result journal state binding in
    match resolved with
    | Some (entry,resolution) -> Ok (journal,entry,Some resolution)
    | None -> Ok (journal,entry,None))

type pending_continuations =
  { inspected : int; ready : continuation list; waiting : int; retired : int
  ; failures : (string * error) list }
type discovery = Ready of continuation | Still_waiting | Retired | Lock_infrastructure

let continuation_data_name name =
  let suffix = ".json" in
  String.length name = 64 + String.length suffix && String.ends_with ~suffix name
  && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) (String.sub name 0 64)

let continuation_lock_data_name name =
  let suffix = ".lock" in
  if not (String.ends_with ~suffix name) then None else
  let data_name = String.sub name 0 (String.length name - String.length suffix) in
  if continuation_data_name data_name then Some data_name else None

let pending_continuations_with ~before_retire ~on_ready ~read_composition_result ~base_path =
  let* base_path = filesystem (fun () -> Ok (Fs_compat.realpath base_path)) in
  let root = Common.masc_dir_from_base_path ~base_path in
  let directory = continuation_directory ~base_path in
  let* names = filesystem (fun () ->
    let* inspection = Fs_compat.inspect_owned_directory_chain ~ownership_root:root directory
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.owned_directory_chain_rejection_to_string error)) in
    match inspection with
      | Fs_compat.Owned_directory_missing -> Ok []
      | Owned_directory _ -> Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
          ~ownership_root:root directory
          |> Result.map_error (fun error -> Persistence_failed
              (Fs_compat.owned_regular_file_read_error_to_string error))) in
  let inspect name = filesystem (fun () ->
    let path = Filename.concat directory name in
    match continuation_lock_data_name name with
    | Some data_name ->
      (* Retirement unlinks only the marker data file, leaving this lock
         sibling behind. An existence-only check skips those orphaned locks
         without acquiring or validating them, so each pass stays
         proportional to live markers, not to every historical request. *)
      let data_path = Filename.concat directory data_name in
      if Fs_compat.file_exists data_path then
        let* _ = continuation_snapshot ~root data_path in
        Ok Lock_infrastructure
      else Ok Lock_infrastructure
    | None when not (continuation_data_name name) ->
      Error (Invalid_continuation_marker "unexpected pending partition filename")
    | None ->
      let* snapshot = continuation_snapshot ~root path in
      if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok Retired
      else
        let* marker = decode_continuation_marker snapshot.bytes in
        if name <> continuation_filename marker.request_id
        then Error (Invalid_continuation_marker "marker filename does not bind its request") else
        let* journal = load_authority ~base_path ~keeper_name:marker.keeper_name
            ~composition_run_id:marker.composition_run_id in
        let* state = strict_read ~root journal.path in
        let* () = check_source journal state in
        let* () = match state.resolution with
          | Some _ -> Ok ()
          | None -> validate_artifacts ~base_path journal.immutable_source in
        match Async.load_canonical_durable_terminal ~base_path ~caller:marker.keeper_name marker.request_id with
        | Error (Async.Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) -> Ok Still_waiting
        | Error (Async.Canonical_terminal_absent | Async.Canonical_terminal_unreadable _
            | Async.Canonical_terminal_access_rejected _
            | Async.Canonical_terminal_publication_ambiguous _
            | Async.Canonical_terminal_noncanonical_location _ as error) ->
          Error (Prior_owner_not_terminal
            {request_id=marker.request_id;reason=Async.canonical_terminal_error_to_string error})
        | Ok proof ->
          let entry = Async.durable_terminal_entry proof in
          let* () = entry_matches_source journal.immutable_source entry
            |> Result.map_error (fun reason -> Invalid_continuation_marker reason) in
          let retire () =
            before_retire path;
            let* () = validate_owned_path ~root ~path ~create:true in
            let* receipt = Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_result path
                ~expected:snapshot
              |> Fs_compat.private_jsonl_cursor_success_receipt
              |> Result.map_error (fun error -> Persistence_failed
                  (Fs_compat.private_jsonl_transaction_error_to_string error)) in
            ignore (continuation_receipt path receipt); Ok Retired in
          match state.resolution with
          | Some resolution ->
            if not (String.equal resolution.owner.request_id marker.request_id)
            then Error (Invalid_continuation_marker "resolved owner differs from pending marker") else
            let () = before_retire path in
            let* () = retire_resolution_marker ~root ~path ~snapshot resolution in
            Ok Retired
          | None -> match state.owner with
          | None -> Error (Invalid_continuation_marker "request has no bound journal owner")
          | Some current when current.request_id <> marker.request_id -> retire ()
          | Some _ ->
            match entry.status with
            | Async.Waiting_for_dependencies _ | Lost _ ->
              let* candidate = waiting_continuation journal in
              (match candidate with
               | None when (match entry.status with
                   | Async.Lost _ -> true
                   | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
                   | Waiting_for_dependencies _ | Done _ -> false) -> retire ()
               | None -> Error Ownership_changed
               | Some continuation when continuation_request_id continuation <> marker.request_id -> Error Ownership_changed
               | Some continuation ->
                 let* readiness = continuation_readiness ~read_composition_result continuation in
                 match readiness with
                 | Waiting_for_results -> Ok Still_waiting
                 | Results_ready -> Ok (Ready continuation))
            | Cancelled _ | Persistence_failed _ | Done _ -> retire ()
            | Queued | Running | Cancelling _ -> Error (Invalid_continuation_marker "terminal proof has an active status")) in
  let empty = {inspected=0;ready=[];waiting=0;retired=0;failures=[]} in
  let report = List.fold_left (fun report name ->
    match inspect name with
    | Ok Lock_infrastructure -> report
    | Ok (Ready continuation) ->
      (* The original reads have returned and released their authority scopes.
         Scheduling exceptions are not journal/filesystem failures. *)
      on_ready continuation;
      let report = {report with inspected=report.inspected+1} in
      {report with ready=continuation :: report.ready}
    | Ok Still_waiting ->
      let report = {report with inspected=report.inspected+1} in
      {report with waiting=report.waiting+1}
    | Ok Retired ->
      let report = {report with inspected=report.inspected+1} in
      {report with retired=report.retired+1}
    (* Permanent Invalid_result retains its marker unless an explicit, durable
       owner-bound resolution seals this run and its exact marker snapshot.
       Missing authority never becomes retirement or replacement dispatch. *)
    | Error error ->
      let report = {report with inspected=report.inspected+1} in
      {report with failures=(name,error) :: report.failures}) empty names in
  Ok {report with ready=List.rev report.ready;failures=List.rev report.failures}

let discover_pending_continuations ~on_ready ~read_composition_result ~base_path =
  pending_continuations_with ~before_retire:(fun _ -> ()) ~on_ready ~read_composition_result ~base_path

let pending_continuations ~read_composition_result ~base_path =
  discover_pending_continuations ~on_ready:ignore ~read_composition_result ~base_path

module For_testing = struct
  let pending_continuations ~before_retire ~read_composition_result ~base_path =
    pending_continuations_with ~before_retire ~on_ready:ignore ~read_composition_result ~base_path
end

let check_worker (worker : worker) (state : state) =
  if state.resolution = None && same_owner state.owner (Some worker.binding) then Ok ()
  else Error Ownership_changed

let worker_child_admission (worker : worker) ~node_ids =
  update_existing worker.journal (fun state -> None,
    let* () = check_worker worker state in
    Ok (nodes_child_admission state.nodes ~node_ids))

let validate_source_plan journal ~plan =
  let* recorded = frozen_plan ~base_path:journal.base_path journal.immutable_source in
  let* actual = Keeper_tool_plan_request.to_yojson plan
    |> Result.map_error (fun _ -> Plan_identity_conflict) in
  if not (canonical_equal recorded actual) then Error Plan_identity_conflict
  else Ok ()

let validate_plan (worker : worker) ~plan =
  let* () = validate_source_plan worker.journal ~plan in
  update_existing worker.journal (fun state -> None, check_worker worker state)

let validate_refusal_completion (worker : worker) ~plan =
  let journal = worker.journal in
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = validate_nested_producer journal in
  let* () = validate_plan worker ~plan in
  let* children,nodes = update_existing journal (fun state -> None,
    let* () = check_worker worker state in Ok (state.children,state.nodes)) in
  let* () = validate_child_links journal children nodes in
  update_existing journal (fun state -> None, check_worker worker state)

let checked_node (worker : worker) state ~node_id ~tool_name ~input =
  let* () = check_worker worker state in
  let* () = Result.map_error (fun detail -> Invalid_result detail) (decode (fun () -> valid_json input; require (exact_name tool_name) "invalid tool name")) in
  let record = Nodes.find_opt (Plan.Node_id.to_string node_id) state.nodes in
  match record with
  | Some record when not (same_node_identity (occurrence_of_record record) ~node_id ~tool_name ~input) -> Error (Node_identity_conflict node_id)
  | _ -> Ok record

let check_attempt (attempt : attempt) state =
  let* () = check_worker attempt.worker state in
  match Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.nodes with
  | Some (Attempting current) when same_occurrence current attempt.occurrence -> Ok ()
  | None | Some (Attempting _ | Settled _) -> Error (Attempt_conflict attempt.occurrence.node_id)

let submission_operand (attempt : attempt) plan =
  match Plan.contract plan attempt.occurrence.node_id with
  | Some {target=Plan.Child_submission child;_} when not attempt.occurrence.readonly
      && String.equal attempt.occurrence.tool_name child.submission.tool_name -> Ok child
  | Some {target=(Plan.Child_arguments _ | Plan.Child_submission _ | Child_result _ | Descriptor_target _);_} | None ->
    Error (Node_identity_conflict attempt.occurrence.node_id)

let original_nested_context journal =
  let* run = read_manifest ~base_path:journal.base_path journal.immutable_source.run_reference in
  let* json = match run with
    | `Assoc fields -> (match List.assoc_opt "nested_activation" fields with
        | Some value -> Ok value | None -> Error (Invalid_source "original nested recorder is absent"))
    | _ -> Error (Invalid_source "original nested run is not an object") in
  Keeper_skill_activation_recorder.bound_context_of_yojson json
  |> Result.map_error (fun error -> Invalid_source (Keeper_skill_activation_recorder.error_to_string error))

let child_origin (attempt : attempt) ~plan ~activation =
  let journal = attempt.worker.journal in
  let* () = validate_plan attempt.worker ~plan in
  let* child = submission_operand attempt plan in
  let* () = update_existing journal (fun state -> None,check_attempt attempt state) in
  let* bound_plan = Plan.bind_child_plan ~input:attempt.occurrence.input child.child
    |> Result.map_error (fun error -> Invalid_source (Plan.child_binding_error_to_string error)) in
  let* bound = original_nested_context journal in
  let source = journal.immutable_source in
  let alias = Plan.child_alias child.child in
  let expected_id = Plan.Composition_run_id.child_tool_use_id source.composition_run_id
      ~parent_tool_use_id:source.parent_tool_use_id ~alias in
  let* () = if String.equal activation.Keeper_skill_activation_ledger.skill_tool_use_id expected_id
    then Ok () else Error (Invalid_source "child activation is not the original logical invocation") in
  let parent_tool = match source.producer with
    | Prepared -> Keeper_tool_composition_catalog.run_tool_name
    | Named {tool_name;_} -> tool_name in
  let expected : Keeper_skill_activation_recorder.result_child =
    {alias=Plan.Node_id.to_string alias;skill_reference=Plan.child_reference child.child;
     skill_tool_use_id=expected_id;
     activation_frame_sha256=Keeper_skill_activation_ledger.activation_frame_sha256 activation} in
  let* original = Keeper_skill_activation_recorder.find_bound_result_children
      ~config:(Workspace.default_config journal.base_path) bound ~composition_run_id:source.composition_run_id
      ~logical_parent_tool_use_id:(Plan.Composition_run_id.result_receipt_id source.composition_run_id)
      ~source_turn:source.source_turn ~tool_name:parent_tool [expected]
    |> Result.map_error (fun error -> Invalid_source (Keeper_skill_activation_recorder.error_to_string error)) in
  let* activation = match original with [activation] -> Ok activation
    | [] | _::_::_ -> Error (Invalid_source "original child activation is not unique") in
  Ok (Nested {parent_run_id=source.composition_run_id;parent_node_id=attempt.occurrence.node_id;
    parent_execution_id=attempt.occurrence.execution_id;
    parent_occurrence_tool_use_id=attempt.occurrence.tool_use_id;
    result_node_id=child.result.id;args=attempt.occurrence.input;activation},bound_plan)

let record_child_submission (attempt : attempt) ~plan ~child_source =
  let journal = attempt.worker.journal in
  let* child = submission_operand attempt plan in
  let* origin,context = match child_source.producer with
    | Named {origin=Nested origin;activation=Some context;_} -> Ok (origin,context)
    | Named {origin=Standalone;_} | Named {origin=Nested _;activation=None;_} | Prepared ->
      Error (Invalid_source "child source has no original Nested admission") in
  let* expected,bound_plan = child_origin attempt ~plan ~activation:origin.activation in
  let* bound = original_nested_context journal in
  let parent = journal.immutable_source in
  let* () = if canonical_equal (named_origin_to_yojson expected) (named_origin_to_yojson (Nested origin))
      && canonical_equal (Keeper_skill_activation_recorder.bound_context_to_yojson bound)
        (Keeper_skill_activation_recorder.bound_context_to_yojson context)
      && String.equal child_source.keeper_name parent.keeper_name
      && child_source.source_turn = parent.source_turn && child_source.source_task_id = parent.source_task_id
      && (match child_source.producer with
          | Named {tool_name;skill_reference;_} ->
            String.equal tool_name (Plan.child_tool_name child.child)
            && Skill_reference.equal skill_reference (Plan.child_reference child.child)
          | Prepared -> false)
    then Ok () else Error Source_conflict in
  let* child_journal = load ~base_path:journal.base_path ~keeper_name:child_source.keeper_name
      ~composition_run_id:child_source.composition_run_id in
  let* () = if same_source child_source child_journal.immutable_source then Ok () else Error Source_conflict in
  let* () = validate_source_plan child_journal ~plan:bound_plan in
  update_existing journal (fun state ->
    match check_attempt attempt state with
    | Error error -> None,Error error
    | Ok () ->
      let key = Plan.Node_id.to_string attempt.occurrence.node_id in
      match Nodes.find_opt key state.children with
      | Some link when same_source link.child_source child_source
          && Plan.Node_id.equal link.result_node_id child.result.id
          && Ids.Execution_id.equal link.occurrence.execution_id attempt.occurrence.execution_id
          && String.equal link.occurrence.tool_use_id attempt.occurrence.tool_use_id ->
        None,Ok {attempt;link}
      | Some _ -> None,Error Source_conflict
      | None ->
        let link = {occurrence=attempt.occurrence;result_node_id=child.result.id;child_source;accepted=None} in
        let event = event "child_intent" state.source_sha
          ["occurrence",occurrence_json link.occurrence;
           "result_node_id",`String (Plan.Node_id.to_string link.result_node_id);"child_source",source_json child_source] in
        Some (row event),Ok {attempt;link})

let accept_child_submission (submission : child_submission) ~request_id =
  let attempt = submission.attempt in
  let journal = attempt.worker.journal in
  let* binding = accepted_child_binding ~observation:Acceptance_recovery ~base_path:journal.base_path submission.link in
  let* () = if String.equal request_id binding.request_id then Ok () else Error Source_conflict in
  let* _ = Async.load_canonical_durable_queued ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id
    |> Result.map_error (fun error -> Queued_request_rejected (Async.canonical_queued_error_to_string error)) in
  update_existing journal (fun state ->
    match check_attempt attempt state with
    | Error error -> None,Error error
    | Ok () ->
      let key = Plan.Node_id.to_string attempt.occurrence.node_id in
      match Nodes.find_opt key state.children with
      | Some current when same_source current.child_source submission.link.child_source ->
        (match current.accepted with
         | Some prior when canonical_equal (Dependency.composition_to_json prior) (Dependency.composition_to_json binding) -> None,Ok ()
         | Some _ -> None,Error Source_conflict
         | None when child_occurrence_matches current attempt.occurrence ->
           Some (row (event "child_accepted" state.source_sha
             ["node_id",`String key;"binding",Dependency.composition_to_json binding])),Ok ()
         | None -> None,Error (Attempt_conflict attempt.occurrence.node_id))
      | Some _ | None -> None,Error Source_conflict)

let accepted_child_submission (submission : child_submission) =
  let attempt = submission.attempt in
  let journal = attempt.worker.journal in
  let read () = update_existing journal (fun state -> None,
    let* () = check_attempt attempt state in
    match Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.children with
    | Some link when same_source link.child_source submission.link.child_source ->
      (match link.accepted with
       | Some binding -> Ok binding
       | None -> Error (Invalid_result "parent has no committed original child acceptance"))
    | Some _ | None -> Error Source_conflict) in
  let* expected = read () in
  let* actual = accepted_child_binding ~observation:Acceptance_recovery
      ~base_path:journal.base_path submission.link in
  let* current = read () in
  if canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json actual)
      && canonical_equal (Dependency.composition_to_json expected) (Dependency.composition_to_json current)
  then Ok actual else Error Ownership_changed

let child_result_binding (attempt : attempt) ~plan =
  let journal = attempt.worker.journal in
  let* () = validate_plan attempt.worker ~plan in
  let* child = match Plan.contract plan attempt.occurrence.node_id with
    | Some {target=Plan.Child_result child;_} when attempt.occurrence.readonly
        && attempt.occurrence.input = `Assoc [] -> Ok child
    | Some {target=(Plan.Child_arguments _ | Plan.Child_submission _ | Child_result _ | Descriptor_target _);_} | None ->
      Error (Node_identity_conflict attempt.occurrence.node_id) in
  let* link = update_existing journal (fun state -> None,
    let* () = check_attempt attempt state in
    match Nodes.find_opt (Plan.Node_id.to_string child.submission.id) state.children with
    | Some link when Plan.Node_id.equal link.result_node_id child.result.id && Option.is_some link.accepted -> Ok link
    | Some _ | None -> Error (Invalid_result "native result has no accepted original child")) in
  let* binding = accepted_child_binding ~observation:Result_observation ~base_path:journal.base_path link in
  let* () = update_existing journal (fun state -> None,
    let* () = check_attempt attempt state in
    match Nodes.find_opt (Plan.Node_id.to_string child.submission.id) state.children with
    | Some current when child_link_json current = child_link_json link -> Ok ()
    | Some _ | None -> Error Ownership_changed) in
  Ok binding

let lookup (worker : worker) ~node_id ~tool_name ~input =
  update_existing worker.journal (fun state -> None,
    let* record = checked_node worker state ~node_id ~tool_name ~input in replay_for state.children worker.binding node_id record)

let launch_recheck (worker : worker) ~node_id ~tool_name ~input ~execution_id ~tool_use_id =
  update_existing worker.journal (fun state -> None,
    let* () = check_worker worker state in
    match Nodes.find_opt (Plan.Node_id.to_string node_id) state.nodes with
    | None -> Error (Node_identity_conflict node_id)
    | Some record ->
      let occurrence = occurrence_of_record record in
      if not (same_node_identity occurrence ~node_id ~tool_name ~input
          && Ids.Execution_id.equal occurrence.execution_id execution_id
          && String.equal occurrence.tool_use_id tool_use_id
          && owned_job_launch occurrence)
      then Error (Node_identity_conflict node_id) else
      let* record = checked_node worker state ~node_id ~tool_name ~input in
      let* replay = replay_for state.children worker.binding node_id record in
      match replay with
      | Recheck_launch original -> Ok (Some original)
      | Dispatch | Reuse_completed _ -> Ok None
      | Recheck_result _ | Recheck_child_submission _ -> Error (Node_identity_conflict node_id))

let begin_attempt (worker : worker) ~node_id ~tool_name ~input ~execution_id ~tool_use_id ~readonly ?launch_invocation () =
  update_existing worker.journal (fun state ->
    let decision =
      let* record = checked_node worker state ~node_id ~tool_name ~input in
      let* replay = replay_for state.children worker.binding node_id record in
      match replay with
      | Reuse_completed _ -> Error (Attempt_conflict node_id)
      | Dispatch | Recheck_result _ | Recheck_launch _ | Recheck_child_submission _ ->
        let* () = match replay with
          | Recheck_result stored when not readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id -> Error (Attempt_conflict node_id)
          | Recheck_launch stored when readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id
              || launch_invocation <> Some stored.invocation -> Error (Attempt_conflict node_id)
          | Recheck_child_submission stored when readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id -> Error (Attempt_conflict node_id)
          | Dispatch | Reuse_completed _ | Recheck_result _
          | Recheck_launch _ | Recheck_child_submission _ -> Ok () in
        if not (exact_name tool_use_id && exact_name (Ids.Execution_id.to_string execution_id)) then Error (Invalid_result "invalid execution occurrence") else
        let sequence = match record with None -> 1 | Some record -> (occurrence_of_record record).sequence + 1 in
        let launch_mode = match replay with Recheck_launch _ -> Existing_only
          | Dispatch | Reuse_completed _ | Recheck_result _ | Recheck_child_submission _ -> Initial_launch in
        Ok {node_id; tool_name; input; input_sha = json_sha input; owner = worker.binding; sequence;
          execution_id; tool_use_id; readonly; launch_invocation; launch_mode} in
    match decision with
    | Error error -> None, Error error
    | Ok occurrence -> Some (row (attempt_event worker.journal.source_sha occurrence)), Ok {worker; occurrence})

let settle_attempt ?failure_effect_disposition ?deferred_kind attempt ~result ~result_bytes ~truncated_to =
  let completed = {execution_id = attempt.occurrence.execution_id; tool_use_id = attempt.occurrence.tool_use_id; result; result_bytes; truncated_to} in
  let phase = match failure_effect_disposition, result with
    | Some phase, _ -> Some phase
    | None, Tool_result.Failed failure -> Some failure.effect_disposition
    | None, (Tool_result.Completed _ | Deferred _) -> None in
  let dependency_wait = match deferred_kind with
    | Some (Keeper_tool_execution.Owned_job_result_wait job_id) -> Some (Dependency.Owned_job job_id)
    | Some (Keeper_tool_execution.Composition_result_wait binding) -> Some (Dependency.Composition_result binding)
    | None | Some (Generic_deferred | External_effect_deferred _) -> None in
  let* encoded = Result.map_error (fun detail -> Invalid_result detail) (decode (fun () ->
    require (result_bytes >= 0 && Option.fold ~none:true ~some:(fun value -> value >= 0) truncated_to) "negative result size";
    require (String.equal (Tool_result.tool_name result) attempt.occurrence.tool_name) "result tool mismatch";
    let encoded = completed_json completed in valid_json encoded;
    let decoded = completed_of_json (Yojson.Safe.from_string (Yojson.Safe.to_string encoded)) in
    require (decoded.result = result) "strict durable result codec did not preserve complete payload";
    encoded)) in
  update_existing attempt.worker.journal (fun state ->
    let valid =
      let* () = check_worker attempt.worker state in
      decode (fun () -> Option.iter (fun job_id -> require
        (valid_dependency_wait state.children attempt.occurrence result phase job_id)
        "dependency wait does not match the exact read-only result leaf") dependency_wait)
      |> Result.map_error (fun detail -> Invalid_result detail) in
    match valid with
    | Error error -> None, Error error
    | Ok () ->
      let record = Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.nodes in
      match record with
      | Some (Attempting current) when same_occurrence current attempt.occurrence ->
        let json = event "settled" state.source_sha ["occurrence", occurrence_json current; "completed", encoded;
          "failure_effect_disposition", option_json effect_json phase; "dependency_wait", dependency_wait_json dependency_wait] in
        Some (row json), Ok ()
      | Some (Settled (current, prior, prior_phase, prior_wait)) when same_occurrence current attempt.occurrence
          && completed_json prior = encoded && prior_phase = phase && prior_wait = dependency_wait -> None, Ok ()
      | Some (Attempting _ | Settled _) | None -> None, Error (Attempt_conflict attempt.occurrence.node_id))
