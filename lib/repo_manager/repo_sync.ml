open Repo_manager_types

let ( let* ) = Result.bind

let sync_repository ~base_path repo : (unit, string) result =
  let local_path = Repo_store.local_path ~base_path repo in
  let repo_with_path = { repo with local_path } in
  let* () = Repo_store.update_status ~base_path repo.id Cloning in
  let sync_result =
    if Sys.file_exists local_path then
      Repo_git.fetch ~repository:repo_with_path
    else
      match Repo_git.clone ~repository:repo_with_path with
      | Error msg -> Error msg
      | Ok () -> Repo_git.fetch ~repository:repo_with_path
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

type sync_failure =
  { repo_id : string
  ; error : string
  }

let sync_failure_to_string { repo_id; error } =
  Printf.sprintf "repository %s sync failed: %s" repo_id error

let sync_all ~base_path ~now : (repository list, string) result =
  let* repos = Repo_store.load_all ~base_path in
  let due = List.filter (fun r -> should_sync r ~now) repos in
  let rec loop synced failures = function
    | [] ->
      (match failures with
       | [] -> Ok (List.rev synced)
       | _ -> Error (String.concat "; " (List.rev_map sync_failure_to_string failures)))
    | repo :: rest -> (
        match sync_repository ~base_path repo with
        | Error error -> loop synced ({ repo_id = repo.id; error } :: failures) rest
        | Ok () -> loop (repo :: synced) failures rest)
  in
  loop [] [] due
