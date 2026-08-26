type use =
  | Composition_tool of string
  | Instruction_read of string
  | Reference_read of string

let instruction_tool_name = "keeper_skill"

(* [keeper_skill] serves the body when it is called with a name alone and one
   of the skill's own files when [file] rides along, so the argument is what
   tells the two uses apart -- the tool name cannot. *)
let skill_row_named skill_name ~with_file row =
  String.equal
    (Option.value ~default:"" (Safe_ops.json_string_opt "tool" row))
    instruction_tool_name
  &&
  match Safe_ops.json_member_opt "input" row with
  | None -> false
  | Some input ->
    (match Safe_ops.json_string_opt "name" input with
     | None -> false
     | Some name ->
       String.equal name skill_name
       && Bool.equal with_file (Option.is_some (Safe_ops.json_string_opt "file" input)))
;;

let row_matches use row =
  match Safe_ops.json_string_opt "tool" row with
  | None -> false
  | Some tool ->
    (match use with
     | Composition_tool tool_name -> String.equal tool tool_name
     | Instruction_read skill_name -> skill_row_named skill_name ~with_file:false row
     | Reference_read skill_name -> skill_row_named skill_name ~with_file:true row)
;;

let count ~rows use =
  List.fold_left (fun acc row -> if row_matches use row then acc + 1 else acc) 0 rows
;;
