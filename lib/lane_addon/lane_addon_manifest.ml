open Lane_addon_types
let ( let* ) = Result.bind
let load ~path =
  try
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
             || List.exists (fun key -> key <> "skills" && key <> "actions") names
          then Error "world accepts skills and actions tables" else Ok fields
      | Some _ -> Error "world must be a table" in
    let nested_text section key = match List.assoc_opt section world with
      | None -> Ok None
      | Some (Otoml.TomlTable [field, Otoml.TomlString value]
          | Otoml.TomlInlineTable [field, Otoml.TomlString value])
          when field = key && String.trim value <> "" -> Ok (Some value)
      | Some _ -> Error ("world." ^ section ^ " requires only a non-blank " ^ key ^ " string") in
    let* skills = nested_text "skills" "directory" in
    let* skills_directory = match skills with
      | None -> Ok None
      | Some value -> Skill_resource_path.of_string value |> Result.map Option.some
          |> Result.map_error (fun error -> "world.skills.directory: " ^ Skill_resource_path.error_to_string error) in
    let* action_tool = nested_text "actions" "tool" in
    let* id = text ["id"] in
    let* revision = text ["revision"] in
    let* title = text ["title"] in
    let* image = text ["image"] in
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
    let* pids = read ["resources"; "pids"] Otoml.get_integer in
    let* max_reply_bytes = read ["resources"; "max_reply_bytes"] Otoml.get_integer in
    if command = [] || List.exists (fun arg -> String.trim arg = "") command
    then Error "command requires non-blank argv entries"
    else if contributions = [] then Error "at least one contribution is required"
    else if not (cpus > 0.) || classify_float cpus = FP_infinite
         || memory <= 0 || pids <= 0 || max_reply_bytes <= 0
    then Error "resources require finite positive CPU, memory, pids and reply bytes"
    else Ok { id; revision; title; contributions = List.rev contributions; image; command;
      directory = Filename.dirname path; skills_directory; action_tool;
      resources = { cpus; memory_bytes = Int64.of_int memory; pids; max_reply_bytes } }
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, call, arg) -> Error (call ^ " " ^ arg ^ ": " ^ Unix.error_message error)
  | Otoml.Parse_error (_, message) -> Error message
  | Otoml.Duplicate_key message -> Error message
