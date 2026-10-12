let key = "io.github.jeong-sik/masc.lane.failure"

let metadata result =
  let fields = match Tool_result.metadata result with
    | Some (`Assoc fields) -> List.filter (fun (name, _) -> name <> key) fields
    | None | Some _ -> [] in
  let fields = match result with
    | Tool_result.Failed failure ->
        (key, `Assoc [
          "class", `String (Tool_result.tool_failure_class_to_string failure.class_);
          "effect", `String (Tool_result.failure_effect_disposition_to_string failure.effect_disposition)]) :: fields
    | Completed _ | Deferred _ -> fields in
  match fields with [] -> None | _ -> Some (`Assoc fields)

let failure (result : Mcp_protocol.Mcp_types.tool_result) =
  let unknown = Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown in
  match result.is_error, result._meta with
  | Some true, Some (`Assoc fields) ->
      (match List.filter (fun (name, _) -> name = key) fields with
       | [_, `Assoc fields] when List.length fields = 2 ->
           (match List.assoc_opt "class" fields, List.assoc_opt "effect" fields with
            | Some (`String class_), Some (`String disposition) ->
                (match Tool_result.tool_failure_class_of_string class_,
                       Tool_result.failure_effect_disposition_of_string disposition with
                 | Some class_, Some disposition -> class_, disposition
                 | _ -> unknown)
            | _ -> unknown)
       | _ -> unknown)
  | _ -> unknown
