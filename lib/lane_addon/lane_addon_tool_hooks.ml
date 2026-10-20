type hook = Lane_addon_types.tool_hook = Validate_input | Validate_output
let hook_name = function Validate_input -> "validate_input" | Validate_output -> "validate_output"
let hook_of_string = function
  | "validate_input" -> Some Validate_input
  | "validate_output" -> Some Validate_output
  | _ -> None
type t = { name : string; checks : (hook * Yojson.Safe.t) list }
let ( let* ) = Result.bind
let selection_of_json = function
  | `List values ->
      let rec loop hooks = function
        | [] -> Ok (List.rev hooks)
        | `String name :: rest ->
            let* hook = match hook_of_string name with
              | Some hook -> Ok hook | None -> Error ("unknown tool hook: " ^ name) in
            if List.mem hook hooks then Error "duplicate tool hook" else loop (hook :: hooks) rest
        | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) :: _ ->
            Error "tool hooks require string names" in
      loop [] values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      Error "tool hooks require an array"
let prepare ~hooks (tool : Mcp_protocol.Mcp_types.tool) =
  let rec loop checks = function
    | [] -> Ok { name = tool.name; checks = List.rev checks }
    | hook :: rest ->
        let* schema = match hook with
          | Validate_input -> Ok tool.input_schema
          | Validate_output -> (match tool.output_schema with
              | Some schema -> Ok schema
              | None -> Error (tool.name ^ ": validate_output requires outputSchema")) in
        let* () = Lane_addon_action.validate_value_schema schema
          |> Result.map_error (fun detail -> tool.name ^ ": " ^ hook_name hook ^ ": " ^ detail) in
        loop ((hook, schema) :: checks) rest in
  loop [] hooks
let check t schema value =
  Lane_addon_action.validate_value ~schema ~name:t.name value |> Result.map (fun _ -> ())
let before_call t arguments =
  List.fold_left (fun result (hook, schema) ->
    let* () = result in
    match hook with
    | Validate_input -> check t schema arguments
    | Validate_output -> Ok ()) (Ok ()) t.checks
let after_call t (result : Mcp_protocol.Mcp_types.tool_result) =
  match result.is_error with
  | Some true -> Ok ()
  | None | Some false ->
      List.fold_left (fun checked (hook, schema) ->
        let* () = checked in
        match hook with
        | Validate_input -> Ok ()
        | Validate_output -> (match result.structured_content with
            | None -> Error (t.name ^ ": successful result requires structuredContent")
            | Some value -> check t schema value)) (Ok ()) t.checks
