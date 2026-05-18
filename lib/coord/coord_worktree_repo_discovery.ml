(** Coord Worktree - Repo discovery, evidence scoring, and workspace scan.

    Read-only helpers that decide *which* repository a task should land on:

    - {!repo_candidates_in_dir} enumerates sandbox clones under
      [repos_dir_of_keeper].
    - {!workspace_repo_matches} bounds a recursive scan of the project root
      to find matching workspace repos when no sandbox clone exists yet.
    - {!infer_task_repo_name} scores task evidence (title, description,
      handoff context, path hints) against the candidates.

    No filesystem mutation; subprocess use is limited to [git -C ... config
    --get remote.origin.url] via {!git_origin_url}.

    Stage 06, godfile decomposition plan 2026-05-18. *)

open Masc_domain
open Coord_utils

type repo_candidate = {
  name : string;
  path : string;
}

let trim_repo_token token =
  let is_edge = function
    | '`' | '\'' | '"' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
    | ',' | ';' | ':' | '!' | '?' | '.' -> true
    | _ -> false
  in
  let len = String.length token in
  let rec left i =
    if i >= len then len
    else if is_edge token.[i] then left (i + 1)
    else i
  in
  let rec right i =
    if i < 0 then -1
    else if is_edge token.[i] then right (i - 1)
    else i
  in
  let l = left 0 in
  let r = right (len - 1) in
  if r < l then "" else String.sub token l (r - l + 1)

let tokenize_repo_evidence text =
  let mapped =
    String.map
      (function
        | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.'
          | '/') as c -> c
        | _ -> ' ')
      text
  in
  mapped
  |> String.split_on_char ' '
  |> List.map trim_repo_token
  |> List.filter (fun token -> token <> "")

let strip_git_suffix token =
  if String.ends_with ~suffix:".git" token then
    String.sub token 0 (String.length token - 4)
  else
    token

let normalize_repo_alias token =
  token |> trim_repo_token |> String.lowercase_ascii |> strip_git_suffix

let repo_token_variants token =
  let token = normalize_repo_alias token in
  let basename = Filename.basename token |> normalize_repo_alias in
  let split_parts =
    token
    |> String.split_on_char '/'
    |> List.concat_map (String.split_on_char '_')
    |> List.concat_map (String.split_on_char '-')
    |> List.concat_map (String.split_on_char '.')
    |> List.map normalize_repo_alias
  in
  token :: basename :: split_parts
  |> List.filter (fun s -> s <> "")
  |> List.sort_uniq String.compare

let repo_exact_alias_variants token =
  let token = normalize_repo_alias token in
  let basename = Filename.basename token |> normalize_repo_alias in
  [ token; basename ]
  |> List.filter (fun s -> s <> "")
  |> List.sort_uniq String.compare

let toml_table_opt value =
  try Some (Otoml.get_table value) with
  | _ -> None

let toml_string_opt tbl key =
  match List.assoc_opt key tbl with
  | None -> None
  | Some value -> (
      try Some (Otoml.get_string value) with
      | _ -> None)

let toml_string_array_or_empty tbl key =
  match List.assoc_opt key tbl with
  | None -> []
  | Some value -> (
      try Otoml.get_array Otoml.get_string value with
      | _ -> [])

let repository_config_path config =
  Filename.concat
    (Filename.concat
       (masc_dir_from_base_path ~base_path:config.base_path)
       "config")
    "repositories.toml"

let repository_aliases_for_candidate config ~repo_name =
  let repo_name = normalize_repo_alias repo_name in
  let path = repository_config_path config in
  if repo_name = "" || not (Coord_worktree_paths.safe_file_exists path) then
    []
  else
    try
      let toml = Otoml.Parser.from_file path in
      match Otoml.find_opt toml Fun.id [ "repository" ] with
      | None -> []
      | Some repositories -> (
          match toml_table_opt repositories with
          | None -> []
          | Some rows ->
            rows
            |> List.concat_map (fun (section_name, value) ->
                   match toml_table_opt value with
                   | None -> []
                   | Some tbl ->
                     let derived_aliases =
                       [ Some section_name
                       ; toml_string_opt tbl "name"
                       ; Option.map Filename.basename (toml_string_opt tbl "url")
                       ; Option.map Filename.basename (toml_string_opt tbl "local_path")
                       ]
                       |> List.filter_map Fun.id
                       |> List.concat_map repo_exact_alias_variants
                     in
                     let configured_aliases =
                       toml_string_array_or_empty tbl "aliases"
                       |> List.concat_map repo_token_variants
                     in
                     let aliases =
                       derived_aliases @ configured_aliases
                       |> List.sort_uniq String.compare
                     in
                     if List.mem repo_name aliases then aliases else [])
            |> List.sort_uniq String.compare)
    with
    | _ -> []

(* Route to the SSOT helper rather than allocating String.sub on every
   step.  Keeps semantics aligned across modules (empty needle returns
   true). *)
let contains_substring = String_util.contains_substring

let task_repo_text (task : task) =
  let handoff_texts =
    match task.handoff_context with
    | None -> []
    | Some handoff ->
        [ Some handoff.summary
        ; handoff.reason
        ; handoff.next_step
        ; handoff.failure_mode
        ]
        |> List.filter_map Fun.id
  in
  String.concat "\n" (task.title :: task.description :: handoff_texts)

(* Reject any path-hint candidate whose components include a literal
   ".." segment.  Substring matching falsely flagged legitimate names
   like "..config.ts.bak" (filename containing ".."), and missed
   embedded segments such as "src/foo/../bar" only by accident.
   Splitting on '/' and checking segments is both more precise and
   the same definition the OS uses for parent-traversal. *)
let has_parent_segment token =
  String.split_on_char '/' token
  |> List.exists (fun seg -> String.equal seg "..")

let task_path_hints (task : task) =
  let text_paths =
    task_repo_text task
    |> tokenize_repo_evidence
    |> List.filter (fun token ->
           contains_substring token "/"
           && Filename.is_relative token
           && not (has_parent_segment token))
  in
  (task.files @ text_paths)
  |> List.map trim_repo_token
  |> List.filter (fun token ->
         token <> ""
         && Filename.is_relative token
         && not (has_parent_segment token))
  |> List.sort_uniq String.compare

let repo_candidates_in_dir repos_dir =
  if not (Coord_worktree_paths.safe_is_dir repos_dir) then []
  else
    let entries =
      try Sys.readdir repos_dir |> Array.to_list with Sys_error _ -> []
    in
    entries
    |> List.filter Coord_worktree_paths.safe_repo_name
    |> List.filter_map (fun name ->
           let path = Filename.concat repos_dir name in
           if Coord_worktree_paths.is_git_clone path then Some { name; path } else None)
    |> List.sort (fun a b -> String.compare a.name b.name)

let repo_name_mentioned ~tokens repo_name =
  let aliases =
    [ normalize_repo_alias repo_name
    ; Filename.basename repo_name |> normalize_repo_alias
    ]
    |> List.filter (fun s -> s <> "")
    |> List.sort_uniq String.compare
  in
  let token_variants =
    tokens |> List.concat_map repo_token_variants |> List.sort_uniq String.compare
  in
  List.exists (fun alias -> List.mem alias token_variants) aliases

let repo_alias_mentioned ~tokens ~aliases =
  let aliases =
    aliases |> List.concat_map repo_token_variants |> List.sort_uniq String.compare
  in
  let token_variants =
    tokens |> List.concat_map repo_token_variants |> List.sort_uniq String.compare
  in
  List.exists (fun alias -> List.mem alias token_variants) aliases

let task_by_id config task_id =
  let backlog = Coord_backlog.read_backlog config in
  List.find_opt (fun (task : task) -> String.equal task.id task_id)
    backlog.tasks

let max_path_hints = 20
let mention_score_value = 100
let file_score_weight = 25

let score_repo_candidate config ~(task : task) ~tokens ~path_hints candidate =
  let aliases =
    repository_aliases_for_candidate config ~repo_name:candidate.name
  in
  let mention_score =
    if
      repo_name_mentioned ~tokens candidate.name
      || repo_alias_mentioned ~tokens ~aliases
    then mention_score_value
    else 0
  in
  let file_score =
    if mention_score >= mention_score_value then 0
    else
      path_hints
      |> List.filteri (fun i _ -> i < max_path_hints)
      |> List.filter (fun rel_path ->
             Coord_worktree_paths.safe_file_exists
               (Filename.concat candidate.path rel_path))
      |> List.length
      |> ( * ) file_score_weight
  in
  let worktree_score =
    match task.worktree with
    | Some wt when String.equal wt.repo_name candidate.name -> 5
    | _ -> 0
  in
  mention_score + file_score + worktree_score

(* Hoisted above [infer_task_repo_name] so the candidates=[] path can
   validate task-evidence mentions against the workspace before
   returning. *)
let workspace_repo_matches ~search_root ~repo_name ?(max_dirs = 4000)
    ?(max_entries = 20000) () =
  let max_dirs = max 0 max_dirs in
  let max_entries = max 0 max_entries in
  let max_matches = 8 in
  let preferred_dir_name = function
    | "workspace" | "workspaces" | "repos" | "projects" | "src" -> true
    | _ -> false
  in
  let entry_priority entry =
    if entry = repo_name then 0
    else if preferred_dir_name entry then 1
    else if String.length entry > 0 && entry.[0] = '.' then 3
    else 2
  in
  let skip_dir_name name =
    name = ".git" || name = ".hg" || name = ".svn"
    || name = Common.masc_dirname || name = ".worktrees"
    || name = "_build" || name = "node_modules"
  in
  let matches =
    if Filename.basename search_root = repo_name
       && Coord_worktree_paths.is_git_clone search_root
    then ref [ search_root ]
    else ref []
  in
  let queue = Queue.create () in
  Queue.add search_root queue;
  let dirs_seen = ref 0 in
  let entries_seen = ref 0 in
  while
    !dirs_seen < max_dirs
    && !entries_seen < max_entries
    && Queue.length queue > 0
    && List.length !matches < max_matches
  do
    let dir = Queue.take queue in
    incr dirs_seen;
    let entries =
      try Sys.readdir dir with Sys_error _ -> [||]
    in
    Array.sort
      (fun a b ->
         match compare (entry_priority a) (entry_priority b) with
         | 0 -> compare a b
         | n -> n)
      entries;
    Array.iter
      (fun entry ->
         if
           !entries_seen < max_entries
           && List.length !matches < max_matches
           && not (skip_dir_name entry)
         then begin
           incr entries_seen;
           let path = Filename.concat dir entry in
           if Coord_worktree_paths.safe_is_dir path then begin
             let is_git_repo_dir = Coord_worktree_paths.has_git_marker path in
             if entry = repo_name && is_git_repo_dir then
               matches := path :: !matches;
             if not is_git_repo_dir then Queue.add path queue
           end
         end)
      entries
  done;
  List.sort_uniq String.compare !matches

let git_origin_url root =
  match
    Coord_worktree_exec.run_argv_with_status
      [ "git"; "-C"; root; "remote"; "get-url"; "origin" ]
  with
  | Unix.WEXITED 0, output -> Coord_worktree_exec.first_nonempty_line output
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None

let infer_task_repo_name config ~agent_name ~task_id =
  let repos_dir = Coord_worktree_paths.repos_dir_of_keeper config agent_name in
  let candidates = repo_candidates_in_dir repos_dir in
  match task_by_id config task_id with
  | None -> (
      match candidates with
      | [] -> Ok None
      | [ candidate ] -> Ok (Some candidate.name)
      | _ ->
          Error
            (System (System_error.IoError
               (Printf.sprintf
                  "ambiguous_task_repo: task %s is not in backlog and sandbox has multiple repos [%s]"
                  task_id
                  (String.concat ", " (List.map (fun c -> c.name) candidates))))))
  | Some task -> (
      match candidates with
      | [] -> (
          (* Sandbox is empty.  Prefer a previously-linked
             [task.worktree.repo_name]; otherwise scan task evidence
             for a unique safe_repo_name mention that resolves to
             exactly one workspace repo via [workspace_repo_matches]
             — [worktree_create_r] will then [auto_provision_sandbox_clone]
             on demand.  Returning [Ok None] here would be a silent
             stranding of the task (caller falls to
             [missing_sandbox_clone] with no actionable repo hint),
             which contradicts the PR's "infer from task evidence"
             contract.  Multiple workspace matches escalate to
             [ambiguous_task_repo] for the same reason as the
             multi-candidate path. *)
          match task.worktree with
          | Some wt when Coord_worktree_paths.safe_repo_name wt.repo_name ->
              Ok (Some wt.repo_name)
          | _ ->
              let tokens = tokenize_repo_evidence (task_repo_text task) in
              let mention_candidates =
                tokens
                (* Allow URL-path mentions like "github.com/org/masc-mcp"
                   to surface "masc-mcp" via Filename.basename. *)
                |> List.concat_map (fun t -> [ t; Filename.basename t ])
                |> List.filter Coord_worktree_paths.safe_repo_name
                |> List.sort_uniq String.compare
              in
              let search_root = Coord_worktree_paths.project_root config in
              let workspace_unique =
                mention_candidates
                |> List.filter_map (fun name ->
                       match
                         workspace_repo_matches ~search_root ~repo_name:name
                           ()
                       with
                       | [ _ ] -> Some name
                       | _ -> None)
                |> List.sort_uniq String.compare
              in
              (match workspace_unique with
               | [] -> Ok None
               | [ name ] -> Ok (Some name)
               | many ->
                   Error
                     (System (System_error.IoError
                        (Printf.sprintf
                           "ambiguous_task_repo: task %s has no sandbox \
                            clone, and task evidence mentions multiple \
                            workspace repos [%s]"
                           task_id (String.concat ", " many))))))
      | [ candidate ] -> Ok (Some candidate.name)
      | _ ->
          let tokens = tokenize_repo_evidence (task_repo_text task) in
          let path_hints = task_path_hints task in
          let ranked =
            candidates
            |> List.map (fun candidate ->
                   ( score_repo_candidate config ~task ~tokens ~path_hints candidate
                   , candidate ))
            |> List.sort (fun (sa, a) (sb, b) ->
                   match compare sb sa with
                   | 0 -> String.compare a.name b.name
                   | n -> n)
          in
          match ranked with
          | (top_score, top_candidate) :: (second_score, _) :: _
            when top_score > 0 && top_score > second_score ->
              Ok (Some top_candidate.name)
          | (top_score, top_candidate) :: [] when top_score > 0 ->
              Ok (Some top_candidate.name)
          | (top_score, _) :: _ when top_score > 0 ->
              let tied =
                ranked
                |> List.filter (fun (score, _) -> score = top_score)
                |> List.map (fun (_, candidate) -> candidate.name)
              in
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "ambiguous_task_repo: task %s matches multiple repos with equal score [%s]"
                      task_id (String.concat ", " tied))))
          | _ ->
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "ambiguous_task_repo: task %s has no repo evidence; sandbox repos=[%s]"
                      task_id
                      (String.concat ", "
                         (List.map (fun c -> c.name) candidates))))))
