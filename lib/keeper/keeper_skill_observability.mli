(** Operator-facing facts about one effective instruction Skill. *)

type surface =
  | Instruction_skill

val kind_label : surface -> string
val execution_label : surface -> string
val surfaces : surface list

type io =
  | Model_orchestrated

type profile = private
  { reference : Skill_reference.t
  ; surface : surface
  ; activation_tool : string
  ; body_bytes : int
  ; discovery_bytes : int
  ; tool_schema_bytes : int option
  ; node_count : int
  ; batch_count : int
  ; parallel_batch_count : int
  ; max_parallelism : int
  ; statically_read_only : bool option
  ; io : io
  }

val of_skill_with_reference : Skill_reference.t -> Keeper_skill_catalog.skill -> profile
val of_catalog : Keeper_skill_catalog.t -> profile list
val to_yojson : profile -> Yojson.Safe.t
val to_fields : profile -> (string * Yojson.Safe.t) list
val tool_component_bytes : Agent_core.Tool.t -> int
