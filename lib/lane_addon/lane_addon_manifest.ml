open Lane_addon_types
let ( let* ) = Result.bind
type error = Invalid_manifest of string | Io_failure of string
let error_to_string = function Invalid_manifest detail | Io_failure detail -> detail
let output_ports world =
  let parse_port (id, value) =
    let* () = if String.trim id = "" then Error "world.outputs has a blank port name" else Ok () in
    let* selection = match value with
      | Otoml.TomlTable ["all_lanes", Otoml.TomlBoolean true]
      | Otoml.TomlInlineTable ["all_lanes", Otoml.TomlBoolean true] -> Ok All_lanes
      | Otoml.TomlTable ["lanes", Otoml.TomlArray values]
      | Otoml.TomlInlineTable ["lanes", Otoml.TomlArray values] ->
          let rec read acc = function
            | [] -> Ok (List.rev acc)
            | Otoml.TomlString lane :: rest when String.trim lane <> "" -> read (lane :: acc) rest
            | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
              | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
              | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
              | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _
              | Otoml.TomlTableArray _ ) :: _ ->
                Error ("world.outputs." ^ id ^ ".lanes requires non-blank lane IDs") in
          let* lanes = read [] values in
          if lanes = [] || List.length lanes <> List.length (List.sort_uniq String.compare lanes)
          then Error ("world.outputs." ^ id ^ ".lanes requires a non-empty list of unique lane IDs")
          else Ok (Selected_lanes (List.sort String.compare lanes))
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
      | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
          Error ("world.outputs." ^ id ^ " requires only lanes or all_lanes = true") in
    Ok (id, selection) in
  match List.assoc_opt "outputs" world with
  | None -> Ok []
  | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
      let names = List.map fst fields in
      if fields = [] || List.length names <> List.length (List.sort_uniq String.compare names)
      then Error "world.outputs requires unique named ports"
      else List.fold_left (fun result field ->
        let* ports = result in let* port = parse_port field in Ok (port :: ports)) (Ok []) fields
        |> Result.map (List.sort (fun (a, _) (b, _) -> String.compare a b))
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> Error "world.outputs must be a table"
(* [world.exact_outputs.<name>] schema = "<path>": the schema file ships in the
   package, so it is read here and becomes part of the package value. The path is
   package-relative like world.skills.directory and must stay inside the package
   after symlinks resolve. *)
let exact_outputs ~directory world =
  (* The runtime lane key relies on this name rule, so both read it from one place. *)
  let valid_name = Runtime_schema.exact_output_name_valid in
  let read_schema name path =
    let label = "world.exact_outputs." ^ name ^ ".schema" in
    let* relative = Skill_resource_path.of_string path
      |> Result.map_error (fun error -> label ^ ": " ^ Skill_resource_path.error_to_string error) in
    (* A path that does not exist is the package's mistake and names this field;
       any other failure to resolve it stays an I/O failure of the load. *)
    let* resolved = match Unix.realpath (Skill_resource_path.append_to ~root:directory relative) with
      | resolved -> Ok resolved
      | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR) as error, _, _) ->
          Error (label ^ ": " ^ Unix.error_message error) in
    let* () = if String.starts_with ~prefix:(directory ^ Filename.dir_sep) resolved then Ok ()
      else Error (label ^ " resolves outside the package directory") in
    let* () = match (Unix.stat resolved).Unix.st_kind with
      | Unix.S_REG -> Ok ()
      | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
          Error (label ^ " names something that is not a file") in
    let* schema = try Ok (Yojson.Safe.from_file resolved)
      with Yojson.Json_error detail -> Error (label ^ ": " ^ detail) in
    let* () = Lane_addon_action.validate_value_schema schema
      |> Result.map_error (fun detail -> label ^ ": " ^ detail) in
    match schema with
    | `Assoc fields when List.assoc_opt "type" fields = Some (`String "object") -> Ok schema
    | _ -> Error (label ^ " must describe an object") in
  let parse_output (name, value) =
    let* () = if valid_name name then Ok ()
      else Error ("world.exact_outputs." ^ name ^ " requires a name of a-z, 0-9 and _ starting with a letter") in
    match value with
    | Otoml.TomlTable ["schema", Otoml.TomlString path]
    | Otoml.TomlInlineTable ["schema", Otoml.TomlString path] ->
        let* schema = read_schema name path in Ok { name; schema }
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
    | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
        Error ("world.exact_outputs." ^ name ^ " requires only a schema path") in
  match List.assoc_opt "exact_outputs" world with
  | None -> Ok []
  | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
      let names = List.map fst fields in
      if fields = [] || List.length names <> List.length (List.sort_uniq String.compare names)
      then Error "world.exact_outputs requires unique named outputs"
      else List.fold_left (fun result field ->
        let* outputs = result in let* output = parse_output field in Ok (output :: outputs)) (Ok []) fields
        |> Result.map (List.sort (fun (a : exact_output) b -> String.compare a.name b.name))
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> Error "world.exact_outputs must be a table"
let load ~path =
  let parse () =
    let path = Unix.realpath path in
    let document = Otoml.Parser.from_file path in
    let read key convert =
      try match Otoml.find_opt document convert key with
        | Some value -> Ok value
        | None -> Error ("missing " ^ String.concat "." key)
      with Otoml.Type_error message -> Error (String.concat "." key ^ ": " ^ message)
         | Not_found -> Error ("missing " ^ String.concat "." key)
    in
    let text key =
      let* value = read key Otoml.get_string in
      if String.trim value = "" then Error (String.concat "." key ^ " is blank") else Ok value
    in
    let* world = match Otoml.find_opt document Fun.id ["world"] with
      | None -> Ok []
      | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
          let names = List.map fst fields in
          if List.length names <> List.length (List.sort_uniq String.compare names)
             || List.exists (fun key -> not (List.mem key ["skills"; "actions"; "outputs"; "tools"; "state"; "exact_outputs"; "asks"])) names
          then Error "world accepts skills, actions, outputs, tools, state and exact_outputs tables" else Ok fields
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> Error "world must be a table" in
    let nested_text section key = match List.assoc_opt section world with
      | None -> Ok None
      | Some (Otoml.TomlTable [field, Otoml.TomlString value]
          | Otoml.TomlInlineTable [field, Otoml.TomlString value])
          when field = key && String.trim value <> "" -> Ok (Some value)
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTable _)
      | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error ("world." ^ section ^ " requires only a non-blank " ^ key ^ " string") in
    let* skills = nested_text "skills" "directory" in
    let* skills_directory = match skills with
      | None -> Ok None
      | Some value -> Skill_resource_path.of_string value |> Result.map Option.some
          |> Result.map_error (fun error -> "world.skills.directory: " ^ Skill_resource_path.error_to_string error) in
    let* action_tool = nested_text "actions" "tool" in
    let* tool_fields = match List.assoc_opt "tools" world with
      | None -> Ok []
      | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields)
        when List.for_all (fun (key,_) -> List.mem key ["export";"invocation"]) fields
          && List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
      | Some ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
             | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
             | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
             | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _
             | Otoml.TomlTableArray _ ) -> Error "world.tools accepts export and invocation only" in
    let* tool_invocation = match List.assoc_opt "invocation" tool_fields with
      | None | Some (Otoml.TomlString "direct") -> Ok Direct
      | Some (Otoml.TomlString "host_context") -> Ok Host_context
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTable _)
      | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error "world.tools.invocation requires direct or host_context" in
    let* exported_tools = match List.assoc_opt "export" tool_fields with
      | None when tool_fields = [] -> Ok []
      | Some (Otoml.TomlArray values) ->
          let* names = List.fold_left (fun result value ->
            let* names = result in match value with
            | Otoml.TomlString name -> Ok (name :: names)
            | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
            | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
            | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
            | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> Error "world.tools.export requires tool names") (Ok []) values in
          validate_exported_tools ~action_tool names
      | None
      | Some ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
             | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
             | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
             | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) ->
          Error "world.tools requires an export array" in
    let* state_storage = match List.assoc_opt "state" world with
      | None -> Ok Ephemeral
      | Some (Otoml.TomlTable [("mode", Otoml.TomlString "persistent")]
             | Otoml.TomlInlineTable [("mode", Otoml.TomlString "persistent")]) -> Ok Persistent
      | Some (Otoml.TomlTable [("mode", Otoml.TomlString "ephemeral")]
             | Otoml.TomlInlineTable [("mode", Otoml.TomlString "ephemeral")]) -> Ok Ephemeral
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTable _)
      | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error "world.state requires only mode = persistent or ephemeral" in
    let* outputs = output_ports world in
    let* exact_outputs = exact_outputs ~directory:(Filename.dirname path) world in
    let* operator_asks = match List.assoc_opt "asks" world with
      | None -> Ok false
      | Some (Otoml.TomlTable [("operator", Otoml.TomlBoolean operator)]
             | Otoml.TomlInlineTable [("operator", Otoml.TomlBoolean operator)]) -> Ok operator
      | Some ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
             | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
             | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
             | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _
             | Otoml.TomlTableArray _ ) -> Error "world.asks requires only operator = true or false" in
    let* interface = match Otoml.find_opt document Fun.id ["interface"] with
      | None -> Ok []
      | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields)
        when List.for_all (fun (key,_) -> List.mem key ["binding_schema";"presentation";"refresh_policy";"model_access"]) fields -> Ok fields
      | Some ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
             | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
             | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
             | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _
             | Otoml.TomlTableArray _ ) ->
          Error "interface accepts binding_schema, presentation, refresh_policy and model_access" in
    let* model_access = match List.assoc_opt "model_access" interface with
      | None | Some (Otoml.TomlString "disabled") -> Ok Model_disabled
      | Some (Otoml.TomlString "host_sampling") -> Ok Host_sampling
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTable _)
      | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error "interface.model_access requires disabled or host_sampling" in
    let* refresh_policy = match List.assoc_opt "refresh_policy" interface with
      | None | Some (Otoml.TomlString "every_hint") -> Ok Every_hint
      | Some (Otoml.TomlString "source_changes") -> Ok Source_changes
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTable _)
      | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error "interface.refresh_policy requires every_hint or source_changes" in
    let json name = match List.assoc_opt name interface with
      | None -> Ok None
      | Some (Otoml.TomlString bytes) ->
          (try Ok (Some (Yojson.Safe.from_string bytes)) with Yojson.Json_error error -> Error error)
      | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _) | Some (Otoml.TomlBoolean _)
      | Some (Otoml.TomlOffsetDateTime _) | Some (Otoml.TomlLocalDateTime _)
      | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _)
      | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error ("interface." ^ name ^ " must contain JSON text") in
    let* binding_schema = json "binding_schema" in
    let* () = match binding_schema with
      | None -> Ok ()
      | Some schema ->
          let* () = Lane_addon_action.validate_value_schema schema in
          (match schema with `Assoc fields when List.assoc_opt "type" fields=Some (`String "object") -> Ok ()
           | _ -> Error "binding_schema must describe an object") in
    let* presentation = json "presentation" in
    let* presentation = match presentation with None -> Ok Lane_addon_presentation.empty
      | Some value -> Lane_addon_presentation.of_json value in
    let* id = text ["id"] in
    let* revision = text ["revision"] in
    let* title = text ["title"] in
    let* image = text ["image"] in
    let* runtime = match Otoml.find_opt document Fun.id ["runtime"] with
      | None -> Ok Docker
      | Some (Otoml.TomlString value) ->
          Option.to_result ~none:"runtime requires docker or apple_container" (runtime_of_string value)
      | Some (Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
             | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
             | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
             | Otoml.TomlTable _ | Otoml.TomlInlineTable _
             | Otoml.TomlTableArray _) ->
          Error "runtime requires docker or apple_container" in
    let* command = read ["command"] (Otoml.get_array Otoml.get_string) in
    let* names = read ["contributions"] (Otoml.get_array Otoml.get_string) in
    let* contributions =
      List.fold_left (fun acc name ->
        let* acc = acc in
        match name with
        | "observe" -> Ok (Observe :: acc) | "derive" -> Ok (Derive :: acc)
        | "act" -> Ok (Act :: acc)
        | _ -> Error ("unsupported contribution: " ^ name)) (Ok []) names
    in
    let* () = match List.mem Act contributions, action_tool with
      | true, Some tool when tool <> "lane_observe" -> Ok ()
      | false, None -> Ok ()
      | _ -> Error "act contribution requires a distinct world.actions.tool, and vice versa" in
    let* cpus = read ["resources"; "cpus"] (Otoml.get_float ~strict:false) in
    let* memory = read ["resources"; "memory_bytes"] Otoml.get_integer in
    let* pids = match Otoml.find_opt document Fun.id ["resources"; "pids"] with
      | None -> Ok None
      | Some (Otoml.TomlInteger value) -> Ok (Some value)
      | Some (Otoml.TomlString _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
             | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
             | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
             | Otoml.TomlTable _ | Otoml.TomlInlineTable _
             | Otoml.TomlTableArray _) ->
          Error "resources.pids requires an integer" in
    let* max_reply_bytes = read ["resources"; "max_reply_bytes"] Otoml.get_integer in
    if command = [] || List.exists (fun arg -> String.trim arg = "") command
    then Error "command requires non-blank argv entries"
    else if contributions = [] then Error "at least one contribution is required"
    else
      let resources = { cpus; memory_bytes = Int64.of_int memory; pids; max_reply_bytes } in
      match check_resources ~runtime resources with
      | Error detail -> Error detail
      | Ok () -> Ok { id; revision; title; contributions = List.rev contributions; runtime; image; command;
          directory = Filename.dirname path; skills_directory; action_tool; state_storage; tool_invocation; exported_tools; outputs; refresh_policy; model_access; binding_schema; presentation;
          exact_outputs; operator_asks; resources }
  in
  try Result.map_error (fun detail -> Invalid_manifest detail) (parse ()) with
  | Sys_error message -> Error (Io_failure message)
  | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR) as error, call, arg) ->
      Error (Invalid_manifest (call ^ " " ^ arg ^ ": " ^ Unix.error_message error))
  | Unix.Unix_error (error, call, arg) ->
      Error (Io_failure (call ^ " " ^ arg ^ ": " ^ Unix.error_message error))
  | Otoml.Parse_error (_, message) -> Error (Invalid_manifest message)
  | Otoml.Duplicate_key message -> Error (Invalid_manifest message)
