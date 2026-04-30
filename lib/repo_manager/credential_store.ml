open Repo_manager_types

let ( let* ) = Result.bind

let creds_toml_path base_path =
  Filename.concat base_path ".masc/config/credentials.toml"

let default_credential =
  {
    id = "default";
    cred_type = Local;
    username = "default";
    gh_config_dir = None;
    ssh_key_path = None;
    gpg_key_id = None;
    state = Unmaterialized;
    token_sha256_prefix = None;
  }

let ensure_dir path =
  let rec loop dir =
    if dir = "" || dir = "." || Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      try Unix.mkdir dir 0o755
      with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop path

let credential_type_of_string = function
  | "Github" | "github" -> Ok Github
  | "Gitlab" | "gitlab" -> Ok Gitlab
  | "Local" | "local" -> Ok Local
  | s -> Error (Printf.sprintf "Unknown credential type: %s" s)

let string_of_credential_type = function
  | Github -> "Github"
  | Gitlab -> "Gitlab"
  | Local -> "Local"

(* RFC-0019 §4.2: credential_state TOML representation.  Variant tag in
   "state" key, optional auxiliary fields under "state_*" keys.  Missing
   key collapses to [Unmaterialized] so older TOML files load cleanly. *)
let credential_state_of_toml toml id =
  let path field = ["credential"; id; field] in
  match Otoml.find_result toml Otoml.get_string (path "state") with
  | Error _ -> Unmaterialized
  | Ok "Unmaterialized" -> Unmaterialized
  | Ok "Materialized" ->
      (match
         Otoml.Helpers.find_integer_result toml (path "state_last_verified_at")
       with
       | Ok ts -> Materialized { last_verified_at = Int64.of_int ts }
       | Error _ -> Materialized { last_verified_at = 0L })
  | Ok "Stale" ->
      let reason =
        match Otoml.find_result toml Otoml.get_string (path "state_reason") with
        | Ok r -> r
        | Error _ -> "unknown"
      in
      Stale { reason }
  | Ok _ -> Unmaterialized

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
  let state = credential_state_of_toml toml id in
  let token_sha256_prefix =
    match
      Otoml.find_result toml Otoml.get_string (path "token_sha256_prefix")
    with
    | Ok s -> Some s
    | Error _ -> None
  in
  Ok
    {
      id;
      cred_type;
      username;
      gh_config_dir;
      ssh_key_path;
      gpg_key_id;
      state;
      token_sha256_prefix;
    }

(* RFC-0019 §4.2 + symmetry with [credential_state_of_toml]: serialise
   the variant tag in "state" and any auxiliary data under "state_*"
   keys.  Symmetry guarded by the round-trip test in
   [test_credential_store]. *)
let state_fields_of_credential_state state =
  match state with
  | Unmaterialized -> [ ("state", Otoml.string "Unmaterialized") ]
  | Materialized { last_verified_at } ->
      [ ("state", Otoml.string "Materialized");
        ( "state_last_verified_at",
          Otoml.integer (Int64.to_int last_verified_at) ) ]
  | Stale { reason } ->
      [ ("state", Otoml.string "Stale");
        ("state_reason", Otoml.string reason) ]

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
  let fields = state_fields_of_credential_state cred.state @ fields in
  let fields =
    match cred.token_sha256_prefix with
    | Some s -> ("token_sha256_prefix", Otoml.string s) :: fields
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
  ensure_dir config_dir;
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
  | None when String.equal id default_credential.id -> Ok default_credential
  | None -> Error (Printf.sprintf "Credential not found: %s" id)

let add ~base_path (cred : credential) =
  let* creds = load_all ~base_path in
  if List.exists (fun (c : credential) -> String.equal c.id cred.id) creds then
    Error (Printf.sprintf "Credential already exists: %s" cred.id)
  else
    (* RFC-0019 §4.4: stamp the state field on insert so the registry
       never holds a credential whose materialisation status hasn't been
       evaluated.  Idempotent w.r.t. the rest of the record. *)
    let materialised = Credential_materializer.ensure cred in
    let* () = save_all ~base_path (materialised :: creds) in
    Ok materialised

let remove ~base_path id =
  let* creds = load_all ~base_path in
  let filtered =
    List.filter (fun (c : credential) -> not (String.equal c.id id)) creds
  in
  if List.length filtered = List.length creds then
    Error (Printf.sprintf "Credential not found: %s" id)
  else
    save_all ~base_path filtered
