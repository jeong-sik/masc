open Repo_manager_types

let ( let* ) = Result.bind

let repos_toml_path base_path =
  Filename.concat base_path ".masc/config/repositories.toml"

let string_of_status = function
  | Active -> "Active"
  | Paused -> "Paused"
  | Cloning -> "Cloning"
  | Error _ -> "Error"

let status_of_string = function
  | "Active" -> Ok Active
  | "Paused" -> Ok Paused
  | "Cloning" -> Ok Cloning
  | "Error" -> Ok (Error "")
  | s -> Error (Printf.sprintf "Unknown repository status: %s" s)

let repository_of_toml toml id =
  let ( let* ) = Result.bind in
  let path field = ["repository"; id; field] in
  let* name = Otoml.find_result toml Otoml.get_string (path "name") in
  let* url = Otoml.find_result toml Otoml.get_string (path "url") in
  let* local_path = Otoml.find_result toml Otoml.get_string (path "local_path") in
  let* default_branch =
    Otoml.find_result toml Otoml.get_string (path "default_branch")
  in
  let* credential_id =
    Otoml.find_result toml Otoml.get_string (path "credential_id")
  in
  let* keepers =
    Otoml.Helpers.find_strings_result toml (path "keepers")
  in
  let* status_str =
    Otoml.find_result toml Otoml.get_string (path "status")
  in
  let* status = status_of_string status_str in
  let* auto_sync =
    Otoml.find_result toml Otoml.get_boolean (path "auto_sync")
  in
  let* sync_interval =
    Otoml.Helpers.find_integer_result toml (path "sync_interval")
  in
  let* created_at =
    Otoml.Helpers.find_integer_result toml (path "created_at")
  in
  let* updated_at =
    Otoml.Helpers.find_integer_result toml (path "updated_at")
  in
  Ok
    {
      id;
      name;
      url;
      local_path;
      default_branch;
      credential_id;
      keepers;
      status;
      auto_sync;
      sync_interval;
      created_at = Int64.of_int created_at;
      updated_at = Int64.of_int updated_at;
    }

let toml_of_repository repo =
  Otoml.TomlTable
    [
      ("name", Otoml.string repo.name);
      ("url", Otoml.string repo.url);
      ("local_path", Otoml.string repo.local_path);
      ("default_branch", Otoml.string repo.default_branch);
      ("credential_id", Otoml.string repo.credential_id);
      ( "keepers",
        Otoml.TomlArray (List.map (fun s -> Otoml.TomlString s) repo.keepers)
      );
      ("status", Otoml.string (string_of_status repo.status));
      ("auto_sync", Otoml.boolean repo.auto_sync);
      ("sync_interval", Otoml.integer repo.sync_interval);
      ("created_at", Otoml.integer (Int64.to_int repo.created_at));
      ("updated_at", Otoml.integer (Int64.to_int repo.updated_at));
    ]

let load_all ~base_path =
  let path = repos_toml_path base_path in
  if not (Sys.file_exists path) then Ok []
  else
    match Otoml.Parser.from_file_result path with
    | Error msg -> Error msg
    | Ok toml -> (
        match Otoml.find_result toml Fun.id ["repository"] with
        | Error _ -> Ok []
        | Ok (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
            let rec loop acc = function
              | [] -> Ok (List.rev acc)
              | (id, value) :: rest -> (
                  match value with
                  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
                      let repo_toml =
                        Otoml.TomlTable
                          [("repository", Otoml.TomlTable [(id, value)])]
                      in
                      (match repository_of_toml repo_toml id with
                      | Ok repo -> loop (repo :: acc) rest
                      | Error msg -> Error msg)
                  | _ ->
                      Error
                        (Printf.sprintf "repository.%s must be a table" id))
            in
            loop [] fields
        | Ok _ -> Ok [])

let save_all ~base_path (repos : repository list) =
  let path = repos_toml_path base_path in
  let config_dir = Filename.dirname path in
  (try
     if not (Sys.file_exists config_dir) then Sys.mkdir config_dir 0o755
   with Sys_error _ -> ());
  let repo_entries =
    List.map (fun (repo : repository) -> (repo.id, toml_of_repository repo)) repos
  in
  let toml = Otoml.TomlTable [("repository", Otoml.TomlTable repo_entries)] in
  let content = Otoml.Printer.to_string toml in
  try
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with Sys_error msg -> Error msg

let find ~base_path id =
  let* repos = load_all ~base_path in
  match List.find_opt (fun (r : repository) -> String.equal r.id id) repos with
  | Some repo -> Ok repo
  | None -> Error (Printf.sprintf "Repository not found: %s" id)

let add ~base_path (repo : repository) =
  let* repos = load_all ~base_path in
  if List.exists (fun (r : repository) -> String.equal r.id repo.id) repos then
    Error (Printf.sprintf "Repository already exists: %s" repo.id)
  else
    let* () = save_all ~base_path (repo :: repos) in
    Ok repo

let remove ~base_path id =
  let* repos = load_all ~base_path in
  let filtered =
    List.filter (fun (r : repository) -> not (String.equal r.id id)) repos
  in
  if List.length filtered = List.length repos then
    Error (Printf.sprintf "Repository not found: %s" id)
  else
    save_all ~base_path filtered

let update_status ~base_path id status =
  let* repos = load_all ~base_path in
  let found = ref false in
  let updated =
    List.map
      (fun (r : repository) ->
        if String.equal r.id id then (
          found := true;
          { r with status })
        else r)
      repos
  in
  if not !found then Error (Printf.sprintf "Repository not found: %s" id)
  else save_all ~base_path updated

let local_path ~base_path repo =
  if Filename.is_relative repo.local_path then
    Filename.concat base_path repo.local_path
  else
    repo.local_path

let list_branches ~base_path id : (string list, string) result =
  let* repo = find ~base_path id in
  let path = local_path ~base_path repo in
  Repo_git.get_branches ~repository:{ repo with local_path = path }
