(* One append authority for an immutable prepared source, its async owners and
   node occurrences. Kept below the existing durable async consumer tree so the
   full typed results retain their artifact roots independently of transcripts. *)
module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Nodes = Map.Make (String)

let ( let* ) = Result.bind

type source =
  { keeper_name : string
  ; composition_run_id : Plan.Composition_run_id.t
  ; draft_reference : Tool_output.artifact_ref
  ; run_reference : Tool_output.artifact_ref
  ; parent_tool_use_id : string
  ; source_turn : int
  ; source_task_id : string option
  }

type completed =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; result : Tool_result.result
  ; result_bytes : int
  ; truncated_to : int option
  }

type recheck = { execution_id : Ids.Execution_id.t; tool_use_id : string }
type launch_invocation = { trace_id : string; turn_ref : Ids.Turn_ref.t }
type recheck_launch =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; invocation : launch_invocation
  }
type replay =
  | Dispatch
  | Reuse_completed of completed
  | Recheck_job_result of recheck
  | Recheck_launch of recheck_launch

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

let source_json (source : source) =
  `Assoc ["keeper_name", `String source.keeper_name;
    "composition_run_id", `String (Plan.Composition_run_id.to_string source.composition_run_id);
    "draft_reference", reference_json source.draft_reference;
    "run_reference", reference_json source.run_reference;
    "parent_tool_use_id", `String source.parent_tool_use_id;
    "source_turn", `Int source.source_turn;
    "source_task_id", option_json (fun value -> `String value) source.source_task_id]

let validate_source source =
  require (exact_name source.keeper_name) "invalid keeper name";
  require (exact_name source.parent_tool_use_id) "invalid parent tool-use identity";
  require (source.source_turn >= 0) "negative source turn";
  Option.iter (fun task -> require (exact_name task) "invalid source task identity") source.source_task_id;
  match Plan.Composition_run_id.of_string (Plan.Composition_run_id.to_string source.composition_run_id) with
  | Ok _ -> ()
  | Error _ -> refuse "invalid UUIDv7 composition run identity"

let source_of_json json =
  let fields = object_fields ["keeper_name"; "composition_run_id"; "draft_reference"; "run_reference"; "parent_tool_use_id"; "source_turn"; "source_task_id"] json in
  let composition_run_id = match Plan.Composition_run_id.of_string (string (field "composition_run_id" fields)) with
    | Ok id -> id | Error _ -> refuse "invalid UUIDv7 composition run identity" in
  let source = {keeper_name = string (field "keeper_name" fields); composition_run_id;
    draft_reference = reference_of_json (field "draft_reference" fields);
    run_reference = reference_of_json (field "run_reference" fields);
    parent_tool_use_id = string (field "parent_tool_use_id" fields);
    source_turn = nonnegative (field "source_turn" fields);
    source_task_id = optional string (field "source_task_id" fields)} in
  validate_source source; source

(* Checkpoint's strict codec owns content variants and failure provenance. Its
   wire codec deliberately omits ToolResult.json, so this typed sidecar retains
   that optional value and recursively restores nested result blocks. *)
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
type occurrence =
  { node_id : Plan.Node_id.t; tool_name : string; input : Yojson.Safe.t;
    input_sha : string; owner : binding; sequence : int;
    execution_id : Ids.Execution_id.t; tool_use_id : string; readonly : bool;
    launch_invocation : launch_invocation option }
type node_record =
  | Attempting of occurrence
  | Settled of occurrence * completed * Tool_result.failure_effect_disposition option
      * Keeper_owned_job_store.Job_id.t option
type state =
  { source : source; source_sha : string; owner : binding option
  ; prior_owners : (binding * node_record Nodes.t) list; nodes : node_record Nodes.t }
type t = {base_path : string; root : string; path : string; immutable_source : source; source_sha : string}
type worker = {journal : t; binding : binding}
type attempt = {worker : worker; occurrence : occurrence}
type continuation =
  { journal : t; expected_owner : binding
  ; terminal_entry : Async.entry
  ; predecessor_terminals : Async.entry list
  ; suspended_nodes : node_record Nodes.t
  ; job_ids : Keeper_owned_job_identity.Job_id.t list }
type readiness = Waiting_for_results | Results_ready

let binding_json binding = `Assoc ["request_id", `String binding.request_id; "generation", `Int binding.generation]
let binding_of_json json =
  let fields = object_fields ["request_id"; "generation"] json in
  let request_id = string (field "request_id" fields) and generation = integer (field "generation" fields) in
  require (exact_name request_id && generation > 0) "invalid worker binding";
  {request_id; generation}
let same_binding a b = String.equal a.request_id b.request_id && a.generation = b.generation
let same_owner a b = match a, b with None, None -> true | Some a, Some b -> same_binding a b | _ -> false
let occurrence_of_record = function Attempting occurrence | Settled (occurrence, _, _, _) -> occurrence
let launch_invocation_json invocation =
  `Assoc ["trace_id", `String invocation.trace_id; "turn_ref", `String (Ids.Turn_ref.to_string invocation.turn_ref)]
let launch_invocation_of_json json =
  let fields = object_fields ["trace_id"; "turn_ref"] json in
  let trace_id = string (field "trace_id" fields) in
  match Ids.Turn_ref.of_string (string (field "turn_ref" fields)) with
  | Some turn_ref when exact_name trace_id -> {trace_id; turn_ref}
  | Some _ | None -> refuse "invalid launch invocation identity"
let occurrence_json occurrence =
  `Assoc ["node_id", `String (Plan.Node_id.to_string occurrence.node_id); "tool_name", `String occurrence.tool_name;
    "input", occurrence.input; "input_sha", `String occurrence.input_sha; "owner", binding_json occurrence.owner;
    "sequence", `Int occurrence.sequence; "execution_id", Ids.Execution_id.to_yojson occurrence.execution_id;
    "tool_use_id", `String occurrence.tool_use_id; "readonly", `Bool occurrence.readonly;
    "launch_invocation", option_json launch_invocation_json occurrence.launch_invocation]
let occurrence_of_json json =
  let fields = object_fields ["node_id"; "tool_name"; "input"; "input_sha"; "owner"; "sequence"; "execution_id"; "tool_use_id"; "readonly"; "launch_invocation"] json in
  let node_id = match Plan.Node_id.make (string (field "node_id" fields)) with Ok id -> id | Error _ -> refuse "invalid node identity" in
  let execution_id = match Ids.Execution_id.of_yojson (field "execution_id" fields) with Ok id -> id | Error detail -> refuse detail in
  let occurrence = {node_id; execution_id; tool_name = string (field "tool_name" fields);
    input = field "input" fields; input_sha = string (field "input_sha" fields);
    owner = binding_of_json (field "owner" fields); sequence = integer (field "sequence" fields);
    tool_use_id = string (field "tool_use_id" fields); readonly = bool (field "readonly" fields);
    launch_invocation = optional launch_invocation_of_json (field "launch_invocation" fields)} in
  require (exact_name occurrence.tool_name && exact_name occurrence.tool_use_id
    && exact_name (Ids.Execution_id.to_string execution_id) && occurrence.sequence > 0) "invalid occurrence identity";
  require (String.equal occurrence.input_sha (json_sha occurrence.input)) "input fingerprint mismatch";
  occurrence
let same_occurrence a b = occurrence_json a = occurrence_json b
let same_node_identity occurrence ~node_id ~tool_name ~input =
  Plan.Node_id.equal occurrence.node_id node_id && String.equal occurrence.tool_name tool_name
  && occurrence.input = input && String.equal occurrence.input_sha (json_sha input)

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

let event kind source_sha fields = `Assoc (["schema", `Int 1; "kind", `String kind; "source_sha", `String source_sha] @ fields)
let row json = Yojson.Safe.to_string json ^ "\n"
let source_event source = event "source" (json_sha (source_json source)) ["source", source_json source]
let attempt_event source_sha occurrence = event "attempting" source_sha ["occurrence", occurrence_json occurrence]

let job_wait_json = option_json (fun job_id -> `String (Keeper_owned_job_store.Job_id.to_string job_id))
let job_wait_of_json = optional (fun json ->
  match Keeper_owned_job_store.Job_id.of_string (string json) with
  | Ok job_id -> job_id | Error detail -> refuse detail)

let result_read_job (occurrence : occurrence) =
  let readonly_action = match Tool_schemas_owned_job.find_definition occurrence.tool_name with
    | Some {action=Tool_schemas_owned_job.Read_result;read_only;_} -> read_only
    | Some {action=(Start | Status | Cancel);_} | None -> false in
  if not (occurrence.readonly && readonly_action) then None
  else match occurrence.input with
    | `Assoc ["job_id", `String id] ->
        (match Keeper_owned_job_store.Job_id.of_string id with Ok job_id -> Some job_id | Error _ -> None)
    | _ -> None

let valid_job_wait occurrence result phase job_id =
  result_read_job occurrence = Some job_id
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

let replay_for binding node_id = function
  | None -> Ok Dispatch
  | Some (Settled (_, ({result = Tool_result.Completed _; _} as completed), _, _)) -> Ok (Reuse_completed completed)
  | Some (Settled (occurrence, completed, phase, Some job_id))
      when valid_job_wait occurrence completed.result phase job_id ->
      Ok (Recheck_job_result {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
  | Some (Settled (occurrence, {result = Tool_result.Failed _; _}, Some Tool_result.Proven_pre_effect, _)) ->
      (match result_read_job occurrence with
       | Some _ -> Ok (Recheck_job_result {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
       | None -> Ok Dispatch)
  | Some (Attempting occurrence) when occurrence.readonly && not (same_binding occurrence.owner binding) ->
      (match result_read_job occurrence with
       | Some _ -> Ok (Recheck_job_result {execution_id=occurrence.execution_id;tool_use_id=occurrence.tool_use_id})
       | None -> Ok Dispatch)
  | Some (Attempting occurrence) when owned_job_launch occurrence ->
      (match recheck_launch_for occurrence with
       | Some replay -> Ok (Recheck_launch replay)
       | None -> Error (Replay_not_proven node_id))
  | Some (Settled (occurrence, {result = Tool_result.Failed _; _}, Some Tool_result.Effect_outcome_unknown, _))
      when owned_job_launch occurrence ->
      (match recheck_launch_for occurrence with
       | Some replay -> Ok (Recheck_launch replay)
       | None -> Error (Replay_not_proven node_id))
  | Some (Attempting _)
  | Some (Settled (_, {result=(Tool_result.Deferred _ | Tool_result.Failed _);_},
      (Some (Tool_result.Proven_pre_effect | Tool_result.Proven_post_effect
        | Tool_result.Effect_outcome_unknown) | None), _)) ->
      Error (Replay_not_proven node_id)

let decode_state bytes = decode (fun () ->
  require (bytes <> "" && bytes.[String.length bytes - 1] = '\n') "missing or incomplete journal identity";
  let lines = String.split_on_char '\n' bytes in
  let lines = match List.rev lines with "" :: rest -> List.rev rest | _ -> refuse "incomplete journal" in
  let jsons = List.mapi (fun index line ->
    require (String.trim line <> "") (Printf.sprintf "blank journal row %d" (index + 1));
    let json = Yojson.Safe.from_string line in valid_json json; json) lines in
  let header, events = match jsons with header :: events -> header, events | [] -> refuse "missing source header" in
  let fields = object_fields ["schema"; "kind"; "source_sha"; "source"] header in
  require (field "schema" fields = `Int 1 && field "kind" fields = `String "source") "invalid source header schema";
  let source = source_of_json (field "source" fields) in
  let source_sha = string (field "source_sha" fields) in
  require (String.equal source_sha (json_sha (source_json source))) "source fingerprint mismatch";
  List.fold_left (fun state json ->
    let kind = match json with `Assoc fields -> string (field "kind" fields) | _ -> refuse "invalid journal row" in
    let extras = match kind with
      | "binding" -> ["expected_owner"; "owner"]
      | "attempting" -> ["occurrence"]
      | "settled" -> ["occurrence"; "completed"; "failure_effect_disposition"; "owned_job_wait"]
      | _ -> refuse "unknown journal event" in
    let fields = object_fields (["schema"; "kind"; "source_sha"] @ extras) json in
    require (field "schema" fields = `Int 1 && field "source_sha" fields = `String source_sha) "event source/schema mismatch";
    match kind with
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
        require (match replay_for occurrence.owner occurrence.node_id prior with
          | Ok Dispatch -> true
          | Ok (Recheck_job_result stored) -> occurrence.readonly
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
          | Ok (Recheck_launch stored) -> owned_job_launch occurrence
              && Ids.Execution_id.equal occurrence.execution_id stored.execution_id
              && occurrence.tool_use_id = stored.tool_use_id
              && occurrence.launch_invocation = Some stored.invocation
          | Ok (Reuse_completed _) | Error _ -> false) "unproven replay event";
        Attempting occurrence)
      else (
        require (match prior with Some (Attempting current) -> same_occurrence current occurrence
                | Some (Settled _) | None -> false) "settlement without exact attempt";
        let completed = completed_of_json (field "completed" fields) in
        require (Ids.Execution_id.equal completed.execution_id occurrence.execution_id && completed.tool_use_id = occurrence.tool_use_id
          && String.equal (Tool_result.tool_name completed.result) occurrence.tool_name) "settlement identity mismatch";
        let phase = optional effect_of_json (field "failure_effect_disposition" fields) in
        let job_wait = job_wait_of_json (field "owned_job_wait" fields) in
        Option.iter (fun job_id -> require (valid_job_wait occurrence completed.result phase job_id)
          "owned job wait does not match the exact read-only result leaf") job_wait;
        Settled (occurrence, completed, phase, job_wait)) in
      {state with nodes = Nodes.add key record state.nodes}
    | _ -> refuse "unknown journal event")
    {source; source_sha; owner = None; prior_owners = []; nodes = Nodes.empty} events)

let source journal = journal.immutable_source
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

let update_existing journal decide = filesystem (fun () ->
  let* () = validate_owned_path ~root:journal.root ~path:journal.path ~create:false in
  let callback bytes =
    match validate_owned_path ~root:journal.root ~path:journal.path ~create:false with
    | Error error -> None, Error error
    | Ok () ->
      match Result.map_error (fun detail -> Corrupt_journal detail) (decode_state bytes) with
      | Error error -> None, Error error
      | Ok state -> match check_source journal state with Error error -> None, Error error | Ok () -> decide state in
  let unpack = function None -> Error Missing_journal | Some result -> result in
  match Fs_compat.update_existing_private_file_durable_locked_result journal.path callback with
  | Fs_compat.Private_file_succeeded value -> unpack value
  | Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} ->
    cleanup_warning journal.path cleanup_failure; unpack value
  | Private_file_failed error -> Error (Persistence_failed (Fs_compat.private_jsonl_transaction_error_to_string error))
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
    Error (Persistence_failed (Fs_compat.private_jsonl_transaction_error_to_string error ^ "; cleanup=" ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let prepare ~base_path immutable_source = filesystem (fun () ->
  let* () = Result.map_error (fun detail -> Invalid_source detail) (decode (fun () -> validate_source immutable_source)) in
  let base_path = Fs_compat.realpath base_path in
  let* () = validate_artifacts ~base_path immutable_source in
  let root, path = path_for ~base_path ~keeper_name:immutable_source.keeper_name ~composition_run_id:immutable_source.composition_run_id in
  let journal = {base_path; root; path; immutable_source; source_sha = json_sha (source_json immutable_source)} in
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
    | Ok state -> let* () = check_source journal state in Ok false in
  let callback bytes =
    match validate_owned_path ~root ~path ~create:false with
    | Error error -> None, Error error
    | Ok () ->
      if bytes = "" && absent then Some (row (source_event immutable_source)), Ok journal
      else match Result.map_error (fun detail -> Corrupt_journal detail) (decode_state bytes) with
        | Error error -> None, Error error
        | Ok state -> None, Result.map (fun () -> journal) (check_source journal state) in
  match Fs_compat.update_private_file_durable_locked_result path callback with
  | Fs_compat.Private_file_succeeded value -> value
  | Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} -> cleanup_warning path cleanup_failure; value
  | Private_file_failed error -> Error (Persistence_failed (Fs_compat.durable_append_error_to_string error))
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
    Error (Persistence_failed (Fs_compat.durable_append_error_to_string error ^ "; cleanup=" ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let load ~base_path ~keeper_name ~composition_run_id = filesystem (fun () ->
  if not (exact_name keeper_name) then Error (Invalid_source "invalid keeper name") else
  let base_path = Fs_compat.realpath base_path in
  let root, path = path_for ~base_path ~keeper_name ~composition_run_id in
  let* state = strict_read ~root path in
  if not (String.equal state.source.keeper_name keeper_name && Plan.Composition_run_id.equal state.source.composition_run_id composition_run_id)
  then Error Source_conflict else
  let* () = validate_artifacts ~base_path state.source in
  Ok {base_path; root; path; immutable_source = state.source; source_sha = state.source_sha})

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
  require (unique "parent_tool_use_id" = `String source.parent_tool_use_id && unique "source_turn" = `Int source.source_turn) "original invocation mismatch";
  let task_fields = List.filter_map (fun (name, value) -> if name = "source_task_id" then Some value else None) fields in
  require (task_fields = (match source.source_task_id with None -> [] | Some task -> [`String task])) "source task identity mismatch")

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

let bind_expected_owner journal ~request_id ~(expected : binding option) ~expected_terminal ~expected_nodes =
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
  let* () = prepare_continuation_marker journal ~request_id in
  update_existing journal (fun state ->
    if not (same_owner state.owner expected)
        || Option.fold ~none:false ~some:(fun nodes -> nodes <> state.nodes) expected_nodes
    then None, Error Ownership_changed
    else match state.owner with
      | Some binding when binding.request_id = request_id -> None, Ok {journal; binding}
      | prior ->
        let binding = {request_id; generation = (match prior with None -> 1 | Some prior -> prior.generation + 1)} in
        Some (row (event "binding" journal.source_sha ["expected_owner", option_json binding_json prior; "owner", binding_json binding])), Ok {journal; binding})

let bind_request journal ~request_id =
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* () = canonical_queued journal request_id in
  let* expected = update_existing journal (fun state -> None, Ok state.owner) in
  bind_expected_owner journal ~request_id ~expected ~expected_terminal:None ~expected_nodes:None

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
  let* () = validate_predecessor_terminals continuation in
  let* () = canonical_queued journal request_id in
  bind_expected_owner journal ~request_id ~expected:(Some continuation.expected_owner)
    ~expected_terminal:(Some continuation.terminal_entry)
    ~expected_nodes:(Some continuation.suspended_nodes)

let continuation_base_path (continuation : continuation) = continuation.journal.base_path
let continuation_source (continuation : continuation) = source continuation.journal
let continuation_request_id (continuation : continuation) = continuation.expected_owner.request_id
let continuation_job_ids (continuation : continuation) = continuation.job_ids

type child_admission_history = Untouched_child | Admitted_child | Admission_unconfirmed

let continuation_child_admission continuation ~node_ids =
  List.fold_left (fun history id ->
    let current = match Nodes.find_opt (Plan.Node_id.to_string id) continuation.suspended_nodes with
      | None -> Untouched_child
      | Some (Attempting _) -> Admission_unconfirmed
      | Some (Settled (_,completed,effect_disposition,wait)) ->
        (match completed.result,effect_disposition,wait with
         | Tool_result.Completed _,_,_ | Tool_result.Deferred _,_,Some _ -> Admitted_child
         | Tool_result.Failed _,Some Tool_result.Proven_pre_effect,_ -> Untouched_child
         | Tool_result.Failed _,(None | Some Tool_result.Effect_outcome_unknown),_
         | Tool_result.Deferred _,_,None -> Admission_unconfirmed) in
    match history,current with
    | Admitted_child,_ | _,Admitted_child -> Admitted_child
    | Admission_unconfirmed,_ | _,Admission_unconfirmed -> Admission_unconfirmed
    | Untouched_child,Untouched_child -> Untouched_child) Untouched_child node_ids

let normalize_job_ids = List.sort_uniq (fun left right ->
  String.compare (Keeper_owned_job_identity.Job_id.to_string left)
    (Keeper_owned_job_identity.Job_id.to_string right))

let exact_waiting_jobs ~expected_owner nodes job_ids =
  let* recorded = Nodes.fold (fun _ record prior ->
    let* ids = prior in
    match record with
    | Settled (_, {result=Tool_result.Completed _;_}, _, None) -> Ok ids
    | Settled (occurrence, completed, phase, Some job_id)
        when same_binding occurrence.owner expected_owner
          && valid_job_wait occurrence completed.result phase job_id -> Ok (job_id :: ids)
    | Attempting _
    | Settled (_, {result=(Tool_result.Completed _ | Tool_result.Deferred _ | Tool_result.Failed _);_}, _, _) ->
      Error (Invalid_result "waiting owner has an unsettled or non-job-wait journal node")) nodes (Ok []) in
  let recorded = normalize_job_ids recorded in
  if recorded = [] || recorded <> normalize_job_ids job_ids
  then Error (Invalid_result "canonical waiting jobs differ from the current journal occurrences")
  else Ok recorded

let prior_owned_job_wait journal prior_owners =
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
      | Async.Waiting_for_owned_jobs {job_ids;_} ->
        let* job_ids = exact_waiting_jobs ~expected_owner:prior nodes job_ids in
        Ok (Some (job_ids,List.rev (entry :: terminals)))
      | Lost _ -> read (entry :: terminals) rest
      | Cancelled _ | Persistence_failed _ | Done _ -> Ok None
      | Queued | Running | Cancelling _ ->
        Error (Prior_owner_not_terminal {request_id=prior.request_id;
          reason="predecessor terminal proof has an active status"})
  in read [] prior_owners

let launch_replay_proven occurrence =
  owned_job_launch occurrence && Option.is_some occurrence.launch_invocation

let recoverable_lost_nodes nodes job_ids =
  let* recorded_jobs = Nodes.fold (fun _ record prior ->
    let* jobs = prior in
    let occurrence = occurrence_of_record record in
    let job = result_read_job occurrence in
    let replay_proven = match record with
      | Settled (_, {result=Tool_result.Completed _;_}, _, None) -> true
      | Settled (occurrence, completed, phase, Some job_id) ->
        valid_job_wait occurrence completed.result phase job_id
      | Attempting occurrence ->
        occurrence.readonly || launch_replay_proven occurrence
      | Settled (occurrence, {result=Tool_result.Failed _;_},
          Some Tool_result.Proven_pre_effect, None) ->
        occurrence.readonly || launch_replay_proven occurrence
      | Settled (occurrence, {result=Tool_result.Failed _;_},
          Some Tool_result.Effect_outcome_unknown, _) ->
        launch_replay_proven occurrence
      | Settled (_, {result=(Tool_result.Deferred _ | Tool_result.Failed _);_},
          (Some (Tool_result.Proven_pre_effect | Tool_result.Proven_post_effect
            | Tool_result.Effect_outcome_unknown) | None), None) -> false in
    if not replay_proven then Error (Invalid_result
        "lost continuation has a deferred or unproven node that cannot replay")
    else Ok (Option.to_list job @ jobs)) nodes (Ok []) in
  let recorded_jobs = normalize_job_ids recorded_jobs in
  if List.for_all (fun job_id -> List.mem job_id recorded_jobs) job_ids then Ok ()
  else Error (Invalid_result "original waiting jobs are absent from the lost journal")

let waiting_continuation journal = filesystem (fun () ->
  let* () = validate_artifacts ~base_path:journal.base_path journal.immutable_source in
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  match state.owner with
  | None -> Ok None
  | Some expected_owner ->
    match Async.load_canonical_durable_terminal ~base_path:journal.base_path
        ~caller:journal.immutable_source.keeper_name expected_owner.request_id with
    | Error (Async.Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) -> Ok None
    | Error (Async.Canonical_terminal_absent | Async.Canonical_terminal_unreadable _
        | Async.Canonical_terminal_access_rejected _
        | Async.Canonical_terminal_publication_ambiguous _
        | Async.Canonical_terminal_noncanonical_location _ as error) ->
      Error (Prior_owner_not_terminal
        {request_id=expected_owner.request_id;reason=Async.canonical_terminal_error_to_string error})
    | Ok proof ->
      let entry = Async.durable_terminal_entry proof in
      let* () = entry_matches_source journal.immutable_source entry
        |> Result.map_error (fun reason -> Prior_owner_not_terminal {request_id=expected_owner.request_id;reason}) in
      match entry.status with
      | Async.Waiting_for_owned_jobs {job_ids;_} ->
        let* job_ids = exact_waiting_jobs ~expected_owner state.nodes job_ids in
        Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals=[];
          suspended_nodes=state.nodes;job_ids})
      | Lost _ ->
        let* original_wait = prior_owned_job_wait journal state.prior_owners in
        (match original_wait with
         | None -> Ok None
         | Some (job_ids,predecessor_terminals) ->
           let* () = recoverable_lost_nodes state.nodes job_ids in
           Ok (Some {journal;expected_owner;terminal_entry=entry;predecessor_terminals;
             suspended_nodes=state.nodes;job_ids}))
      | Queued | Running | Cancelling _ | Cancelled _
      | Persistence_failed _ | Done _ -> Ok None)

let continuation_readiness (continuation : continuation) = filesystem (fun () ->
  let journal = continuation.journal in
  let* state = strict_read ~root:journal.root journal.path in
  let* () = check_source journal state in
  if not (same_owner state.owner (Some continuation.expected_owner))
      || state.nodes <> continuation.suspended_nodes then Error Ownership_changed
  else
  let* () = validate_predecessor_terminals continuation in
  let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name continuation.expected_owner.request_id
    |> Result.map_error (fun error -> Prior_owner_not_terminal
        {request_id=continuation.expected_owner.request_id;reason=Async.canonical_terminal_error_to_string error}) in
  if not (Async.same_entry_record continuation.terminal_entry (Async.durable_terminal_entry proof))
  then Error Ownership_changed
  else List.fold_left (fun prior job_id ->
    let* readiness = prior in
    let* record = Keeper_owned_job_store.load ~base_path:journal.base_path
        ~keeper_name:journal.immutable_source.keeper_name job_id
      |> Result.map_error (fun error -> Invalid_result (Keeper_owned_job_store.error_to_string error)) in
    match readiness, Keeper_owned_job_store.result_ready record with
    | Results_ready, true -> Ok Results_ready
    | (Waiting_for_results | Results_ready), false
    | Waiting_for_results, true -> Ok Waiting_for_results)
      (Ok Results_ready) continuation.job_ids)

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

let pending_continuations_with ~before_retire ~base_path = filesystem (fun () ->
  let base_path = Fs_compat.realpath base_path in
  let root = Common.masc_dir_from_base_path ~base_path in
  let directory = continuation_directory ~base_path in
  let* inspection = Fs_compat.inspect_owned_directory_chain ~ownership_root:root directory
    |> Result.map_error (fun error -> Persistence_failed
        (Fs_compat.owned_directory_chain_rejection_to_string error)) in
  let* names = match inspection with
    | Fs_compat.Owned_directory_missing -> Ok []
    | Owned_directory _ -> Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
        ~ownership_root:root directory
        |> Result.map_error (fun error -> Persistence_failed
            (Fs_compat.owned_regular_file_read_error_to_string error)) in
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
        let* journal = load ~base_path ~keeper_name:marker.keeper_name
            ~composition_run_id:marker.composition_run_id in
        let* state = strict_read ~root journal.path in
        let* () = check_source journal state in
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
          match state.owner with
          | None -> Error (Invalid_continuation_marker "request has no bound journal owner")
          | Some current when current.request_id <> marker.request_id -> retire ()
          | Some _ ->
            match entry.status with
            | Async.Waiting_for_owned_jobs _ | Lost _ ->
              let* candidate = waiting_continuation journal in
              (match candidate with
               | None when (match entry.status with Async.Lost _ -> true
                            | Queued | Running | Cancelling _ | Cancelled _
                            | Persistence_failed _ | Waiting_for_owned_jobs _ | Done _ -> false) -> retire ()
               | None -> Error Ownership_changed
               | Some continuation when continuation_request_id continuation <> marker.request_id -> Error Ownership_changed
               | Some continuation ->
                 let* readiness = continuation_readiness continuation in
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
      let report = {report with inspected=report.inspected+1} in
      {report with ready=continuation :: report.ready}
    | Ok Still_waiting ->
      let report = {report with inspected=report.inspected+1} in
      {report with waiting=report.waiting+1}
    | Ok Retired ->
      let report = {report with inspected=report.inspected+1} in
      {report with retired=report.retired+1}
    | Error error ->
      let report = {report with inspected=report.inspected+1} in
      {report with failures=(name,error) :: report.failures}) empty names in
  Ok {report with ready=List.rev report.ready;failures=List.rev report.failures})

let pending_continuations ~base_path =
  pending_continuations_with ~before_retire:(fun _ -> ()) ~base_path

module For_testing = struct
  let pending_continuations = pending_continuations_with
end

let check_worker (worker : worker) (state : state) = if same_owner state.owner (Some worker.binding) then Ok () else Error Ownership_changed

let validate_plan (worker : worker) ~plan =
  let* recorded = frozen_plan ~base_path:worker.journal.base_path worker.journal.immutable_source in
  let* actual = Keeper_tool_plan_request.to_yojson plan
    |> Result.map_error (fun _ -> Plan_identity_conflict) in
  if not (canonical_equal recorded actual) then Error Plan_identity_conflict
  else update_existing worker.journal (fun state -> None, check_worker worker state)

let checked_node (worker : worker) state ~node_id ~tool_name ~input =
  let* () = check_worker worker state in
  let* () = Result.map_error (fun detail -> Invalid_result detail) (decode (fun () -> valid_json input; require (exact_name tool_name) "invalid tool name")) in
  let record = Nodes.find_opt (Plan.Node_id.to_string node_id) state.nodes in
  match record with
  | Some record when not (same_node_identity (occurrence_of_record record) ~node_id ~tool_name ~input) -> Error (Node_identity_conflict node_id)
  | _ -> Ok record

let lookup (worker : worker) ~node_id ~tool_name ~input =
  update_existing worker.journal (fun state -> None,
    let* record = checked_node worker state ~node_id ~tool_name ~input in replay_for worker.binding node_id record)

let begin_attempt (worker : worker) ~node_id ~tool_name ~input ~execution_id ~tool_use_id ~readonly ?launch_invocation () =
  update_existing worker.journal (fun state ->
    let decision =
      let* record = checked_node worker state ~node_id ~tool_name ~input in
      let* replay = replay_for worker.binding node_id record in
      match replay with
      | Reuse_completed _ -> Error (Attempt_conflict node_id)
      | Dispatch | Recheck_job_result _ | Recheck_launch _ ->
        let* () = match replay with
          | Recheck_job_result stored when not readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id -> Error (Attempt_conflict node_id)
          | Recheck_launch stored when readonly
              || not (Ids.Execution_id.equal execution_id stored.execution_id)
              || tool_use_id <> stored.tool_use_id
              || launch_invocation <> Some stored.invocation -> Error (Attempt_conflict node_id)
          | Dispatch | Reuse_completed _ | Recheck_job_result _ | Recheck_launch _ -> Ok () in
        if not (exact_name tool_use_id && exact_name (Ids.Execution_id.to_string execution_id)) then Error (Invalid_result "invalid execution occurrence") else
        let sequence = match record with None -> 1 | Some record -> (occurrence_of_record record).sequence + 1 in
        Ok {node_id; tool_name; input; input_sha = json_sha input; owner = worker.binding; sequence; execution_id; tool_use_id; readonly; launch_invocation} in
    match decision with
    | Error error -> None, Error error
    | Ok occurrence -> Some (row (attempt_event worker.journal.source_sha occurrence)), Ok {worker; occurrence})

let settle_attempt ?failure_effect_disposition ?deferred_kind attempt ~result ~result_bytes ~truncated_to =
  let completed = {execution_id = attempt.occurrence.execution_id; tool_use_id = attempt.occurrence.tool_use_id; result; result_bytes; truncated_to} in
  let phase = match failure_effect_disposition, result with
    | Some phase, _ -> Some phase
    | None, Tool_result.Failed failure -> Some failure.effect_disposition
    | None, (Tool_result.Completed _ | Deferred _) -> None in
  let job_wait = match deferred_kind with
    | Some (Keeper_tool_execution.Owned_job_result_wait job_id) -> Some job_id
    | None | Some (Generic_deferred | External_effect_deferred _) -> None in
  let* encoded = Result.map_error (fun detail -> Invalid_result detail) (decode (fun () ->
    Option.iter (fun job_id -> require (valid_job_wait attempt.occurrence result phase job_id)
      "owned job wait does not match the exact read-only result leaf") job_wait;
    require (result_bytes >= 0 && Option.fold ~none:true ~some:(fun value -> value >= 0) truncated_to) "negative result size";
    require (String.equal (Tool_result.tool_name result) attempt.occurrence.tool_name) "result tool mismatch";
    let encoded = completed_json completed in valid_json encoded;
    let decoded = completed_of_json (Yojson.Safe.from_string (Yojson.Safe.to_string encoded)) in
    require (decoded.result = result) "strict durable result codec did not preserve complete payload";
    encoded)) in
  update_existing attempt.worker.journal (fun state ->
    match check_worker attempt.worker state with
    | Error error -> None, Error error
    | Ok () ->
      let record = Nodes.find_opt (Plan.Node_id.to_string attempt.occurrence.node_id) state.nodes in
      match record with
      | Some (Attempting current) when same_occurrence current attempt.occurrence ->
        let json = event "settled" state.source_sha ["occurrence", occurrence_json current; "completed", encoded;
          "failure_effect_disposition", option_json effect_json phase; "owned_job_wait", job_wait_json job_wait] in
        Some (row json), Ok ()
      | Some (Settled (current, prior, prior_phase, prior_wait)) when same_occurrence current attempt.occurrence
          && completed_json prior = encoded && prior_phase = phase && prior_wait = job_wait -> None, Ok ()
      | Some (Attempting _ | Settled _) | None -> None, Error (Attempt_conflict attempt.occurrence.node_id))
