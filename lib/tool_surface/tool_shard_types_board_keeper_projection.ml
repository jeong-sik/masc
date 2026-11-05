(** Keeper-model input projections for Board capabilities.

    Public Board names and schemas are owned by [Board_tool_registry]. This
    module carries only the deliberately narrower Keeper-model input shape,
    read from the [keeper_projection] tables of the binary-embedded
    [config/tools/masc_board_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2); it is not part of the
    public or global schema aggregate. A missing file, a missing table, or a
    declaration that does not decode refuses the boot. *)

let projection_of_board_name board_name : Masc_domain.tool_schema =
  let name = Tool_name.Board_name.to_string board_name in
  match (Tool_definition_embedded.load name).Tool_definition_toml.keeper_projection with
  | Some schema -> schema
  | None ->
    failwith
      (Printf.sprintf
         "%s declares no keeper_projection table"
         (Tool_definition_embedded.path name))
;;

(* The eight curated Keeper projections. The other Board tools reach a
   Keeper through the canonical registry schema instead. *)
let schemas : Masc_domain.tool_schema list =
  List.map
    projection_of_board_name
    Tool_name.Board_name.
      [ Board_post
      ; Board_list
      ; Board_comment
      ; Board_vote
      ; Board_stats
      ; Board_search
      ; Board_curation_read
      ; Board_curation_submit
      ]
;;

let keeper_board_schema board_name =
  let name = Tool_name.Board_name.to_string board_name in
  List.find_opt
    (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
    schemas
;;
