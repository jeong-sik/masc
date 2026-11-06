open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_model

let schema = "masc.skill-activations/v8"

let task_id_set_to_yojson task_ids =
  `List
    (List.map
       (fun task_id -> `String (Keeper_id.Task_id.to_string task_id))
       (task_id_set_to_list task_ids))
;;

let instruction_origin_to_yojson = function
  | Task_instruction { task_ids } ->
    `Assoc
      [ "kind", `String "task_instruction"
      ; "task_ids", task_id_set_to_yojson task_ids
      ]
  | Session_instruction -> `Assoc [ "kind", `String "session_instruction" ]
;;

let composition_origin_to_yojson = function
  | Task_composition { task_ids } ->
    `Assoc
      [ "kind", `String "task_composition"
      ; "task_ids", task_id_set_to_yojson task_ids
      ]
  | Session_composition -> `Assoc [ "kind", `String "session_composition" ]
;;

let delivery_boundary_to_yojson = function
  | Model_response { agent_core_turn } ->
    `Assoc
      [ "kind", `String "model_response"
      ; "agent_core_turn", `Int agent_core_turn
      ]
  | Official_client_result_handoff { agent_core_turn } ->
    `Assoc
      [ "kind", `String "official_client_result_handoff"
      ; "agent_core_turn", `Int agent_core_turn
      ]
;;

let delivery_to_yojson (delivery : delivery) =
  `Assoc
    [ "boundary", delivery_boundary_to_yojson delivery.boundary
    ; "runtime_id", `String delivery.runtime_id
    ; "delivered_at", `String delivery.delivered_at
    ; "content_bytes", `Int delivery.content_bytes
    ; "content_sha256", `String delivery.content_sha256
    ]
;;

let action_identity_to_yojson = function
  | Call_id call_id ->
    `Assoc [ "kind", `String "call_id"; "call_id", `String call_id ]
  | Provider_step { conversation_id; step_index } ->
    `Assoc
      [ "kind", `String "provider_step"
      ; "conversation_id", `String conversation_id
      ; "step_index", `Int step_index
      ]
;;

let action_to_yojson (action : action) =
  `Assoc
    [ "identity", action_identity_to_yojson action.identity
    ; "tool_name", `String action.tool_name
    ; "runtime_id", `String action.runtime_id
    ; "agent_core_turn", `Int action.agent_core_turn
    ; "observed_at", `String action.observed_at
    ]
;;

let served_content_to_yojson = function
  | Skill_body { bytes; sha256 } ->
    `Assoc
      [ "kind", `String "skill_body"
      ; "bytes", `Int bytes
      ; "sha256", `String sha256
      ]
  | Skill_resource { relative_path; bytes; sha256 } ->
    `Assoc
      [ "kind", `String "skill_resource"
      ; "relative_path", `String relative_path
      ; "bytes", `Int bytes
      ; "sha256", `String sha256
      ]
;;

let invocation_to_yojson = function
  | Instruction_invocation { origin; served_content } ->
    `Assoc
      [ "kind", `String "instruction"
      ; "origin", instruction_origin_to_yojson origin
      ; "served_content", served_content_to_yojson served_content
      ]
  | Composition_invocation { origin; tool_name; execution_id } ->
    `Assoc
      [ "kind", `String "composition"
      ; "origin", composition_origin_to_yojson origin
      ; "execution_id", Ids.Execution_id.to_yojson execution_id
      ; "tool_name", `String tool_name
      ]
  | Nested_composition_invocation { origin; tool_name; scope } ->
    `Assoc
      [ "kind", `String "nested_composition"
      ; "origin", composition_origin_to_yojson origin
      ; "tool_name", `String tool_name
      ; "scope", `Assoc [ "parent_tool_use_id", `String scope.parent_tool_use_id
          ; "composition_run_id", `String scope.composition_run_id; "alias", `String scope.alias ]
      ]
;;

let transition_rejection_to_yojson = function
  | Delivery_order_rejected
      { skill_tool_use_id
      ; activation_turn_ref
      ; observed_turn_ref
      ; activation_agent_core_turn
      ; observed_agent_core_turn
      ; observed_at
      } ->
    `Assoc
      [ "kind", `String "delivery_order"
      ; "skill_tool_use_id", `String skill_tool_use_id
      ; "activation_turn_ref", Ids.Turn_ref.to_yojson activation_turn_ref
      ; "observed_turn_ref", Ids.Turn_ref.to_yojson observed_turn_ref
      ; "activation_agent_core_turn", `Int activation_agent_core_turn
      ; "observed_agent_core_turn", `Int observed_agent_core_turn
      ; "observed_at", `String observed_at
      ]
  | Delivery_conflict_rejected
      { skill_tool_use_id
      ; activation_turn_ref
      ; observed_turn_ref
      ; observed_agent_core_turn
      ; observed_at
      } ->
    `Assoc
      [ "kind", `String "delivery_conflict"
      ; "skill_tool_use_id", `String skill_tool_use_id
      ; "activation_turn_ref", Ids.Turn_ref.to_yojson activation_turn_ref
      ; "observed_turn_ref", Ids.Turn_ref.to_yojson observed_turn_ref
      ; "observed_agent_core_turn", `Int observed_agent_core_turn
      ; "observed_at", `String observed_at
      ]
  | Action_before_delivery_rejected
      { skill_tool_use_id
      ; activation_turn_ref
      ; observed_turn_ref
      ; action_identity
      ; tool_name
      ; observed_agent_core_turn
      ; observed_at
      } ->
    `Assoc
      [ "kind", `String "action_before_delivery"
      ; "skill_tool_use_id", `String skill_tool_use_id
      ; "activation_turn_ref", Ids.Turn_ref.to_yojson activation_turn_ref
      ; "observed_turn_ref", Ids.Turn_ref.to_yojson observed_turn_ref
      ; "action_identity", action_identity_to_yojson action_identity
      ; "tool_name", `String tool_name
      ; "observed_agent_core_turn", `Int observed_agent_core_turn
      ; "observed_at", `String observed_at
      ]
;;

let activation_to_yojson activation =
  `Assoc
    [ "identity", Skill_reference.identity_to_yojson activation.identity
    ; ( "content_revision"
      , `String
          (Skill_reference.content_revision_to_string activation.content_revision) )
    ; ( "snapshot_revision"
      , `String
          (Skill_catalog_snapshot.snapshot_revision_to_string
             activation.snapshot_revision) )
    ; "turn_ref", Ids.Turn_ref.to_yojson activation.turn_ref
    ; "runtime_id", `String activation.runtime_id
    ; "skill_tool_use_id", `String activation.skill_tool_use_id
    ; "agent_core_turn", `Int activation.agent_core_turn
    ; "invocation", invocation_to_yojson activation.invocation
    ; ( "delivery"
      , match activation.delivery with
        | Some delivery -> delivery_to_yojson delivery
        | None -> `Null )
    ; "actions", `List (List.map action_to_yojson activation.actions)
    ; "activated_at", `String activation.activated_at
    ]
;;

(* What an activation records when it is made. Its delivery and actions
   arrive later, by their own events, so whether a repeated recording is the
   same invocation is judged on this part alone. *)
let recorded_part (activation : activation) =
  { activation with delivery = None; actions = [] }
;;

let activation_frame_to_yojson activation = activation_to_yojson (recorded_part activation)

let activation_frame_sha256 activation =
  Agent_core_sha256.(digest_string (Yojson.Safe.to_string (activation_frame_to_yojson activation)) |> to_hex)
;;

let async_evidence_for_activation ledger (activation : activation) =
  let frame_sha256 = activation_frame_sha256 activation in
  let result_deliveries =
    List.filter (fun (delivery : Keeper_skill_async_delivery.t) ->
      List.exists (fun (child : Keeper_skill_async_delivery.child_activation) ->
        String.equal child.skill_tool_use_id activation.skill_tool_use_id
        && String.equal child.activation_sha256 frame_sha256)
        delivery.child_activations) ledger.async_result_deliveries
  in
  let identities = List.fold_left (fun identities delivery ->
    Delivery_identity_set.add (Keeper_skill_async_delivery.identity delivery) identities)
    Delivery_identity_set.empty result_deliveries in
  let action_observations = List.filter (fun (action : Keeper_skill_async_action.t) ->
    Delivery_identity_set.mem action.delivery_sha256 identities) ledger.async_actions in
  { result_deliveries; action_observations }
;;

let revision_of_ledger ~workspace_key ~session_id ~activations ~transition_rejections ~async_result_deliveries ~async_actions =
  let canonical =
    `Assoc
      [ "workspace_key", `String workspace_key
      ; "session_id", `String (Keeper_id.Trace_id.to_string session_id)
      ; "activations", `List (List.map activation_to_yojson activations)
      ; ( "transition_rejections"
        , `List (List.map transition_rejection_to_yojson transition_rejections) )
      ; "async_result_deliveries", `List (List.map Keeper_skill_async_delivery.to_json async_result_deliveries)
      ; "async_actions", `List (List.map Keeper_skill_async_action.to_json async_actions)
      ]
  in
  Agent_core_sha256.(digest_string (Yojson.Safe.to_string canonical) |> to_hex)
;;

let revision ledger =
  match ledger.revision_memo with
  | Some revision -> revision
  | None ->
    let revision =
      revision_of_ledger
        ~workspace_key:ledger.workspace_key
        ~session_id:ledger.session_id
        ~activations:ledger.activations
        ~transition_rejections:ledger.transition_rejections
        ~async_result_deliveries:ledger.async_result_deliveries
    ~async_actions:ledger.async_actions
    in
    ledger.revision_memo <- Some revision;
    revision
;;

let receipt_projection_revision ledger ~skill_tool_use_id =
  let buffer = Buffer.create 160 in
  let add field value =
    Buffer.add_string buffer (string_of_int (String.length field));
    Buffer.add_char buffer ':';
    Buffer.add_string buffer field;
    Buffer.add_string buffer (string_of_int (String.length value));
    Buffer.add_char buffer ':';
    Buffer.add_string buffer value
  in
  add "ledger_revision" (revision ledger);
  add "skill_tool_use_id" skill_tool_use_id;
  Agent_core_sha256.(digest_string (Buffer.contents buffer) |> to_hex)
;;

let to_yojson ledger =
  `Assoc
    [ "schema", `String schema
    ; "workspace_key", `String ledger.workspace_key
    ; "session_id", `String (Keeper_id.Trace_id.to_string ledger.session_id)
    ; "revision", `String (revision ledger)
    ; "activations", `List (List.map activation_to_yojson ledger.activations)
    ; ( "transition_rejections"
      , `List
          (List.map transition_rejection_to_yojson ledger.transition_rejections) )
    ; "async_result_deliveries", `List (List.map Keeper_skill_async_delivery.to_json ledger.async_result_deliveries)
    ; "async_actions", `List (List.map Keeper_skill_async_action.to_json ledger.async_actions)
    ]
;;
