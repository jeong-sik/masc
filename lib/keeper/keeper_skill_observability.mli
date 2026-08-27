(** Operator-facing, execution-derived facts about one effective Skill.

    Counts come from the same validated plan and descriptor-aware schedule as
    execution. They are not inferred from prose, names, or historical logs. *)

type profile = private
  { reference : Skill_reference.t
  ; kind : string
  ; activation_tool : string
  ; execution : string
  ; body_bytes : int
  ; eager_body_bytes : int
  ; discovery_bytes : int
  ; tool_schema_bytes : int option
  ; node_count : int
  ; batch_count : int
  ; parallel_batch_count : int
  ; max_parallelism : int
  ; statically_read_only : bool option
  ; declaration_span : Keeper_skill_body_ast.span option
  }

val of_skill : Keeper_skill_catalog.skill -> profile option
val of_catalog : Keeper_skill_catalog.t -> profile list
val to_yojson : profile -> Yojson.Safe.t

val tool_component_bytes : Agent_core.Tool.t -> int
(** Exact name + description + serialized input-schema bytes used by official
    client runtime measurements. JSON request-envelope framing is excluded. *)
