(** Board_tool_schemas - Board tool schema definitions, read from the
    binary-embedded [config/tools/masc_board_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    One file declares one tool; [schema_of_board_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or
    a declaration that does not decode refuses the boot instead of
    advertising a partial Board surface. *)

let schema_of_board_name board_name : Masc_domain.tool_schema =
  let name = Tool_name.Board_name.to_string board_name in
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let tool_post_create = schema_of_board_name Tool_name.Board_name.Board_post
let tool_post_edit = schema_of_board_name Tool_name.Board_name.Board_post_update
let tool_post_list = schema_of_board_name Tool_name.Board_name.Board_list
let tool_post_get = schema_of_board_name Tool_name.Board_name.Board_post_get
let tool_comment_add = schema_of_board_name Tool_name.Board_name.Board_comment
let tool_vote = schema_of_board_name Tool_name.Board_name.Board_vote
let tool_stats = schema_of_board_name Tool_name.Board_name.Board_stats
let tool_search = schema_of_board_name Tool_name.Board_name.Board_search
let tool_comment_vote = schema_of_board_name Tool_name.Board_name.Board_comment_vote
let tool_reaction = schema_of_board_name Tool_name.Board_name.Board_reaction
let tool_profile = schema_of_board_name Tool_name.Board_name.Board_profile
let tool_hearth_list = schema_of_board_name Tool_name.Board_name.Board_hearths

let tool_sub_board_create =
  schema_of_board_name Tool_name.Board_name.Board_sub_board_create
;;

let tool_sub_board_list =
  schema_of_board_name Tool_name.Board_name.Board_sub_board_list
;;

let tool_sub_board_get = schema_of_board_name Tool_name.Board_name.Board_sub_board_get

let tool_sub_board_update =
  schema_of_board_name Tool_name.Board_name.Board_sub_board_update
;;

let tool_sub_board_delete =
  schema_of_board_name Tool_name.Board_name.Board_sub_board_delete
;;
