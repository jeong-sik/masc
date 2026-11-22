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

let acp_settings_json ?mcp_server_name:server_name ~gemini_dir () =
  if String.trim gemini_dir = ""
     || Filename.is_relative gemini_dir
     || String.contains gemini_dir '\000'
  then
    Error
      { path = gemini_dir
      ; detail =
          "managed Antigravity ACP dir must be a non-empty absolute path without NUL bytes"
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
         let allow =
           match server_name, schema_dir with
           | Some srv, Some dir -> [ "mcp(" ^ srv ^ "/*)"; "read_file(" ^ dir ^ ")" ]
           | Some _, None | None, (Some _ | None) -> []
         in
         let deny =
           [ "read_file(" ^ config_dir ^ ")"
           ; "read_file(" ^ token_path ^ ")"
           ; "read_url(*)"
           ; "execute_url(*)"
           ]
         in
         let strings values = `List (List.map (fun value -> `String value) values) in
         Ok (`Assoc [ "permissions", `Assoc [ "allow", strings allow; "deny", strings deny ] ])))
;;
