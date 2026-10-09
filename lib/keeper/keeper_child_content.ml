module Binding = Keeper_claude_task_binding
module Input = Runtime_claude_input_attribution
let ( let* ) = Result.bind

type origin =
  { keeper_name : string; source : Runtime_native_tasks.source
  ; attempt : Runtime_native_tasks.attempt; invocation : Runtime_native_tasks.invocation }
type parent_occurrence =
  { call_id : string; call_envelope_uuid : string; call_ordinal : int }
type parent_evidence =
  | Explicit_parent_input
  | Response_inherited_parent_input
  | Command_inherited_parent_input of { stamp_uuid : string }
type attribution =
  | Original_parent_input of parent_evidence
  | Parent_input_refused of Binding.rejection
type view =
  { origin : origin; observation_id : string; envelope_uuid : string; ordinal : int
  ; channel : Runtime_claude_code.content_channel; parent_tool_use_id : string
  ; parent_occurrence : parent_occurrence option; message_id : string option
  ; model : string; text : string; attribution : attribution }
type error = Invalid_view of string | Malformed_json of string
type publication = { observation : view }
let schema = "masc.child_content.v1"
let error_to_string = function
  | Invalid_view field -> "invalid child observation: " ^ field
  | Malformed_json field -> "malformed child observation: " ^ field

let identity label value =
  if String.length value > 0 then Ok () else Error (Invalid_view label)
let nonnegative label value =
  match Runtime_json_integer.of_json (`Int value) with
  | Ok n when n >= 0 -> Ok ()
  | Ok _ | Error _ -> Error (Invalid_view label)
let validate (value : view) =
  let origin=value.origin in
  let invocation=origin.invocation and attempt=origin.attempt in
  let* () = List.fold_left (fun result (label,value) ->
    let* () = result in identity label value) (Ok ())
    ["keeper_name",origin.keeper_name;"receiver_generation",invocation.receiver_generation;
     "session_id",invocation.session_id;"client_uuid",invocation.client_uuid;
     "routing_run_id",attempt.routing_run_id;"runtime_id",attempt.runtime_id;
     "observation_id",value.observation_id;"envelope_uuid",value.envelope_uuid;
     "parent_tool_use_id",value.parent_tool_use_id] in
  let* () = match origin.source with
    | Runtime_native_tasks.Operation {operation_id} -> identity "operation_id" operation_id
    | Autonomous_turn {turn_ref} -> identity "turn_ref" turn_ref in
  let* () = nonnegative "lane_attempt_index" attempt.lane_attempt_index in
  let* () = nonnegative "ordinal" value.ordinal in
  let* () = match value.parent_occurrence with
    | None -> Ok ()
    | Some parent ->
        let* () = identity "parent.call_id" parent.call_id in
        let* () = identity "parent.call_envelope_uuid" parent.call_envelope_uuid in
        nonnegative "parent.call_ordinal" parent.call_ordinal in
  let* () = match value.attribution,value.parent_occurrence with
    | Original_parent_input _,None -> Error (Invalid_view "bound parent is absent")
    | Original_parent_input _,Some parent when not (String.equal parent.call_id value.parent_tool_use_id) ->
        Error (Invalid_view "bound literal parent mismatch")
    | Parent_input_refused Binding.Unknown_parent,Some _ -> Error (Invalid_view "unknown parent is present")
    | Original_parent_input (Command_inherited_parent_input {stamp_uuid}),Some _ -> identity "stamp_uuid" stamp_uuid
    | Original_parent_input (Explicit_parent_input | Response_inherited_parent_input),Some _
    | Parent_input_refused _,_ -> Ok () in
  Ok value

let obj fields = `Assoc fields
let optional key encode = function None -> [] | Some value -> [key,encode value]
let str value = `String value
let parent_to_json parent = obj ["call_id",str parent.call_id;
  "call_envelope_uuid",str parent.call_envelope_uuid;"call_ordinal",`Int parent.call_ordinal]
let input_rejection_to_string = function
  | Input.Duplicate_field -> "duplicate_field" | Invalid_primary -> "invalid_primary"
  | Invalid_group -> "invalid_group" | Group_without_primary -> "group_without_primary"
  | Primary_not_in_group -> "primary_not_in_group" | Duplicate_member -> "duplicate_member"
  | Group_exceeds_provider_limit -> "group_exceeds_provider_limit"
  | Missing_frame_uuid -> "missing_frame_uuid" | Foreign_session -> "foreign_session"
  | Conflicting_frame_replay -> "conflicting_frame_replay" | Ambiguous_response -> "ambiguous_response"
let rejection_to_json = function
  | Binding.Rejected_assistant reason -> obj ["kind",str "rejected_assistant";
      "input_rejection",str (input_rejection_to_string reason)]
  | reason ->
      let kind = match reason with
        | Binding.Missing_ticket -> "missing_ticket" | Conflicting_invocation -> "conflicting_invocation"
        | Foreign_session -> "foreign_session" | Foreign_invocation -> "foreign_invocation"
        | Unknown_parent -> "unknown_parent" | Conflicting_parent_provenance -> "conflicting_parent_provenance"
        | Missing_assistant_evidence -> "missing_assistant_evidence"
        | Unattributed_assistant -> "unattributed_assistant" | Input_not_in_group -> "input_not_in_group"
        | Conflicting_assistant_evidence -> "conflicting_assistant_evidence"
        | Rejected_assistant _ -> "rejected_assistant" in
      obj ["kind",str kind]
let evidence_to_json = function
  | Explicit_parent_input -> obj ["kind",str "explicit"]
  | Response_inherited_parent_input -> obj ["kind",str "response_inherited"]
  | Command_inherited_parent_input {stamp_uuid} -> obj ["kind",str "command_inherited";"stamp_uuid",str stamp_uuid]
let attribution_to_json = function
  | Original_parent_input evidence -> obj ["kind",str "original_parent_input";"evidence",evidence_to_json evidence]
  | Parent_input_refused reason -> obj ["kind",str "parent_input_refused";"reason",rejection_to_json reason]
let source_to_json = function
  | Runtime_native_tasks.Operation {operation_id} -> obj ["kind",str "operation";"operation_id",str operation_id]
  | Autonomous_turn {turn_ref} -> obj ["kind",str "autonomous_turn";"turn_ref",str turn_ref]
let to_json value =
  let origin=value.origin in
  let attempt=origin.attempt and invocation=origin.invocation in
  obj (["schema",str schema;"origin",obj ["keeper_name",str origin.keeper_name;
    "source",source_to_json origin.source;
    "attempt",obj ["routing_run_id",str attempt.routing_run_id;"runtime_id",str attempt.runtime_id;
      "lane_attempt_index",`Int attempt.lane_attempt_index];
    "invocation",obj ["receiver_generation",str invocation.receiver_generation;
      "session_id",str invocation.session_id;"client_uuid",str invocation.client_uuid]];
    "observation_id",str value.observation_id;"envelope_uuid",str value.envelope_uuid;
    "ordinal",`Int value.ordinal;"channel",str (match value.channel with Runtime_claude_code.Text_content -> "text" | Thinking_content -> "thinking");
    "parent_tool_use_id",str value.parent_tool_use_id;"model",str value.model;"text",str value.text;
    "attribution",attribution_to_json value.attribution]
    @ optional "parent_occurrence" parent_to_json value.parent_occurrence
    @ optional "message_id" str value.message_id)

let fields ~label ~allowed = function
  | `Assoc fields ->
      let names=List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then Error (Malformed_json (label ^ ": duplicate member"))
      else if List.exists (fun name -> not (List.mem name allowed)) names
      then Error (Malformed_json (label ^ ": unknown member")) else Ok fields
  | _ -> Error (Malformed_json (label ^ ": expected object"))
let member label key fields = match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error (Malformed_json (label ^ ": missing " ^ key))
let string label = function `String value -> Ok value | _ -> Error (Malformed_json (label ^ ": expected string"))
let string_member label key fields = let* json=member label key fields in string (label ^ "." ^ key) json
let int_member label key fields =
  let* json=member label key fields in
  match Runtime_json_integer.of_json json with
  | Ok value -> Ok value | Error _ -> Error (Malformed_json (label ^ "." ^ key ^ ": invalid integer"))
let optional_member label key decode fields = match List.assoc_opt key fields with
  | None -> Ok None
  | Some `Null -> Error (Malformed_json (label ^ "." ^ key ^ ": null member"))
  | Some json -> let* value=decode json in Ok (Some value)
let input_rejection_of_string = function
  | "duplicate_field" -> Ok Input.Duplicate_field | "invalid_primary" -> Ok Input.Invalid_primary
  | "invalid_group" -> Ok Input.Invalid_group | "group_without_primary" -> Ok Input.Group_without_primary
  | "primary_not_in_group" -> Ok Input.Primary_not_in_group | "duplicate_member" -> Ok Input.Duplicate_member
  | "group_exceeds_provider_limit" -> Ok Input.Group_exceeds_provider_limit
  | "missing_frame_uuid" -> Ok Input.Missing_frame_uuid | "foreign_session" -> Ok Input.Foreign_session
  | "conflicting_frame_replay" -> Ok Input.Conflicting_frame_replay | "ambiguous_response" -> Ok Input.Ambiguous_response
  | _ -> Error (Malformed_json "unknown input rejection")
let rejection_of_json json =
  let* raw=fields ~label:"refusal" ~allowed:["kind";"input_rejection"] json in
  let* kind=string_member "refusal" "kind" raw in
  let regular reason = let* _=fields ~label:"refusal" ~allowed:["kind"] json in Ok reason in
  match kind with
  | "missing_ticket" -> regular Binding.Missing_ticket
  | "conflicting_invocation" -> regular Binding.Conflicting_invocation
  | "foreign_session" -> regular Binding.Foreign_session
  | "foreign_invocation" -> regular Binding.Foreign_invocation
  | "unknown_parent" -> regular Binding.Unknown_parent
  | "conflicting_parent_provenance" -> regular Binding.Conflicting_parent_provenance
  | "missing_assistant_evidence" -> regular Binding.Missing_assistant_evidence
  | "unattributed_assistant" -> regular Binding.Unattributed_assistant
  | "input_not_in_group" -> regular Binding.Input_not_in_group
  | "conflicting_assistant_evidence" -> regular Binding.Conflicting_assistant_evidence
  | "rejected_assistant" -> let* wire=string_member "refusal" "input_rejection" raw in
      let* reason=input_rejection_of_string wire in Ok (Binding.Rejected_assistant reason)
  | _ -> Error (Malformed_json "unknown parent input refusal")
let evidence_of_json json =
  let* raw=fields ~label:"evidence" ~allowed:["kind";"stamp_uuid"] json in
  let* kind=string_member "evidence" "kind" raw in
  let regular value = let* _=fields ~label:"evidence" ~allowed:["kind"] json in Ok value in
  match kind with
  | "explicit" -> regular Explicit_parent_input
  | "response_inherited" -> regular Response_inherited_parent_input
  | "command_inherited" -> let* stamp_uuid=string_member "evidence" "stamp_uuid" raw in
      Ok (Command_inherited_parent_input {stamp_uuid})
  | _ -> Error (Malformed_json "unknown parent evidence")
let attribution_of_json json =
  let* raw=fields ~label:"attribution" ~allowed:["kind";"evidence";"reason"] json in
  let* kind=string_member "attribution" "kind" raw in
  match kind with
  | "original_parent_input" ->
      let* raw=fields ~label:"attribution" ~allowed:["kind";"evidence"] json in
      let* json=member "attribution" "evidence" raw in let* evidence=evidence_of_json json in
      Ok (Original_parent_input evidence)
  | "parent_input_refused" ->
      let* raw=fields ~label:"attribution" ~allowed:["kind";"reason"] json in
      let* json=member "attribution" "reason" raw in let* reason=rejection_of_json json in
      Ok (Parent_input_refused reason)
  | _ -> Error (Malformed_json "unknown attribution")
let parent_of_json json =
  let* raw=fields ~label:"parent" ~allowed:["call_id";"call_envelope_uuid";"call_ordinal"] json in
  let* call_id=string_member "parent" "call_id" raw in
  let* call_envelope_uuid=string_member "parent" "call_envelope_uuid" raw in
  let* call_ordinal=int_member "parent" "call_ordinal" raw in
  Ok {call_id;call_envelope_uuid;call_ordinal}
let source_of_json json =
  let* raw=fields ~label:"source" ~allowed:["kind";"operation_id";"turn_ref"] json in
  let* kind=string_member "source" "kind" raw in
  match kind with
  | "operation" -> let* raw=fields ~label:"source" ~allowed:["kind";"operation_id"] json in
      let* operation_id=string_member "source" "operation_id" raw in Ok (Runtime_native_tasks.Operation {operation_id})
  | "autonomous_turn" -> let* raw=fields ~label:"source" ~allowed:["kind";"turn_ref"] json in
      let* turn_ref=string_member "source" "turn_ref" raw in Ok (Runtime_native_tasks.Autonomous_turn {turn_ref})
  | _ -> Error (Malformed_json "unknown source")
let origin_of_json json =
  let* raw=fields ~label:"origin" ~allowed:["keeper_name";"source";"attempt";"invocation"] json in
  let* keeper_name=string_member "origin" "keeper_name" raw in
  let* source_json=member "origin" "source" raw in let* source=source_of_json source_json in
  let* attempt_json=member "origin" "attempt" raw in
  let* attempt_fields=fields ~label:"attempt" ~allowed:["routing_run_id";"runtime_id";"lane_attempt_index"] attempt_json in
  let* routing_run_id=string_member "attempt" "routing_run_id" attempt_fields in
  let* runtime_id=string_member "attempt" "runtime_id" attempt_fields in
  let* lane_attempt_index=int_member "attempt" "lane_attempt_index" attempt_fields in
  let* invocation_json=member "origin" "invocation" raw in
  let* invocation_fields=fields ~label:"invocation" ~allowed:["receiver_generation";"session_id";"client_uuid"] invocation_json in
  let* receiver_generation=string_member "invocation" "receiver_generation" invocation_fields in
  let* session_id=string_member "invocation" "session_id" invocation_fields in
  let* client_uuid=string_member "invocation" "client_uuid" invocation_fields in
  Ok {keeper_name;source;attempt={Runtime_native_tasks.routing_run_id;runtime_id;lane_attempt_index};
      invocation={Runtime_native_tasks.receiver_generation;session_id;client_uuid}}
let of_json json =
  let* raw=fields ~label:"child" ~allowed:["schema";"origin";"observation_id";"envelope_uuid";
    "ordinal";"channel";"parent_tool_use_id";"parent_occurrence";"message_id";"model";"text";"attribution"] json in
  let* supplied_schema=string_member "child" "schema" raw in
  let* ()=if String.equal supplied_schema schema then Ok () else Error (Malformed_json "unknown schema") in
  let* origin_json=member "child" "origin" raw in let* origin=origin_of_json origin_json in
  let* observation_id=string_member "child" "observation_id" raw in
  let* envelope_uuid=string_member "child" "envelope_uuid" raw in
  let* ordinal=int_member "child" "ordinal" raw in
  let* channel_wire=string_member "child" "channel" raw in
  let* channel=match channel_wire with "text" -> Ok Runtime_claude_code.Text_content
    | "thinking" -> Ok Runtime_claude_code.Thinking_content | _ -> Error (Malformed_json "unknown channel") in
  let* parent_tool_use_id=string_member "child" "parent_tool_use_id" raw in
  let* parent_occurrence=optional_member "child" "parent_occurrence" parent_of_json raw in
  let* message_id=optional_member "child" "message_id" (string "message_id") raw in
  let* model=string_member "child" "model" raw in
  let* text=string_member "child" "text" raw in
  let* attribution_json=member "child" "attribution" raw in let* attribution=attribution_of_json attribution_json in
  validate {origin;observation_id;envelope_uuid;ordinal;channel;parent_tool_use_id;parent_occurrence;message_id;model;text;attribution}

let redact redact_text (value : view) =
  {value with model=redact_text value.model; text=redact_text value.text}

let prepare ~keeper_name ~source ~attempt ~redact_text observation =
  let content,attribution = match observation with
    | Binding.Child_bound bound ->
        let evidence=match bound.parent_input.evidence with
          | Binding.Explicit_group _ -> Explicit_parent_input
          | Response_inherited _ -> Response_inherited_parent_input
          | Command_inherited witness -> Command_inherited_parent_input {stamp_uuid=witness.stamp_uuid} in
        bound.content,Original_parent_input evidence
    | Child_rejected {content;reason} -> content,Parent_input_refused reason in
  let source=match source with
    | Keeper_native_task_journal.Operation operation_id -> Runtime_native_tasks.Operation
        {operation_id=Keeper_chat_operation.Operation_id.to_string operation_id}
    | Autonomous_turn turn_ref -> Runtime_native_tasks.Autonomous_turn {turn_ref=Ids.Turn_ref.to_string turn_ref} in
  let ticket=content.invocation in
  let origin={keeper_name;source;attempt;invocation={Runtime_native_tasks.receiver_generation=ticket.receiver_generation;
    session_id=ticket.session_id;client_uuid=ticket.client_uuid}} in
  let parent_occurrence=Option.map (fun (parent:Runtime_claude_code.native_agent_parent_witness) ->
    {call_id=parent.call_id;call_envelope_uuid=parent.call_envelope_uuid;call_ordinal=parent.call_ordinal}) content.parent_occurrence in
  let* envelope_uuid,ordinal=match content.block with
    | Runtime_claude_code.Assistant_block {uuid;ordinal} -> Ok (uuid,ordinal)
    | Partial_block _ -> Error (Invalid_view "complete child uses partial block") in
  let* observation=validate {origin;observation_id=content.observation_id;envelope_uuid;ordinal;
    channel=content.channel;parent_tool_use_id=content.parent_tool_use_id;parent_occurrence;
    message_id=content.message_id;model=content.model;text=content.text;attribution} in
  Ok {observation=redact redact_text observation}
let view publication = publication.observation
