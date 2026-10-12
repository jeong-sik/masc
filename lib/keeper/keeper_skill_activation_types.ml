(* Canonical immutable Skill activation and summary data. *)

type task_id_set =
  | Task_ids of
      { first : Keeper_id.Task_id.t
      ; rest : Keeper_id.Task_id.t list
      }

type instruction_origin =
  | Task_instruction of { task_ids : task_id_set }
  | Session_instruction

type composition_origin =
  | Task_composition of
      { task_ids : task_id_set }
  | Session_composition

type delivery_boundary =
  | Model_response of { agent_core_turn : int }
  | Official_client_result_handoff of { agent_core_turn : int }

type delivery =
  { boundary : delivery_boundary
  ; runtime_id : string
  ; delivered_at : string
  ; content_bytes : int
  ; content_sha256 : string
  }

type tool_result_receipt =
  { tool_use_id : string
  ; content_bytes : int
  ; content_sha256 : string
  }

type action_identity = Runtime_native_tools.action_identity =
  | Call_id of string
  | Provider_step of
      { conversation_id : string
      ; step_index : int
      }

type action =
  { identity : action_identity
  ; tool_name : string
  ; runtime_id : string
  ; agent_core_turn : int
  ; observed_at : string
  }

type served_content =
  | Skill_body of
      { bytes : int
      ; sha256 : string
      }
  | Skill_resource of
      { relative_path : string
      ; bytes : int
      ; sha256 : string
      }

type invocation =
  | Instruction_invocation of
      { origin : instruction_origin
      ; served_content : served_content
      }
  | Composition_invocation of
      { origin : composition_origin
      ; tool_name : string
      }

type transition_rejection =
  | Delivery_order_rejected of
      { skill_tool_use_id : string
      ; activation_turn_ref : Ids.Turn_ref.t
      ; observed_turn_ref : Ids.Turn_ref.t
      ; activation_agent_core_turn : int
      ; observed_agent_core_turn : int
      ; observed_at : string
      }
  | Delivery_conflict_rejected of
      { skill_tool_use_id : string
      ; activation_turn_ref : Ids.Turn_ref.t
      ; observed_turn_ref : Ids.Turn_ref.t
      ; observed_agent_core_turn : int
      ; observed_at : string
      }
  | Action_before_delivery_rejected of
      { skill_tool_use_id : string
      ; activation_turn_ref : Ids.Turn_ref.t
      ; observed_turn_ref : Ids.Turn_ref.t
      ; action_identity : action_identity
      ; tool_name : string
      ; observed_agent_core_turn : int
      ; observed_at : string
      }

type activation =
  { identity : Skill_reference.identity
  ; content_revision : Skill_reference.content_revision
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; skill_tool_use_id : string
  ; agent_core_turn : int
  ; invocation : invocation
  ; delivery : delivery option
  ; actions : action list
  ; activated_at : string
  }

type summary =
  { instruction_invocations : int
  ; skill_bodies_served : int
  ; skill_resources_served : int
  ; instruction_provider_deliveries : int
  ; instruction_official_client_handoffs : int
  ; instruction_actions_observed : int
  ; composition_invocations : int
  ; composition_provider_deliveries : int
  ; composition_official_client_handoffs : int
  ; composition_actions_observed : int
  ; invalid_transitions : int
  }

type summary_scope =
  { snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; invocation_runtime_id : string
  ; reference : Skill_reference.t
  }

type runtime_count =
  { runtime_id : string
  ; count : int
  }

type scoped_summary =
  { scope : summary_scope
  ; summary : summary
  ; provider_delivery_runtime_counts : runtime_count list
  ; official_client_handoff_runtime_counts : runtime_count list
  ; action_runtime_counts : runtime_count list
  }

let rejection_skill_tool_use_id = function
  | Delivery_order_rejected { skill_tool_use_id; _ }
  | Delivery_conflict_rejected { skill_tool_use_id; _ }
  | Action_before_delivery_rejected { skill_tool_use_id; _ } ->
    skill_tool_use_id
;;
