(** Durable, session-scoped evidence of exact Skill activations. *)

type ledger_revision = private string

type instruction_origin =
  | Task_instruction of { task_id : Keeper_id.Task_id.t }
  | Session_instruction

type composition_origin =
  | Task_composition of
      { task_id : Keeper_id.Task_id.t }
  | Session_composition

type delivery =
  { agent_core_turn : int
  ; delivered_at : string
  }

type action =
  { tool_use_id : string
  ; tool_name : string
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
      ; action_tool_use_id : string
      ; tool_name : string
      ; observed_agent_core_turn : int
      ; observed_at : string
      }

type activation = private
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

type t

type summary =
  { instruction_invocations : int
  ; skill_bodies_served : int
  ; skill_resources_served : int
  ; instruction_deliveries : int
  ; instruction_actions_observed : int
  ; composition_invocations : int
  ; composition_deliveries : int
  ; composition_actions_observed : int
  ; invalid_transitions : int
  }

type summary_scope =
  { snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; reference : Skill_reference.t
  }

type scoped_summary =
  { scope : summary_scope
  ; summary : summary
  }

type record_outcome =
  | Recorded of activation
  | Already_recorded of activation

type decode_error =
  | Expected_object of { field : string }
  | Missing_string of { field : string }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Unsupported_schema of string
  | Invalid_source_id of string
  | Invalid_skill_name of string
  | Invalid_package_id of Skill_reference.package_id_error
  | Invalid_content_revision of Skill_reference.revision_error
  | Invalid_snapshot_revision of Skill_catalog_snapshot.revision_error
  | Invalid_workspace_key of Skill_catalog_snapshot.revision_error
  | Invalid_session_id of string
  | Invalid_origin_kind of string
  | Invalid_task_id of string
  | Invalid_tool_name of string
  | Invalid_turn_ref of string
  | Turn_ref_session_mismatch
  | Invalid_runtime_id
  | Invalid_skill_tool_use_id
  | Invalid_agent_core_turn of int
  | Invalid_served_content_kind of string
  | Invalid_served_content_path of string
  | Invalid_served_content_bytes of int
  | Invalid_served_content_sha256 of Skill_reference.revision_error
  | Invalid_delivery_agent_core_turn of int
  | Invalid_delivery_time of string
  | Invalid_action_tool_use_id_field
  | Invalid_action_tool_name_field of string
  | Invalid_action_agent_core_turn of int
  | Invalid_action_time of string
  | Invalid_transition_rejection_kind of string
  | Orphan_transition_rejection of string
  | Transition_rejection_activation_mismatch of string
  | Duplicate_action_tool_use_id
  | Invalid_activated_at of string
  | Duplicate_skill_tool_use_id
  | Session_id_mismatch
  | Workspace_key_mismatch
  | Invalid_ledger_revision of Skill_catalog_snapshot.revision_error
  | Ledger_revision_mismatch

type store_error =
  | Lock_failed of string
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Decode_failed of decode_error
  | Invocation_id_collision of string
  | Invalid_delivery_order of
      { skill_tool_use_id : string
      ; activation_turn : int
      ; delivery_turn : int
      }
  | Conflicting_delivery of string
  | Action_before_delivery of string
  | Invalid_action_tool_use_id
  | Invalid_action_tool_name of string
  | Invalid_action_turn of int
  | Invalid_action_observed_at of string
  | Write_failed of Keeper_fs.durable_write_error
  | Readback_mismatch

val store_error_to_string : store_error -> string
val store_error_code : store_error -> string
val decode_error_code : decode_error -> string

val empty : workspace_root:string -> trace_id:Keeper_id.Trace_id.t -> t
val activations : t -> activation list
val transition_rejections : t -> transition_rejection list
val revision : t -> ledger_revision
val ledger_revision_to_string : ledger_revision -> string
val workspace_key : t -> string
val session_id : t -> Keeper_id.Trace_id.t
val summarize : t -> summary
val summary_to_yojson : summary -> Yojson.Safe.t
val summarize_by_scope : t -> scoped_summary list
val scoped_summary_to_yojson : scoped_summary -> Yojson.Safe.t

val make_activation :
  identity:Skill_reference.identity ->
  content_revision:Skill_reference.content_revision ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  turn_ref:Ids.Turn_ref.t ->
  runtime_id:string ->
  skill_tool_use_id:string ->
  agent_core_turn:int ->
  invocation:invocation ->
  activated_at:string ->
  (activation, decode_error) result

val to_yojson : t -> Yojson.Safe.t
val of_projection_yojson : Yojson.Safe.t -> (t, decode_error) result
(** Strictly decode the self-contained dashboard projection. This verifies the
    schema, exact fields, typed ids, activation invariants, uniqueness, and
    derived ledger revision. It does not assert which workspace requested the
    projection; callers with that authority use {!of_yojson}. *)
val of_yojson :
  expected_workspace_root:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (t, decode_error) result

val load :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  (t, store_error) result

val record :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  activation ->
  (t * record_outcome, store_error) result
(** Record one exact Agent Core invocation. Re-observing the same
    [skill_tool_use_id] is idempotent only when every persisted field agrees.
    A later invocation of the same Skill remains a distinct activation. *)

val observe_delivery :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  tool_result_ids:string list ->
  agent_core_turn:int ->
  delivered_at:string ->
  (t * string list, store_error) result
(** Mark exact Skill results that are present in a later provider request.
    Unrelated tool-result ids are ignored. The returned ids are the matching
    Skill invocations, including an idempotently re-observed delivery. *)

val observe_action :
  config:Workspace.config ->
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  active_skill_tool_use_ids:string list ->
  action_tool_use_id:string ->
  tool_name:string ->
  agent_core_turn:int ->
  observed_at:string ->
  (t * int, store_error) result
(** Attach one later model-selected tool invocation to every exact delivered
    Skill id in [active_skill_tool_use_ids]. The count is the number of Skill
    activations updated; repeating the same action id is idempotent. *)
