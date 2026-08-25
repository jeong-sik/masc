(** Tool_shard_types_schemas_search_files — [search_files_tools] tool_search_files
    schema.

    [Grep] is ripgrep pattern search over the repo. Directory listing, file
    reads, find, and git views are done with the Execute tool. *)

let tool_search_files_schema : Masc_domain.tool_schema =
  Tool_shard_types_schemas_filesystem_toml.search_files
;;

let search_files_tools : Masc_domain.tool_schema list =
  [ tool_search_files_schema ]
;;
