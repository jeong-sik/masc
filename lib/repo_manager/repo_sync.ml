open Repo_manager_types

let ( let* ) = Result.bind

type advance_outcome =
  | Advanced of { behind : int }
  | Already_current
  | Skipped_dirty of { staged : int; unstaged : int; conflicted : int }
  | Skipped_not_on_default_branch of { current : string }
  | Fast_forward_refused of { behind : int; reason : string }
  | Advance_inspect_failed of { reason : string }

type sync_attempt = {
  repository : repository;
  result : (advance_outcome, string) result;
}

let advance_outcome_label = function
  | Advanced _ -> "advanced"
  | Already_current -> "already_current"
  | Skipped_dirty _ -> "skipped_dirty"
  | Skipped_not_on_default_branch _ -> "skipped_not_on_default_branch"
  | Fast_forward_refused _ -> "fast_forward_refused"
  | Advance_inspect_failed _ -> "advance_inspect_failed"

(* RFC-0210 (Keeper Playground Repo Currency): a fetch alone never moves the
   working tree, so managed clones drift arbitrarily far behind their remote
   while reporting a clean "변경 없음" state to every reader (IDE workspace
   tree/file/diff/blame). After a successful fetch we advance the checked-out
   default branch to the fetched remote ref — work-preserving:

   - tracked local modifications (staged/unstaged/conflicted) skip the move;
   - a non-default checkout (feature branch, detached HEAD) skips the move;
   - [git merge --ff-only] refuses divergence instead of rewriting history.

   Every skip is a typed outcome the caller must consume; none of them is an
   [Error] because the fetch itself succeeded and refs are current. *)
let advance_working_tree ~repository : advance_outcome =
  let target_ref = "origin/" ^ repository.default_branch in
  match Repo_git.ahead_behind ~repository ~target_ref with
  | Error reason -> Advance_inspect_failed { reason }
  | Ok (0, _ahead) -> Already_current
  | Ok (behind, _ahead) -> (
      match Repo_git.current_branch ~repository with
      | Error reason -> Advance_inspect_failed { reason }
      | Ok current when not (String.equal current repository.default_branch) ->
          Skipped_not_on_default_branch { current }
      | Ok _default -> (
          match Repo_git.status_summary ~repository with
          | Error reason -> Advance_inspect_failed { reason }
          | Ok summary
            when summary.Repo_git.staged_files > 0
                 || summary.Repo_git.unstaged_files > 0
                 || summary.Repo_git.conflicted_files > 0 ->
              Skipped_dirty
                {
                  staged = summary.Repo_git.staged_files;
                  unstaged = summary.Repo_git.unstaged_files;
                  conflicted = summary.Repo_git.conflicted_files;
                }
          | Ok _clean -> (
              match Repo_git.fast_forward ~repository ~target_ref with
              | Ok () -> Advanced { behind }
              | Error reason -> Fast_forward_refused { behind; reason })))

let sync_repository ~base_path repo : (advance_outcome, string) result =
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
      let outcome = advance_working_tree ~repository:repo_with_path in
      let* () = Repo_store.update_status ~base_path repo.id Active in
      Ok outcome

let should_sync repo ~now =
  if not repo.auto_sync then false
  else
    let elapsed = Int64.sub now repo.updated_at in
    Int64.to_int elapsed >= repo.sync_interval

let next_due_at repos =
  List.fold_left
    (fun earliest (repo : repository) ->
      if not repo.auto_sync then earliest
      else
        let due_at =
          Int64.add repo.updated_at (Int64.of_int repo.sync_interval)
        in
        match earliest with
        | None -> Some due_at
        | Some current -> Some (Int64.min current due_at))
    None repos

let sync_all ~base_path ~now :
    (sync_attempt list, string) result =
  let* repos = Repo_store.load_all ~base_path in
  let due = List.filter (fun r -> should_sync r ~now) repos in
  let rec loop attempts = function
    | [] -> Ok (List.rev attempts)
    | repository :: rest ->
        let result = sync_repository ~base_path repository in
        loop ({ repository; result } :: attempts) rest
  in
  loop [] due
