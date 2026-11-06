open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors

type ledger_revision = string
type workspace_key = string

type async_evidence =
  { result_deliveries : Keeper_skill_async_delivery.t list
  ; action_observations : Keeper_skill_async_action.t list
  }

module Delivery_identity_set = Set.Make (String)

(* The revision is the SHA-256 of the whole canonical ledger, so computing it
   costs a serialisation of every activation. A mutation does not need it --
   only a reader that projects or verifies the ledger does -- so it is computed
   on the first read and kept with the value. The fields it covers are
   immutable, so two readers that race to fill it write the same string. *)
type t =
  { workspace_key : workspace_key
  ; session_id : Keeper_id.Trace_id.t
  ; activations : activation list
  ; transition_rejections : transition_rejection list
  ; async_result_deliveries : Keeper_skill_async_delivery.t list
  ; async_actions : Keeper_skill_async_action.t list
  ; mutable revision_memo : ledger_revision option
  }

type record_outcome =
  | Recorded of activation
  | Already_recorded of activation

let activations ledger = ledger.activations
let transition_rejections ledger = ledger.transition_rejections
let async_result_deliveries ledger = ledger.async_result_deliveries
let async_actions ledger = ledger.async_actions
let ledger_revision_to_string revision = revision
let workspace_key ledger = ledger.workspace_key
let session_id ledger = ledger.session_id

let task_id_set_to_list (Task_ids { first; rest }) = first :: rest

let task_id_set_of_list task_ids =
  let rec duplicate = function
    | [] -> None
    | task_id :: rest ->
      if List.exists (Keeper_id.Task_id.equal task_id) rest
      then Some task_id
      else duplicate rest
  in
  match task_ids with
  | [] -> Error Empty_task_ids
  | first :: rest ->
    (match duplicate task_ids with
     | None -> Ok (Task_ids { first; rest })
     | Some task_id ->
       Error (Duplicate_task_id (Keeper_id.Task_id.to_string task_id)))
;;

let summarize ledger =
  Keeper_skill_activation_summary.summarize
    ~activations:ledger.activations
    ~async_result_deliveries:ledger.async_result_deliveries
    ~async_actions:ledger.async_actions
    ~transition_rejections:ledger.transition_rejections
;;

type catalog_usage =
  { invocations : int
  ; received_invocations : int
  ; observed_actions : int
  ; last_activated_at : string
  }

let usage_for_reference ledger reference =
  let matching = List.filter (fun (activation : activation) ->
    Skill_reference.equal reference
      (Skill_reference.make ~identity:activation.identity
         ~content_revision:activation.content_revision)) ledger.activations in
  match matching with
  | [] -> None
  | first :: rest ->
    let received_invocations, observed_actions = List.fold_left
      (fun (received, actions) activation ->
        let summary = Keeper_skill_activation_summary.summarize
          ~activations:[activation]
          ~async_result_deliveries:ledger.async_result_deliveries
          ~async_actions:ledger.async_actions ~transition_rejections:[] in
        let boundaries = summary.instruction_provider_deliveries
          + summary.instruction_official_client_handoffs
          + summary.composition_provider_deliveries
          + summary.composition_official_client_handoffs in
        received + (if boundaries > 0 then 1 else 0),
        actions + summary.instruction_actions_observed + summary.composition_actions_observed)
      (0, 0) matching in
    (* Constructors and decoders validate these instants before admitting
       activations. Offsets must be compared as time, not as wire text. *)
    let timestamp (activation : activation) =
      Time_codec.parse_rfc3339 activation.activated_at |> Result.get_ok in
    let _, latest = List.fold_left (fun (last, previous) candidate ->
      let at = timestamp candidate in
      if at > last then at, candidate else last, previous)
      (timestamp first, first) rest in
    Some { invocations = List.length matching; received_invocations; observed_actions
         ; last_activated_at = latest.activated_at }
;;

let summarize_by_scope ledger =
  Keeper_skill_activation_summary.summarize_by_scope
    ~activations:ledger.activations
    ~async_result_deliveries:ledger.async_result_deliveries
    ~async_actions:ledger.async_actions
    ~transition_rejections:ledger.transition_rejections
;;

let summary_to_yojson = Keeper_skill_activation_summary.summary_to_yojson
let scoped_summary_to_yojson = Keeper_skill_activation_summary.scoped_summary_to_yojson

let rejection_activation_turn_ref = function
  | Delivery_order_rejected { activation_turn_ref; _ }
  | Delivery_conflict_rejected { activation_turn_ref; _ }
  | Action_before_delivery_rejected { activation_turn_ref; _ } ->
    activation_turn_ref
;;

let validate_served_content = function
  | Skill_body { bytes; sha256 } ->
    if bytes < 0
    then Error (Invalid_served_content_bytes bytes)
    else
      Skill_reference.validate_revision_string sha256
      |> Result.map_error (fun error -> Invalid_served_content_sha256 error)
  | Skill_resource { relative_path; bytes; sha256 } ->
    let* () =
      Skill_resource_path.of_string relative_path
      |> Result.map ignore
      |> Result.map_error (fun _ -> Invalid_served_content_path relative_path)
    in
    if bytes < 0
    then Error (Invalid_served_content_bytes bytes)
    else
      Skill_reference.validate_revision_string sha256
      |> Result.map_error (fun error -> Invalid_served_content_sha256 error)
;;

let nested_composition_scope ~parent_tool_use_id ~composition_run_id ~alias =
  let* () = if String.equal (String.trim parent_tool_use_id) "" then
      Error (Invalid_nested_composition_scope "empty parent invocation ID") else Ok () in
  let* () = if String.equal alias "" then
      Error (Invalid_nested_composition_scope "empty child alias") else Ok () in
  let* composition_run_id = Random_id.parse_uuid_v7 composition_run_id
      |> Result.map_error (fun detail -> Invalid_nested_composition_scope detail) in
  Ok { parent_tool_use_id; composition_run_id; alias }
;;

let validate_nested_scope ~skill_tool_use_id scope =
  let* _ = nested_composition_scope ~parent_tool_use_id:scope.parent_tool_use_id
      ~composition_run_id:scope.composition_run_id ~alias:scope.alias in
  if String.equal skill_tool_use_id scope.parent_tool_use_id then
    Error (Invalid_nested_composition_scope "child and parent invocation IDs must differ")
  else Ok ()
;;

let make_activation_evidence
      ~(identity : Skill_reference.identity)
      ~content_revision
      ~snapshot_revision
      ~turn_ref
      ~runtime_id
      ~skill_tool_use_id
      ~agent_core_turn
      ~invocation
      ~activated_at
  =
  let trace_id = Ids.Turn_ref.trace_id turn_ref in
  let* canonical_name =
    Agent_core.Skill_document.canonical_name identity.name
    |> Result.map_error (fun _ -> Invalid_skill_name identity.name)
  in
  let* () =
    if String.equal canonical_name identity.name
    then Ok ()
    else Error (Invalid_skill_name identity.name)
  in
  let invocation_valid =
    match invocation with
    | Instruction_invocation { served_content; _ } ->
      validate_served_content served_content
    | Composition_invocation { tool_name; execution_id; _ } ->
      if not (Safe_identifier.is_portable_name tool_name) then Error (Invalid_tool_name tool_name)
      else if String.trim (Ids.Execution_id.to_string execution_id) = "" then Error Invalid_composition_execution_id
      else Ok ()
    | Nested_composition_invocation { tool_name; scope; _ } ->
      let* () = if Safe_identifier.is_portable_name tool_name then Ok () else Error (Invalid_tool_name tool_name) in
      validate_nested_scope ~skill_tool_use_id scope
  in
  let* () = invocation_valid in
  let* () =
    if String.equal (String.trim runtime_id) ""
    then Error Invalid_runtime_id
    else Ok ()
  in
  let* () =
    if String.equal (String.trim skill_tool_use_id) ""
    then Error Invalid_skill_tool_use_id
    else Ok ()
  in
  let* () =
    if agent_core_turn < 0
    then Error (Invalid_agent_core_turn agent_core_turn)
    else Ok ()
  in
  let* () =
    if String.equal trace_id "" || Ids.Turn_ref.absolute_turn turn_ref <= 0
    then Error (Invalid_turn_ref (Ids.Turn_ref.to_string turn_ref))
    else Ok ()
  in
  let* () =
    Time_codec.parse_rfc3339 activated_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_activated_at activated_at)
  in
  Ok
    { identity
    ; content_revision
    ; snapshot_revision
    ; turn_ref
    ; runtime_id
    ; skill_tool_use_id
    ; agent_core_turn
    ; invocation
    ; delivery = None
    ; actions = []
    ; activated_at
    }
;;

let make_activation
      ~identity
      ~content_revision
      ~snapshot_revision
      ~turn_ref
      ~runtime_id
      ~skill_tool_use_id
      ~agent_core_turn
      ~invocation
      ~activated_at
  =
  make_activation_evidence
    ~identity
    ~content_revision
    ~snapshot_revision
    ~turn_ref
    ~runtime_id
    ~skill_tool_use_id
    ~agent_core_turn
    ~invocation
    ~activated_at
;;

let workspace_key_of_root root =
  Agent_core_sha256.(digest_string root |> to_hex)
;;

let make ~workspace_key ~session_id ~activations ~transition_rejections ~async_result_deliveries ~async_actions =
  { workspace_key; session_id; activations; transition_rejections; async_result_deliveries; async_actions; revision_memo = None }
;;

let empty ~workspace_root ~trace_id =
  make
    ~workspace_key:(workspace_key_of_root workspace_root)
    ~session_id:trace_id
    ~activations:[]
    ~transition_rejections:[]
    ~async_result_deliveries:[]
    ~async_actions:[]
;;
