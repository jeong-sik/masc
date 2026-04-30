open Repo_manager_types

let ( let* ) = Result.bind

let repos_toml_path base_path =
  Filename.concat base_path ".masc/config/repositories.toml"

let default_local_path id = Filename.concat ".masc/repos" id

let now_unix_seconds () = Int64.of_float (Unix.time ())

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

let string_of_status = function
  | Active -> "Active"
  | Paused -> "Paused"
  | Cloning -> "Cloning"
  | Error _ -> "Error"

let status_of_string = function
  | "Active" | "active" -> Ok Active
  | "Paused" | "paused" -> Ok Paused
  | "Cloning" | "cloning" -> Ok Cloning
  | "Error" | "error" -> Ok (Error "")
  | s -> Error (Printf.sprintf "Unknown repository status: %s" s)

let repository_of_toml toml id =
  let ( let* ) = Result.bind in
  let path field = ["repository"; id; field] in
  let find_string_default field default =
    match Otoml.find_result toml Otoml.get_string (path field) with
    | Ok value -> Ok value
    | Error _ -> Ok default
  in
  let find_bool_default field default =
    match Otoml.find_result toml Otoml.get_boolean (path field) with
    | Ok value -> Ok value
    | Error _ -> Ok default
  in
  let find_int64_default field default =
    match Otoml.Helpers.find_integer_result toml (path field) with
    | Ok value -> Ok (Int64.of_int value)
    | Error _ -> Ok default
  in
  let find_string_list_default field default =
    match Otoml.Helpers.find_strings_result toml (path field) with
    | Ok value -> Ok value
    | Error _ -> Ok default
  in
  let* name = Otoml.find_result toml Otoml.get_string (path "name") in
  let* url = Otoml.find_result toml Otoml.get_string (path "url") in
  let* local_path = find_string_default "local_path" (default_local_path id) in
  let* default_branch = find_string_default "default_branch" "main" in
  let* credential_id = find_string_default "credential_id" "default" in
  let* keepers = find_string_list_default "keepers" [] in
  let* status_str = find_string_default "status" "Active" in
  let* status = status_of_string status_str in
  let status =
    match status with
    | Error _ -> (
        match Otoml.find_result toml Otoml.get_string (path "status_error") with
        | Ok msg -> Error msg
        | Error _ -> Error "")
    | other -> other
  in
  let* auto_sync = find_bool_default "auto_sync" false in
  let* sync_interval = find_int64_default "sync_interval" (Int64.of_int 300) in
  let* created_at = find_int64_default "created_at" Int64.zero in
  let* updated_at = find_int64_default "updated_at" Int64.zero in
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
      sync_interval = Int64.to_int sync_interval;
      created_at;
      updated_at;
    }

let toml_of_repository repo =
  let fields =
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
  in
  let fields =
    match repo.status with
    | Error msg when String.trim msg <> "" ->
        ("status_error", Otoml.string msg) :: fields
    | _ -> fields
  in
  Otoml.TomlTable fields

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
  ensure_dir config_dir;
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
    let now = now_unix_seconds () in
    let repo =
      {
        repo with
        local_path =
          (if String.trim repo.local_path = "" then default_local_path repo.id
           else repo.local_path);
        credential_id =
          (if String.trim repo.credential_id = "" then "default"
           else repo.credential_id);
        created_at = (if Int64.equal repo.created_at Int64.zero then now else repo.created_at);
        updated_at = (if Int64.equal repo.updated_at Int64.zero then now else repo.updated_at);
      }
    in
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
  let now = now_unix_seconds () in
  let updated =
    List.map
      (fun (r : repository) ->
        if String.equal r.id id then (
          found := true;
          { r with status; updated_at = now })
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

let slugify_id s =
  String.map
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> c
      | _ -> '-')
    s

let run_read_line cmd =
  try
    let ic = Unix.open_process_in cmd in
    Fun.protect
      ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        try Ok (input_line ic) with End_of_file -> Error "no output")
  with Sys_error msg -> Error msg

let discover_repositories ~base_path =
  let existing_paths =
    match load_all ~base_path with
    | Ok repos ->
        List.map (fun (r : repository) -> local_path ~base_path r) repos
    | Error _ -> []
  in
  let git_dirs =
    try
      let cmd =
        Printf.sprintf "find %s -name \".git\" -maxdepth 3 -type d 2>/dev/null"
          (Filename.quote base_path)
      in
      let ic = Unix.open_process_in cmd in
      Fun.protect
        ~finally:(fun () -> ignore (Unix.close_process_in ic))
        (fun () ->
          let rec read_lines acc =
            match input_line ic with
            | line -> read_lines (line :: acc)
            | exception End_of_file -> List.rev acc
          in
          read_lines [])
    with _ -> []
  in
  let is_masc_dir path =
    let masc_prefix = Filename.concat base_path ".masc" in
    String.length path >= String.length masc_prefix
    && String.sub path 0 (String.length masc_prefix) = masc_prefix
  in
  let candidates =
    List.filter_map
      (fun git_dir ->
        let repo_dir = Filename.dirname git_dir in
        let abs_repo_dir =
          if Filename.is_relative repo_dir then Filename.concat base_path repo_dir
          else repo_dir
        in
        if is_masc_dir abs_repo_dir then None
        else if List.exists (String.equal abs_repo_dir) existing_paths then None
        else
          let url_cmd =
            Printf.sprintf "git -C %s remote get-url origin 2>/dev/null"
              (Filename.quote abs_repo_dir)
          in
          match run_read_line url_cmd with
          | Ok url ->
              let name = Filename.basename abs_repo_dir in
              let id = slugify_id name in
              Some
                {
                  id;
                  name;
                  url;
                  local_path = abs_repo_dir;
                  default_branch = "main";
                  credential_id = "default";
                  keepers = [];
                  status = Active;
                  auto_sync = false;
                  sync_interval = 0;
                  created_at = Int64.zero;
                  updated_at = Int64.zero;
                }
          | Error _ -> None)
      git_dirs
  in
  Ok candidates
