type error =
  { path : string
  ; detail : string
  }

let error_to_string { path; detail } =
  Printf.sprintf "unsafe Antigravity policy path %s: %s" path detail
;;

(* agy reads these characters as pattern syntax inside a rule, so a path that
   holds one would widen or break the rule that names it. *)
let has_permission_pattern_syntax path =
  String.exists (function '*' | '?' | '[' | ']' | '(' | ')' -> true | _ -> false) path
;;

(* [path] lies at or below [root]. Both are canonical, so whole path
   components compare; [/a/b] does not hold [/a/bc]. *)
let path_is_within ~root path =
  let parts value = String.split_on_char '/' value |> List.filter (fun part -> part <> "") in
  let rec holds = function
    | [], _ -> true
    | root_part :: root_rest, part :: rest -> String.equal root_part part && holds (root_rest, rest)
    | _ :: _, [] -> false
  in
  holds (parts root, parts path)
;;

let has_dot_segments path =
  String.split_on_char '/' path
  |> List.exists (function "." | ".." -> true | _ -> false)
;;

let validate_deny_read_roots ~gemini_dir roots =
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | root :: rest ->
      if String.trim root = ""
         || Filename.is_relative root
         || String.contains root '\000'
         || has_dot_segments root
      then
        Error
          { path = root
          ; detail =
              "ACP deny_read_root must be a normalized non-empty absolute path without NUL or dot segments"
          }
      else if has_permission_pattern_syntax root
      then
        Error
          { path = root
          ; detail = "ACP deny_read_root contains permission-pattern syntax"
          }
      else if path_is_within ~root gemini_dir
      then
        Error
          { path = root
          ; detail =
              "ACP deny_read_root must not contain managed --gemini-dir (would shadow MCP schema reads)"
          }
      else if List.mem root seen
      then loop seen acc rest
      else loop (root :: seen) (root :: acc) rest
  in
  loop [] [] roots
;;

let acp_settings_json
      ?mcp_server_name:server_name
      ?(deny_read_roots = [])
      ?(deny_writes_and_commands = false)
      ~gemini_dir
      ()
  =
  if String.trim gemini_dir = ""
     || Filename.is_relative gemini_dir
     || String.contains gemini_dir '\000'
     || has_dot_segments gemini_dir
  then
    Error
      { path = gemini_dir
      ; detail =
          "managed Antigravity ACP dir must be a normalized non-empty absolute path without NUL or dot segments"
      }
  else (
    match server_name with
    | Some srv when (not (Fs_compat.is_capability_leaf srv)) || has_permission_pattern_syntax srv ->
      Error
        { path = gemini_dir
        ; detail = "ACP MCP server name is not a safe leaf or contains permission-pattern syntax"
        }
    | Some _ | None ->
      let config_dir = Filename.concat gemini_dir "config" in
      let cli_dir = Filename.concat gemini_dir "antigravity-cli" in
      let token_path = Filename.concat cli_dir "antigravity-oauth-token" in
      let schema_dir =
        Option.map
          (fun srv -> Filename.concat (Filename.concat cli_dir "mcp") srv)
          server_name
      in
      let checked_paths = config_dir :: token_path :: Option.to_list schema_dir in
      (match List.find_opt has_permission_pattern_syntax checked_paths with
       | Some path ->
         Error
           { path
           ; detail = "managed Antigravity ACP dir contains permission-pattern syntax"
           }
       | None ->
         (match validate_deny_read_roots ~gemini_dir deny_read_roots with
          | Error _ as err -> err
          | Ok valid_deny_roots ->
            let allow =
              match server_name, schema_dir with
              | Some srv, Some dir -> [ "mcp(" ^ srv ^ "/*)"; "read_file(" ^ dir ^ ")" ]
              | Some _, None | None, (Some _ | None) -> []
            in
            let extra_root_denies =
              List.map (fun root -> "read_file(" ^ root ^ ")") valid_deny_roots
            in
            let write_cmd_denies =
              if deny_writes_and_commands then [ "write_file(*)"; "command(*)" ] else []
            in
            let deny =
              [ "read_file(" ^ config_dir ^ ")"
              ; "read_file(" ^ token_path ^ ")"
              ]
              @ extra_root_denies
              @ write_cmd_denies
              @ [ "read_url(*)"; "execute_url(*)" ]
            in
            let strings values = `List (List.map (fun value -> `String value) values) in
            Ok (`Assoc [ "permissions", `Assoc [ "allow", strings allow; "deny", strings deny ] ]))))
;;
