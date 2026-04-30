open Repo_manager_types

let ( let* ) = Result.bind

let creds_toml_path base_path =
  Filename.concat base_path ".masc/config/credentials.toml"

let credential_type_of_string = function
  | "Github" -> Ok Github
  | "Gitlab" -> Ok Gitlab
  | "Local" -> Ok Local
  | s -> Error (Printf.sprintf "Unknown credential type: %s" s)

let string_of_credential_type = function
  | Github -> "Github"
  | Gitlab -> "Gitlab"
  | Local -> "Local"

let credential_of_toml toml id =
  let path field = ["credential"; id; field] in
  let* cred_type_str = Otoml.find_result toml Otoml.get_string (path "type") in
  let* cred_type = credential_type_of_string cred_type_str in
  let* username = Otoml.find_result toml Otoml.get_string (path "username") in
  let gh_config_dir =
    match Otoml.find_result toml Otoml.get_string (path "gh_config_dir") with
    | Ok dir -> Some dir
    | Error _ -> None
  in
  let ssh_key_path =
    match Otoml.find_result toml Otoml.get_string (path "ssh_key_path") with
    | Ok path -> Some path
    | Error _ -> None
  in
  let gpg_key_id =
    match Otoml.find_result toml Otoml.get_string (path "gpg_key_id") with
    | Ok id -> Some id
    | Error _ -> None
  in
  Ok { id; cred_type; username; gh_config_dir; ssh_key_path; gpg_key_id }

let toml_of_credential cred =
  let fields =
    [
      ("type", Otoml.string (string_of_credential_type cred.cred_type));
      ("username", Otoml.string cred.username);
    ]
  in
  let fields =
    match cred.gh_config_dir with
    | Some dir -> ("gh_config_dir", Otoml.string dir) :: fields
    | None -> fields
  in
  let fields =
    match cred.ssh_key_path with
    | Some path -> ("ssh_key_path", Otoml.string path) :: fields
    | None -> fields
  in
  let fields =
    match cred.gpg_key_id with
    | Some id -> ("gpg_key_id", Otoml.string id) :: fields
    | None -> fields
  in
  Otoml.TomlTable (List.rev fields)

let load_all ~base_path =
  let path = creds_toml_path base_path in
  if not (Sys.file_exists path) then Ok []
  else
    match Otoml.Parser.from_file_result path with
    | Error msg -> Error msg
    | Ok toml -> (
        match Otoml.find_result toml Fun.id ["credential"] with
        | Error _ -> Ok []
        | Ok (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
            let rec loop acc = function
              | [] -> Ok (List.rev acc)
              | (id, value) :: rest -> (
                  match value with
                  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
                      let cred_toml =
                        Otoml.TomlTable [("credential", Otoml.TomlTable [(id, value)])]
                      in
                      (match credential_of_toml cred_toml id with
                      | Ok cred -> loop (cred :: acc) rest
                      | Error msg -> Error msg)
                  | _ ->
                      Error (Printf.sprintf "credential.%s must be a table" id))
            in
            loop [] fields
        | Ok _ -> Ok [])

let save_all ~base_path (creds : credential list) =
  let path = creds_toml_path base_path in
  let config_dir = Filename.dirname path in
  (try
     if not (Sys.file_exists config_dir) then Sys.mkdir config_dir 0o755
   with Sys_error _ -> ());
  let cred_entries =
    List.map (fun (cred : credential) -> (cred.id, toml_of_credential cred)) creds
  in
  let toml = Otoml.TomlTable [("credential", Otoml.TomlTable cred_entries)] in
  let content = Otoml.Printer.to_string toml in
  try
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with Sys_error msg -> Error msg

let find ~base_path id =
  let* creds = load_all ~base_path in
  match List.find_opt (fun (c : credential) -> String.equal c.id id) creds with
  | Some cred -> Ok cred
  | None -> Error (Printf.sprintf "Credential not found: %s" id)

let add ~base_path (cred : credential) =
  let* creds = load_all ~base_path in
  if List.exists (fun (c : credential) -> String.equal c.id cred.id) creds then
    Error (Printf.sprintf "Credential already exists: %s" cred.id)
  else
    let* () = save_all ~base_path (cred :: creds) in
    Ok cred

let remove ~base_path id =
  let* creds = load_all ~base_path in
  let filtered =
    List.filter (fun (c : credential) -> not (String.equal c.id id)) creds
  in
  if List.length filtered = List.length creds then
    Error (Printf.sprintf "Credential not found: %s" id)
  else
    save_all ~base_path filtered
