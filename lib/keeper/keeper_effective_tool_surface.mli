(** Read-only projection of the exact dynamic tool surface prepared for one
    Keeper turn.  This module consumes the same descriptor, SKILL.md, runtime,
    and native-posture authorities as the turn path; it does not infer a
    Keeper surface from the global MCP registry. *)

type tool_origin =
  | Descriptor of { group : string }
  | Instruction_skill
  | Composition_skill of
      { provenance : Keeper_skill_catalog.provenance option }
  | Composition_plan
  | Composition_control

type tool =
  { name : string
  ; origin : tool_origin
  }

type tool_delivery =
  | Tools_delivered
  | Tools_suppressed_runtime_unsupported

type t =
  { keeper_name : string
  ; runtime_id : string
  ; official_client_kind : string
  ; tool_delivery : tool_delivery
  ; native_posture : Runtime_native_tools.posture option
  ; tool_groups : string list
  ; current_task_id : string option
  ; skill_snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; skill_resource_read_max_bytes : int option
  ; instruction_skills : Skill_reference.t list
  ; composition_skills : Skill_reference.t list
  ; skill_profiles : Keeper_skill_observability.profile list
  ; tool_surface_bytes : int
  ; skill_tool_surface_bytes : int
  ; skill_body_bytes : int
  ; skills_left_out : string list
        (** Documents the catalog could not read, by the directory they were
            found in and why. This surface answers "what can this Keeper
            call"; a skill left out is absent from that answer, and absence
            with no reason beside it reads as a skill nobody wrote. *)
  ; tools : tool list
  ; tool_surface_sha256 : string option
  }

type unavailable =
  { keeper_name : string
  ; reason : string
  ; detail : string
  }

type outcome =
  | Available of t
  | Unavailable of unavailable

val resolve : config:Workspace.config -> keeper_name:string -> outcome
val to_yojson : outcome -> Yojson.Safe.t

module For_testing : sig
  val project :
    keeper_name:string ->
    runtime_id:string ->
    skills_left_out:string list ->
    official_client_kind:string ->
    tool_delivery:tool_delivery ->
    native_posture:Runtime_native_tools.posture option ->
    tool_groups:string list option ->
    current_task_id:string option ->
    task_skill_references:Skill_reference.t list ->
    task_selection:Keeper_task_skill_turn.t option ->
    skill_snapshot:Skill_catalog_snapshot.t ->
    (t, Keeper_task_skill_turn.error) result
  (** Pure projection seam over one frozen Task/snapshot pair. *)
end
