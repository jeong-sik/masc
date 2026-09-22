module Install = Runtime_official_cli_install

let client_arg =
  Cmdliner.Arg.enum
    [ "claude-code", Install.Claude; "codex", Install.Codex; "antigravity", Install.Antigravity ]
;;

let client_name = function
  | Install.Claude -> "claude-code"
  | Install.Codex -> "codex"
  | Install.Antigravity -> "antigravity"
;;

let to_json ~client ~command ~path =
  `Assoc
    [ "schema", `String "masc.runtime_client_path.v1"
    ; "client", `String (client_name client)
    ; "command", `String command
    ; ("path", match path with Some path -> `String path | None -> `Null)
    ]
;;

let run ~client ~command =
  let command = match command with Some command -> command | None -> Install.name client in
  let path = Install.locate client ~command in
  print_endline (Yojson.Safe.to_string (to_json ~client ~command ~path));
  0
;;
