(** Read-only projection of the exact dynamic tool surface prepared for one
    Keeper turn.  This module consumes the same descriptor, SKILL.md, runtime,
    and native-posture authorities as the turn path; it does not infer a
    Keeper surface from the global MCP registry. *)

type tool_origin =
  | Descriptor of { group : string }
  | Instruction_skill
  | Composition_skill of { source : string }
  | Composition_plan
  | Composition_control

type tool =
  { name : string
  ; origin : tool_origin
  }

type t =
  { keeper_name : string
  ; runtime_id : string
  ; official_client_kind : string
  ; native_posture : Runtime_native_tools.posture option
  ; tool_groups : string list
  ; current_task_id : string option
  ; instruction_skills : string list
  ; composition_skills : string list
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
    official_client_kind:string ->
    native_posture:Runtime_native_tools.posture option ->
    tool_groups:string list option ->
    current_task_id:string option ->
    task_skill_names:string list ->
    skill_catalog:Keeper_skill_catalog.t ->
    (t, string * string) result
  (** Pure projection seam.  The error pair is [(reason, detail)]. *)
end
