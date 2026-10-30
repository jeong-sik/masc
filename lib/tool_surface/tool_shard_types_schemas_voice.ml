(** Tool_shard_types_schemas_voice — keeper_voice_* tool schemas. *)

let voice_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_voice_toml.speak
  ; Tool_shard_types_schemas_voice_toml.listen
  ; Tool_shard_types_schemas_voice_toml.agent
  ; Tool_shard_types_schemas_voice_toml.sessions
  ; Tool_shard_types_schemas_voice_toml.session_start
  ; Tool_shard_types_schemas_voice_toml.session_end
  ]
;;
