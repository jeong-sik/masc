(** Tool_shard_types_schemas_filesystem — [filesystem_tools] tool_* file schemas + keeper_ide_annotate. *)

open Tool_shard_types_enum_mirrors

let filesystem_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_filesystem_toml.read_file
  ; Tool_shard_types_schemas_filesystem_toml.edit_file
  ; Tool_shard_types_schemas_filesystem_toml.write_file
  ; Tool_shard_types_schemas_filesystem_toml.ide_annotate
  ]
;;
