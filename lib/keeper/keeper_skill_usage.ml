type use =
  | Composition_tool of string
  | Instruction_read of string

type summary =
  { use_count : int
  ; success_count : int
  ; failure_count : int
  }

let instruction_tool_name = "keeper_skill"
let composition_run_summary_tool_name = "keeper_composition_run_summary"

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

let outcome_matches use row =
  match use with
  | Instruction_read _ -> row_matches use row
  | Composition_tool composition_tool ->
    Safe_ops.json_string_opt "record_kind" row = Some "composition_run"
    && Safe_ops.json_string_opt "tool" row = Some composition_run_summary_tool_name
    && Safe_ops.json_string_opt "composition_tool" row = Some composition_tool
;;

let row_outcome row =
  match Safe_ops.json_string_opt "disposition" row with
  | Some "completed" -> Some true
  | Some "failed" -> Some false
  | Some "deferred" -> None
  | Some _ | None -> Safe_ops.json_bool_opt "success" row
;;

let summarize ~rows use =
  List.fold_left
    (fun summary row ->
       let use_count =
         summary.use_count + if row_matches use row then 1 else 0
       in
       if not (outcome_matches use row)
       then { summary with use_count }
       else
         match row_outcome row with
         | Some true ->
           { use_count
           ; success_count = summary.success_count + 1
           ; failure_count = summary.failure_count
           }
         | Some false ->
           { use_count
           ; success_count = summary.success_count
           ; failure_count = summary.failure_count + 1
           }
         | None -> { summary with use_count })
    { use_count = 0; success_count = 0; failure_count = 0 }
    rows
;;
