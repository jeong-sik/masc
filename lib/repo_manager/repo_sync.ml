open Repo_manager_types

let ( let* ) = Result.bind

let sync_repository ~base_path repo credential : (unit, string) result =
  let local_path = Repo_store.local_path ~base_path repo in
  let repo_with_path = { repo with local_path } in
  let* () = Repo_store.update_status ~base_path repo.id Cloning in
  let sync_result =
    if Sys.file_exists local_path then
      Repo_git.fetch ~repository:repo_with_path ~credential
    else
      match Repo_git.clone ~repository:repo_with_path ~credential with
      | Error msg -> Error msg
      | Ok () -> Repo_git.fetch ~repository:repo_with_path ~credential
  in
  match sync_result with
  | Error msg ->
      let* () = Repo_store.update_status ~base_path repo.id (Error msg) in
      Error msg
  | Ok _branches ->
      let* () = Repo_store.update_status ~base_path repo.id Active in
      Ok ()

let should_sync repo ~now =
  if not repo.auto_sync then false
  else
    let elapsed = Int64.sub now repo.updated_at in
    Int64.to_int elapsed >= repo.sync_interval

let sync_all ~base_path ~now : (repository list, string) result =
  let* repos = Repo_store.load_all ~base_path in
  let due = List.filter (fun r -> should_sync r ~now) repos in
  let rec loop synced = function
    | [] -> Ok (List.rev synced)
    | repo :: rest -> (
        match Credential_store.find ~base_path repo.credential_id with
        | Error msg -> loop synced rest
        | Ok credential -> (
            match sync_repository ~base_path repo credential with
            | Error _ -> loop synced rest
            | Ok () -> loop (repo :: synced) rest))
  in
  loop [] due
