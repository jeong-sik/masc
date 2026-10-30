open Result.Syntax
module Invocation = Agent_core.Tool_contract.Invocation
module Types = Keeper_skill_activation_types
type presentation = Inline_result | Manifest_reference
type child_activation = { skill_tool_use_id : string; activation_sha256 : string }
type t =
  { original_turn_ref : Ids.Turn_ref.t
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; logical_parent_tool_use_id : string
  ; request_id : string
  ; physical_turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; status_invocation : Invocation.t
  ; boundary : Types.delivery_boundary
  ; receipt : Types.tool_result_receipt
  ; presentation : presentation
  ; child_activations : child_activation list
  ; observed_at : string
  }
let invocation_to_json invocation =
  let schedule = Invocation.schedule invocation in
  `Assoc ["tool_use_id",`String (Invocation.tool_use_id invocation);
    "turn",`Int (Invocation.turn invocation);
    "schedule",`Assoc ["planned_index",`Int schedule.planned_index;
      "batch_index",`Int schedule.batch_index;"batch_size",`Int schedule.batch_size;
      "execution_mode",Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode];
    "completion",Agent_core.Tool_contract.completion_to_yojson (Invocation.completion invocation)]
let equal_invocation left right =
  String.equal (Invocation.tool_use_id left) (Invocation.tool_use_id right)
  && Invocation.turn left = Invocation.turn right
  && Invocation.schedule left = Invocation.schedule right
  && Invocation.completion left = Invocation.completion right
let boundary_to_json = function
  | Types.Model_response {agent_core_turn} -> `Assoc ["kind",`String "model_response";"agent_core_turn",`Int agent_core_turn]
  | Official_client_result_handoff {agent_core_turn} -> `Assoc ["kind",`String "official_client_result_handoff";"agent_core_turn",`Int agent_core_turn]
let fields value =
  ["original_turn_ref",Ids.Turn_ref.to_yojson value.original_turn_ref;
   "composition_run_id",`String (Keeper_tool_plan.Composition_run_id.to_string value.composition_run_id);
   "logical_parent_tool_use_id",`String value.logical_parent_tool_use_id;
   "request_id",`String value.request_id;"physical_turn_ref",Ids.Turn_ref.to_yojson value.physical_turn_ref;
   "runtime_id",`String value.runtime_id;"status_invocation",invocation_to_json value.status_invocation;
   "boundary",boundary_to_json value.boundary;
   "receipt",`Assoc ["tool_use_id",`String value.receipt.tool_use_id;
     "content_bytes",`Int value.receipt.content_bytes;"content_sha256",`String value.receipt.content_sha256];
   "presentation",`String (match value.presentation with Inline_result -> "inline_result" | Manifest_reference -> "manifest_reference");
   "child_activations",`List (List.map (fun child -> `Assoc ["skill_tool_use_id",`String child.skill_tool_use_id; "activation_sha256",`String child.activation_sha256]) value.child_activations)]
let to_json value = `Assoc (fields value @ ["observed_at",`String value.observed_at])
let identity value = Agent_core_sha256.(digest_string (Yojson.Safe.to_string (`Assoc (fields value))) |> to_hex)
let nonblank name value = if String.trim value <> "" then Ok () else Error (name ^ " is blank")
let validate_invocation invocation =
  let* () = nonblank "SDK invocation" (Invocation.tool_use_id invocation) in
  let schedule = Invocation.schedule invocation in
  if Invocation.turn invocation >= 0 && schedule.planned_index >= 0
      && schedule.batch_index >= 0 && schedule.batch_size > 0 then Ok () else Error "invalid SDK occurrence"
let make ~original_turn_ref ~composition_run_id ~logical_parent_tool_use_id ~request_id
    ~physical_turn_ref ~runtime_id ~status_invocation ~boundary ~receipt ~presentation
    ~child_activations ~observed_at =
  let* () = nonblank "original trace" (Ids.Turn_ref.trace_id original_turn_ref) in
  let* () = nonblank "physical trace" (Ids.Turn_ref.trace_id physical_turn_ref) in
  let* () = if Ids.Turn_ref.absolute_turn original_turn_ref > 0 && Ids.Turn_ref.absolute_turn physical_turn_ref > 0
    then Ok () else Error "invalid admitted Keeper turn" in
  let* () = nonblank "logical parent" logical_parent_tool_use_id in
  let* () = nonblank "canonical request" request_id in
  let* () = nonblank "runtime" runtime_id in
  let* () = validate_invocation status_invocation in
  let* () = if String.equal receipt.Types.tool_use_id (Invocation.tool_use_id status_invocation)
      && receipt.content_bytes >= 0 then Ok () else Error "receipt differs from actual status invocation" in
  let* () = Skill_reference.validate_revision_string receipt.content_sha256
    |> Result.map_error (fun _ -> "invalid raw transport digest") in
  let* () = match boundary with
    | Types.Model_response {agent_core_turn} when agent_core_turn > Invocation.turn status_invocation -> Ok ()
    | Official_client_result_handoff {agent_core_turn} when agent_core_turn = Invocation.turn status_invocation -> Ok ()
    | Model_response _ | Official_client_result_handoff _ -> Error "handoff precedes or differs from status occurrence" in
  let* () = match child_activations with
    | [] -> Error "no admitted original child"
    | _::_ -> List.fold_left (fun result child ->
        let* () = result in
        let* () = nonblank "child invocation" child.skill_tool_use_id in
        Skill_reference.validate_revision_string child.activation_sha256
        |> Result.map_error (fun _ -> "invalid original activation frame digest")) (Ok ()) child_activations in
  let children = List.sort (fun left right -> String.compare left.skill_tool_use_id right.skill_tool_use_id) child_activations in
  let ids = List.map (fun child -> child.skill_tool_use_id) children in
  let* () = if List.sort_uniq String.compare ids = ids then Ok () else Error "duplicate child invocation" in
  let* () = Time_codec.parse_rfc3339 observed_at |> Result.map ignore |> Result.map_error (fun _ -> "invalid observation clock") in
  Ok {original_turn_ref;composition_run_id;logical_parent_tool_use_id;request_id;physical_turn_ref;
    runtime_id;status_invocation;boundary;receipt;presentation;child_activations=children;observed_at}
let object_fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "unexpected, duplicate or missing async evidence fields"
let string name fields = match List.assoc name fields with `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ -> Error ("expected string " ^ name)
let int name fields = match List.assoc name fields with `Int value -> Ok value
  | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> Error ("expected integer " ^ name)
let invocation_of_json json =
  let* fields = object_fields ["tool_use_id";"turn";"schedule";"completion"] json in
  let* tool_use_id = string "tool_use_id" fields and* turn = int "turn" fields in
  let* schedule = object_fields ["planned_index";"batch_index";"batch_size";"execution_mode"] (List.assoc "schedule" fields) in
  let* planned_index = int "planned_index" schedule and* batch_index = int "batch_index" schedule in
  let* batch_size = int "batch_size" schedule in
  let* execution_mode = Agent_core.Tool_contract.execution_mode_of_yojson (List.assoc "execution_mode" schedule) in
  let* completion = Agent_core.Tool_contract.completion_of_yojson (List.assoc "completion" fields) in
  Ok (Invocation.create ~tool_use_id ~turn ~schedule:{planned_index;batch_index;batch_size;execution_mode} ~completion)
let of_json json =
  let* fields = object_fields ["original_turn_ref";"composition_run_id";"logical_parent_tool_use_id";
    "request_id";"physical_turn_ref";"runtime_id";"status_invocation";"boundary";"receipt";
    "presentation";"child_activations";"observed_at"] json in
  let* original_turn_ref = Ids.Turn_ref.of_yojson (List.assoc "original_turn_ref" fields)
  and* physical_turn_ref = Ids.Turn_ref.of_yojson (List.assoc "physical_turn_ref" fields) in
  let* raw_run = string "composition_run_id" fields in
  let* composition_run_id = Keeper_tool_plan.Composition_run_id.of_string raw_run
    |> Result.map_error (fun (Keeper_tool_plan.Composition_run_id.Invalid_uuid_v7 detail) -> detail) in
  let* logical_parent_tool_use_id = string "logical_parent_tool_use_id" fields
  and* request_id = string "request_id" fields in
  let* runtime_id = string "runtime_id" fields and* observed_at = string "observed_at" fields in
  let* status_invocation = invocation_of_json (List.assoc "status_invocation" fields) in
  let* boundary = object_fields ["kind";"agent_core_turn"] (List.assoc "boundary" fields) in
  let* kind = string "kind" boundary and* agent_core_turn = int "agent_core_turn" boundary in
  let* boundary = match kind with
    | "model_response" -> Ok (Types.Model_response {agent_core_turn})
    | "official_client_result_handoff" -> Ok (Types.Official_client_result_handoff {agent_core_turn})
    | _ -> Error "unknown physical handoff boundary" in
  let* receipt = object_fields ["tool_use_id";"content_bytes";"content_sha256"] (List.assoc "receipt" fields) in
  let* tool_use_id = string "tool_use_id" receipt and* content_bytes = int "content_bytes" receipt in
  let* content_sha256 = string "content_sha256" receipt in
  let receipt = Types.{tool_use_id;content_bytes;content_sha256} in
  let* presentation = string "presentation" fields in
  let* presentation = match presentation with "inline_result" -> Ok Inline_result
    | "manifest_reference" -> Ok Manifest_reference | _ -> Error "unknown result presentation" in
  let* child_activations = match List.assoc "child_activations" fields with
    | `List values -> List.fold_left (fun result json ->
        let* children = result in
        let* child = object_fields ["skill_tool_use_id";"activation_sha256"] json in
        let* skill_tool_use_id = string "skill_tool_use_id" child
        and* activation_sha256 = string "activation_sha256" child in
        Ok ({skill_tool_use_id;activation_sha256}::children)) (Ok []) values |> Result.map List.rev
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> Error "expected original child activation frames" in
  make ~original_turn_ref ~composition_run_id ~logical_parent_tool_use_id ~request_id ~physical_turn_ref
    ~runtime_id ~status_invocation ~boundary ~receipt ~presentation ~child_activations ~observed_at
