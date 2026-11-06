module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
module Nodes = Map.Make (String)
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_json

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
