(** Tool_shard_types — pure types + enum-string SSOT mirrors extracted
    from Tool_shard (2165 LoC godfile).

    See tool_shard_types.mli for rationale and contract. *)

let pr_review_event_enum_strings = [ "COMMENT"; "APPROVE"; "REQUEST_CHANGES" ]

let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let memory_kind_enum_strings =
  [ "constraints"; "decision"; "next"; "goal"; "progress"; "open_question"; "long_term" ]
;;

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]

let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]

let vote_direction_enum_strings = [ "up"; "down" ]

let keeper_shell_op_enum_strings =
  [ "pwd"
  ; "ls"
  ; "cat"
  ; "rg"
  ; "git_status"
  ; "find"
  ; "head"
  ; "tail"
  ; "wc"
  ; "tree"
  ; "git_log"
  ; "git_diff"
  ; "git_worktree"
  ; "git_clone"
  ; "gh"
  ]
;;

type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap = Map.Make (String)

let select_named_schemas (names : string list) (schemas : Masc_domain.tool_schema list)
  : Masc_domain.tool_schema list
  =
  names
  |> List.filter_map (fun name ->
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      schemas)
;;

let default_shard_names : string list =
  [ "base"
  ; "board"
  ; "filesystem"
  ; "shell"
  ; "library"
  ; "taskboard"
  ; "coding"
  ]
;;

let tool_spec_read_only = [ "masc_tool_list" ]
let tool_spec_destructive = [ "masc_tool_grant"; "masc_tool_revoke" ]

let tool_required_permission = function
  | "masc_tool_list" -> Some Masc_domain.CanReadState
  | "masc_tool_grant" | "masc_tool_revoke" -> Some Masc_domain.CanAdmin
  | _ -> None
;;

let tool_effect_domain name =
  match Tool_name.of_string name with
  | Some (Tool_name.Masc Tool_name.Masc.Tool_list) -> Some Tool_catalog.Read_only
  | Some (Tool_name.Masc (Tool_name.Masc.Tool_grant | Tool_name.Masc.Tool_revoke)) ->
    Some Tool_catalog.Masc_coordination
  | _ -> None
;;
