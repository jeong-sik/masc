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
    native_posture:Runtime_native_tools.posture option ->
    tool_groups:string list option ->
    current_task_id:string option ->
    task_skill_names:string list ->
    skill_catalog:Keeper_skill_catalog.t ->
    (t, string * string) result
  (** Pure projection seam.  The error pair is [(reason, detail)]. *)
end
