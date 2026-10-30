module L = Keeper_librarian
module A = Agent_core.Types
module C = Keeper_librarian_context
module H = Keeper_librarian_task_context
module P = Keeper_counterpart_observation
module F = Keeper_memory_os_types
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result

let fields expected = function
  | `Assoc entries when List.sort String.compare (List.map fst entries)=List.sort String.compare expected -> Ok entries
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "Librarian input capture has unknown, duplicate, missing or non-object fields"
let value name entries = List.assoc name entries
let text = function
  | `String s -> Ok s
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ -> Error "Expected captured text"
let nonblank json =
  let* s=text json in
  if String.trim s="" then Error "Captured goal identity must be nonblank" else Ok s
let integer = function
  | `Int n -> Ok n
  | `Assoc _ | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Expected captured integer"
let list decode = function
  | `List values -> List.fold_right (fun json result -> let* x=decode json in let+ xs=result in x::xs) values (Ok [])
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Error "Expected captured list"
let strings = list text
let json_strings values = `List (List.map (fun s -> `String s) values)
let optional encode = Option.fold ~none:`Null ~some:encode
let option decode = function
  | `Null -> Ok None
  | (`Assoc _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json ->
    let+ v=decode json in Some v
(* JSON itself may be Null, so presence cannot use Null as its sentinel. *)
let json_option = function None -> `List [] | Some json -> `List [json]
let json_option_of_json = function
  | `List [] -> Ok None | `List [json] -> Ok (Some json)
  | `List (_::_::_) | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
    Error "Captured optional JSON requires zero or one value"
let tag json = match json with
  | `Assoc entries -> (match List.assoc_opt "kind" entries with Some json -> text json | None -> Error "Missing captured kind")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Expected captured tagged object"
let fact_of_json json = F.fact_of_json json |> Result.map_error F.wire_error_to_string

let error_class_json : A.tool_error_class -> Yojson.Safe.t = function
  | Transient -> `String "transient" | Deterministic -> `String "deterministic" | Unknown -> `String "unknown"
let error_class_of_json json = let* s=text json in match s with
  | "transient" -> Ok A.Transient | "deterministic" -> Ok A.Deterministic | "unknown" -> Ok A.Unknown
  | _ -> Error "Unknown captured tool error class"
let failure_kind_json : A.tool_failure_kind -> Yojson.Safe.t = function
  | Validation_error -> `String "validation_error" | Recoverable_tool_error -> `String "recoverable_tool_error"
  | Non_retryable_tool_error -> `String "non_retryable_tool_error" | Reported_tool_error -> `String "reported_tool_error"
  | Unattributed_tool_error -> `String "unattributed_tool_error"
let failure_kind_of_json json = let* s=text json in match s with
  | "validation_error" -> Ok A.Validation_error | "recoverable_tool_error" -> Ok A.Recoverable_tool_error
  | "non_retryable_tool_error" -> Ok A.Non_retryable_tool_error | "reported_tool_error" -> Ok A.Reported_tool_error
  | "unattributed_tool_error" -> Ok A.Unattributed_tool_error | _ -> Error "Unknown captured tool failure provenance"
let outcome_json : A.tool_result_outcome -> Yojson.Safe.t = function
  | Tool_succeeded -> `Assoc ["kind",`String "succeeded"]
  | Tool_failed failure -> `Assoc ["kind",`String "failed";"failure_kind",failure_kind_json failure.failure_kind;
      "error_class",optional error_class_json failure.error_class]
let outcome_of_json json = let* kind=tag json in match kind with
  | "succeeded" -> let+ _=fields ["kind"] json in A.Tool_succeeded
  | "failed" -> let* f=fields ["kind";"failure_kind";"error_class"] json in
    let* failure_kind=failure_kind_of_json (value "failure_kind" f) in
    let+ error_class=option error_class_of_json (value "error_class" f) in A.Tool_failed {failure_kind;error_class}
  | _ -> Error "Unknown captured tool result outcome"
let detail_json (detail:A.reasoning_detail) = `Assoc ["raw",detail.raw;"text",optional (fun s -> `String s) detail.text]
let detail_of_json json = let* f=fields ["raw";"text"] json in
  let+ text=option text (value "text" f) in ({A.raw=value "raw" f;text}:A.reasoning_detail)
let rec content_json : A.content_block -> Yojson.Safe.t = function
  | Text s -> `Assoc ["kind",`String "text";"text",`String s]
  | Thinking {content;signature} -> `Assoc ["kind",`String "thinking";"content",`String content;
      "signature",optional (fun s -> `String s) signature]
  | ReasoningDetails {reasoning_content;details} -> `Assoc ["kind",`String "reasoning_details";
      "reasoning_content",optional (fun s -> `String s) reasoning_content;"details",`List (List.map detail_json details)]
  | RedactedThinking s -> `Assoc ["kind",`String "redacted_thinking";"content",`String s]
  | ToolUse {id;name;input} -> `Assoc ["kind",`String "tool_use";"id",`String id;"name",`String name;"input",input]
  | ToolResult {tool_use_id;content;outcome;json;content_blocks} -> `Assoc ["kind",`String "tool_result";
      "tool_use_id",`String tool_use_id;"content",`String content;"outcome",outcome_json outcome;
      "json",json_option json;"content_blocks",optional (fun blocks -> `List (List.map content_json blocks)) content_blocks]
  | (Image _ | Document _ | Audio _) as block -> media_content_json block
(* Media are captured by reference, in the history codec's source shape. *)
and media_content_json block = match Agent_core.History.content_block_to_json block with
  | `Assoc fields -> `Assoc (("kind", Option.value (List.assoc_opt "type" fields) ~default:`Null)
      :: List.filter (fun (key, _) -> not (String.equal key "type")) fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json -> json
let rec content_of_json json : (A.content_block,string) result =
  let* kind=tag json in match kind with
  | "text" -> let* f=fields ["kind";"text"] json in let+ s=text (value "text" f) in A.Text s
  | "thinking" -> let* f=fields ["kind";"content";"signature"] json in
    let* content=text (value "content" f) in let+ signature=option text (value "signature" f) in A.Thinking {content;signature}
  | "reasoning_details" -> let* f=fields ["kind";"reasoning_content";"details"] json in
    let* reasoning_content=option text (value "reasoning_content" f) in
    let+ details=list detail_of_json (value "details" f) in A.ReasoningDetails {reasoning_content;details}
  | "redacted_thinking" -> let* f=fields ["kind";"content"] json in
    let+ s=text (value "content" f) in A.RedactedThinking s
  | "tool_use" -> let* f=fields ["kind";"id";"name";"input"] json in
    let* id=text (value "id" f) in let+ name=text (value "name" f) in A.ToolUse {id;name;input=value "input" f}
  | "tool_result" -> let* f=fields ["kind";"tool_use_id";"content";"outcome";"json";"content_blocks"] json in
    let* tool_use_id=text (value "tool_use_id" f) in let* content=text (value "content" f) in
    let* outcome=outcome_of_json (value "outcome" f) in let* json=json_option_of_json (value "json" f) in
    let+ content_blocks=option (list content_of_json) (value "content_blocks" f) in
    A.ToolResult {tool_use_id;content;outcome;json;content_blocks}
  | "image" | "document" | "audio" -> media_content_of_json kind json
  | _ -> Error "Unknown captured content block"
and media_content_of_json kind json = let* f=fields ["kind";"source"] json in
  Agent_core.History.content_block_of_json (`Assoc ["type",`String kind;"source",value "source" f])
  |> Result.map_error Agent_core.History.decode_error_to_string
let role_json : A.role -> Yojson.Safe.t = function
  | System -> `String "system" | User -> `String "user" | Assistant -> `String "assistant" | Tool -> `String "tool"
let role_of_json json = let* s=text json in match s with
  | "system" -> Ok A.System | "user" -> Ok A.User | "assistant" -> Ok A.Assistant | "tool" -> Ok A.Tool
  | _ -> Error "Unknown captured message role"
let message_json (message:A.message) = `Assoc [
  "role",role_json message.role;"origin",`String (A.message_origin_to_string message.origin);
  "content",`List (List.map content_json message.content);"name",optional (fun s -> `String s) message.name;
  "tool_call_id",optional (fun s -> `String s) message.tool_call_id;
  "metadata",`List (List.map (fun (key,json) -> `Assoc ["key",`String key;"value",json]) message.metadata)]
let message_of_json json =
  let* f=fields ["role";"origin";"content";"name";"tool_call_id";"metadata"] json in
  let* role=role_of_json (value "role" f) in let* content=list content_of_json (value "content" f) in
  let* name=option text (value "name" f) in let* tool_call_id=option text (value "tool_call_id" f) in
  let* metadata=list (fun json -> let* f=fields ["key";"value"] json in
    let+ key=text (value "key" f) in key,value "value" f) (value "metadata" f) in
  let* origin_token=text (value "origin" f) in
  let+ origin=match A.message_origin_of_string origin_token with
    | Some origin -> Ok origin | None -> Error "Unknown captured message origin" in
  ({origin;A.role;content;name;tool_call_id;metadata}:A.message)

let source_json (source:C.source) = `Assoc ["reference",`String source.reference;"content",source.content]
let source_of_json json = let* f=fields ["reference";"content"] json in
  let+ reference=text (value "reference" f) in ({C.reference;content=value "content" f}:C.source)
let completeness_json : C.completeness -> Yojson.Safe.t = function
  | Current -> `String "current" | Needs_reconsideration -> `String "needs_reconsideration"
let completeness_of_json json = let* s=text json in match s with
  | "current" -> Ok C.Current | "needs_reconsideration" -> Ok C.Needs_reconsideration
  | _ -> Error "Unknown captured pocket completeness"
let pocket_json (pocket:C.pocket) = `Assoc ["id",`String pocket.id;"merge_contexts",json_strings pocket.merge_contexts;
  "sources",json_strings pocket.sources;"context",`String pocket.context;"next_steps",json_strings pocket.next_steps;
  "completeness",completeness_json pocket.completeness]
let pocket_of_json json = let* f=fields ["id";"merge_contexts";"sources";"context";"next_steps";"completeness"] json in
  let* id=text (value "id" f) in let* merge_contexts=strings (value "merge_contexts" f) in
  let* sources=strings (value "sources" f) in let* context=text (value "context" f) in
  let* next_steps=strings (value "next_steps" f) in let+ completeness=completeness_of_json (value "completeness" f) in
  ({C.id;merge_contexts;sources;context;next_steps;completeness}:C.pocket)
let snapshot_json (snapshot:C.snapshot) = `Assoc ["generation",`String snapshot.generation;"revision",`Int snapshot.revision;
  "execution_basis",optional (fun s -> `String s) snapshot.execution_basis;
  "sources",`List (List.map source_json snapshot.sources);"pockets",`List (List.map pocket_json snapshot.pockets)]
let snapshot_of_json json = let* f=fields ["generation";"revision";"execution_basis";"sources";"pockets"] json in
  let* generation=text (value "generation" f) in let* revision=integer (value "revision" f) in
  let* execution_basis=option text (value "execution_basis" f) in let* sources=list source_of_json (value "sources" f) in
  let+ pockets=list pocket_of_json (value "pockets" f) in ({C.generation;revision;execution_basis;sources;pockets}:C.snapshot)
let context_json (context:C.input) = `Assoc ["sources",`List (List.map source_json context.sources);
  "previous",optional snapshot_json context.previous;"unavailable",json_strings context.unavailable;
  "execution_basis",optional (fun s -> `String s) context.execution_basis]
let context_of_json json = let* f=fields ["sources";"previous";"unavailable";"execution_basis"] json in
  let* sources=list source_of_json (value "sources" f) in let* previous=option snapshot_of_json (value "previous" f) in
  let* unavailable=strings (value "unavailable" f) in let+ execution_basis=option text (value "execution_basis" f) in
  ({C.sources;previous;unavailable;execution_basis}:C.input)

let historical_source_of_json json = let* kind=tag json in match kind with
  | "atoms" -> let* f=fields ["kind";"trace_id";"start_atom";"end_atom"] json in
    let* trace_id=text (value "trace_id" f) in let* start_atom=integer (value "start_atom" f) in
    let+ end_atom=integer (value "end_atom" f) in H.Atom_span {trace_id;start_atom;end_atom}
  | "official_turn" -> let+ _=fields ["kind"] json in H.Official_turn
  | "boundary_only" -> let+ _=fields ["kind"] json in H.Boundary_only
  | _ -> Error "Unknown captured historical source"
let attribution_of_json json = let* kind=tag json in match kind with
  | "unattributed" -> let+ _=fields ["kind"] json in H.Unattributed
  | "observed" -> let* f=fields ["kind";"turn_ref";"task_context"] json in
    let* turn_ref=Ids.Turn_ref.of_yojson (value "turn_ref" f) in
    let+ task_context=Keeper_turn_task_context.of_json (value "task_context" f) |> Result.map_error F.wire_error_to_string in
    H.Observed {turn_ref;task_context}
  | _ -> Error "Unknown captured historical attribution"
let historical_of_json json =
  let* f=fields ["source";"attribution";"first_message";"after_message";"first_tool_observation";"after_tool_observation"] json in
  let* source=historical_source_of_json (value "source" f) in let* attribution=attribution_of_json (value "attribution" f) in
  let* first_message=integer (value "first_message" f) in let* after_message=integer (value "after_message" f) in
  let* first_tool_observation=integer (value "first_tool_observation" f) in
  let+ after_tool_observation=integer (value "after_tool_observation" f) in
  ({H.scope={source;attribution};first_message;after_message;first_tool_observation;after_tool_observation}:H.t)
let goal_of_json json =
  let* f=match json with `Assoc f -> Ok f | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Expected captured goal context" in
  let* status=match List.assoc_opt "status" f with Some json -> text json | None -> Error "Missing goal status" in
  match status with
  | "no_task" -> let+ _=fields ["status"] json in L.No_task
  | "unavailable" -> let* f=fields ["status";"task_id";"detail"] json in
    let* task_id=nonblank (value "task_id" f) in let+ detail=text (value "detail" f) in L.Task_goals {task_id;criteria=Error detail}
  | "available" -> let* f=fields ["status";"task_id";"goals"] json in
    let* task_id=nonblank (value "task_id" f) in
    let+ criteria=list (fun json -> let* f=fields ["goal_id";"phase";"criterion"] json in
      let* goal_id=nonblank (value "goal_id" f) in let* phase=Goal_phase.of_yojson (value "phase" f) in
      let+ criterion=Goal_store.criterion_of_yojson (value "criterion" f) in goal_id,phase,criterion) (value "goals" f) in
    L.Task_goals {task_id;criteria=Ok criteria}
  | _ -> Error "Unknown captured goal status"
let current_json (current:L.current_selection) = `Assoc ["facts",`List (List.map F.fact_to_json current.facts)]
let current_of_json json = let* f=fields ["facts"] json in
  let+ facts=list fact_of_json (value "facts" f) in ({L.facts}:L.current_selection)
let tool_json (observation:L.tool_observation) =
  let outcome=match observation.outcome with L.Succeeded -> "succeeded" | Failed -> "failed" | Unknown -> "unknown" in
  `Assoc ["tool_name",`String observation.tool_name;"outcome",`String outcome]
let tool_of_json json = let* f=fields ["tool_name";"outcome"] json in
  let* tool_name=text (value "tool_name" f) in let* token=text (value "outcome" f) in
  let+ outcome=match token with "succeeded" -> Ok L.Succeeded | "failed" -> Ok L.Failed | "unknown" -> Ok L.Unknown
    | _ -> Error "Unknown captured tool observation outcome" in ({L.tool_name;outcome}:L.tool_observation)
let counterpart_of_json json = let* f=fields ["origin";"channel";"workspace_id";"user_id";"user_name";"authority";"content"] json in
  let* token=text (value "origin" f) in
  let* origin=match token with "connector_attention" -> Ok P.Connector_attention | "durable_chat" -> Ok P.Durable_chat
    | _ -> Error "Unknown captured counterpart origin" in
  let* token=text (value "authority" f) in
  let* authority=match token with "owner" -> Ok P.Owner | "external" -> Ok P.External | "keeper" -> Ok P.Keeper
    | _ -> Error "Unknown captured counterpart authority" in
  let* channel=text (value "channel" f) in let* workspace_id=option text (value "workspace_id" f) in
  let* user_id=option text (value "user_id" f) in let* user_name=option text (value "user_name" f) in
  let+ content=text (value "content" f) in ({P.origin;channel;workspace_id;user_id;user_name;authority;content}:P.t)

let to_json (input:L.input) : Yojson.Safe.t = `Assoc [
  "keeper_id",`String (Keeper_identity.Keeper_id.to_string input.keeper_id);
  "keeper_instructions",`String input.keeper_instructions;"turn_ref",Ids.Turn_ref.to_yojson input.turn_ref;
  "goal_context",L.goal_context_to_json input.goal_context;"current",optional current_json input.current;
  "historical_task_contexts",H.to_json input.historical_task_contexts;"working_context",context_json input.working_context;
  "messages",`List (List.map message_json input.messages);
  "tool_observations",`List (List.map tool_json input.tool_observations);
  "counterpart_observations",`List (List.map P.to_yojson input.counterpart_observations)]
let of_json json =
  let* f=fields ["keeper_id";"keeper_instructions";"turn_ref";"goal_context";"current";
    "historical_task_contexts";"working_context";"messages";"tool_observations";"counterpart_observations"] json in
  let* name=text (value "keeper_id" f) in
  let* keeper_id=match Keeper_identity.Keeper_id.of_string name with
    | Some id when Keeper_identity.Keeper_id.to_string id=name -> Ok id
    | Some _ | None -> Error "Captured Keeper identity is not canonical" in
  let* keeper_instructions=text (value "keeper_instructions" f) in let* turn_ref=Ids.Turn_ref.of_yojson (value "turn_ref" f) in
  let* goal_context=goal_of_json (value "goal_context" f) in let* current=option current_of_json (value "current" f) in
  let* historical_task_contexts=list historical_of_json (value "historical_task_contexts" f) in
  let* working_context=context_of_json (value "working_context" f) in let* messages=list message_of_json (value "messages" f) in
  let* tool_observations=list tool_of_json (value "tool_observations" f) in
  let+ counterpart_observations=list counterpart_of_json (value "counterpart_observations" f) in
  ({L.keeper_id;keeper_instructions;turn_ref;goal_context;current;historical_task_contexts;
    working_context;messages;tool_observations;counterpart_observations}:L.input)
