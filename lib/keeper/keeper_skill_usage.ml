type use =
  | Composition_tool of string
  | Instruction_read of string

let instruction_tool_name = "keeper_skill"

let row_matches use row =
  match Safe_ops.json_string_opt "tool" row with
  | None -> false
  | Some tool ->
    (match use with
     | Composition_tool tool_name -> String.equal tool tool_name
     | Instruction_read skill_name ->
       String.equal tool instruction_tool_name
       &&
       (match Safe_ops.json_member_opt "input" row with
        | None -> false
        | Some input ->
          (match Safe_ops.json_string_opt "name" input with
           | Some name -> String.equal name skill_name
           | None -> false)))
;;

let count ~rows use =
  List.fold_left (fun acc row -> if row_matches use row then acc + 1 else acc) 0 rows
;;
