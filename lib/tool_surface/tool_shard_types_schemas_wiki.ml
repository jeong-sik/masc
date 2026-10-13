(** Tool_shard_types_schemas_wiki — keeper_wiki_* tool schemas. *)

let wiki_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_wiki_toml.search
  ; Tool_shard_types_schemas_wiki_toml.read
  ]
;;
