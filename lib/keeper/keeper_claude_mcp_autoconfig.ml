(* Auto-construct claude_mcp_config JSON for CLI-backed keeper turns.
   See .mli for rationale and contract. #10049. *)

let read_token_opt ~base_path ~agent_name =
  let token_file =
    Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")
  in
  match Fs_compat.load_file token_file with
  | content ->
      let trimmed = String.trim content in
      if String.length trimmed = 0 then None else Some trimmed
  | exception _ -> None

let mcp_url_opt () =
  match Sys.getenv_opt Env_config_core.mcp_url_env_key with
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if String.length trimmed = 0 then None else Some trimmed

(* Build the JSON document via Yojson so URL and bearer are escaped
   correctly. Layout mirrors the Codex sync format
   (server_runtime_bootstrap.ml:~695) but emitted as JSON rather than
   TOML. *)
let build_json ~url ~bearer : string =
  let servers : Yojson.Safe.t =
    `Assoc
      [
        ( "masc",
          `Assoc
            [
              ("type", `String "http");
              ("url", `String url);
              ( "headers",
                `Assoc
                  [ ("Authorization", `String ("Bearer " ^ bearer)) ] );
            ] );
      ]
  in
  let root : Yojson.Safe.t = `Assoc [ ("mcpServers", servers) ] in
  Yojson.Safe.to_string root

let auto_construct ~base_path ~agent_name =
  match mcp_url_opt (), read_token_opt ~base_path ~agent_name with
  | Some url, Some bearer -> Some (build_json ~url ~bearer)
  | _ -> None
