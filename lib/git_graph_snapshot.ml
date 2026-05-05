type repo_info =
  { id : string
  ; root : string
  ; label : string
  ; current_branch : string option
  ; head : string option
  ; dirty : bool
  ; conflict_count : int
  ; branch_count : int
  ; commit_count : int
  ; worktree_count : int
  }
[@@deriving yojson, show]

type agent_lane =
  { id : string
  ; label : string
  ; branch : string option
  ; worktree_path : string
  ; color : string
  }
[@@deriving yojson, show]

type graph_node =
  { id : string
  ; kind : string
  ; label : string
  ; repo_id : string
  ; agent_id : string option
  ; color : string option
  ; status : string
  ; conflict : bool
  ; sha : string option
  ; branch : string option
  ; detail : string option
  }
[@@deriving yojson, show]

type graph_edge =
  { id : string
  ; source : string
  ; target : string
  ; kind : string
  ; label : string option
  }
[@@deriving yojson, show]

type stats =
  { repo_count : int
  ; agent_count : int
  ; branch_count : int
  ; commit_count : int
  ; conflict_count : int
  ; dirty_count : int
  }
[@@deriving yojson, show]

type snapshot =
  { generated_at : string
  ; repos : repo_info list
  ; agents : agent_lane list
  ; nodes : graph_node list
  ; edges : graph_edge list
  ; stats : stats
  ; warnings : string list
  }
[@@deriving yojson, show]

type git_outputs =
  { repo_root : string
  ; head : string option
  ; short_head : string option
  ; current_branch : string option
  ; refs : string list
  ; commits : string list
  ; worktrees : string list
  ; status : string list
  ; merge_state : bool
  }

type ref_pointer =
  { name : string
  ; sha : string
  ; ref_kind : string
  }

type commit_row =
  { sha : string
  ; parents : string list
  ; committed_at : string option
  ; subject : string option
  }

type worktree_row =
  { path : string
  ; head : string option
  ; branch : string option
  ; detached : bool
  ; bare : bool
  }

type git_capture_hook =
  workdir:string -> string list -> (Unix.process_status * string) option

let git_capture_hook_for_tests : git_capture_hook option Atomic.t =
  Atomic.make None

let set_git_capture_hook_for_tests hook =
  Atomic.set git_capture_hook_for_tests (Some hook)

let clear_git_capture_hook_for_tests () =
  Atomic.set git_capture_hook_for_tests None

let palette =
  [| "#e63946"
   ; "#f4a261"
   ; "#e9c46a"
   ; "#2a9d8f"
   ; "#264653"
   ; "#8338ec"
   ; "#3a86ff"
   ; "#06d6a0"
   ; "#ef476f"
   ; "#118ab2"
   ; "#073b4c"
   ; "#fb5607"
  |]

let split_lines raw =
  raw
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

let split_tab line = String.split_on_char '\t' line

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let strip_prefix ~prefix s =
  if starts_with ~prefix s then
    Some (String.sub s (String.length prefix) (String.length s - String.length prefix))
  else None

let short_sha sha =
  let trimmed = String.trim sha in
  if String.length trimmed <= 10 then trimmed else String.sub trimmed 0 10

let repo_id_of_root root = Digest.string root |> Digest.to_hex |> fun s -> "repo:" ^ String.sub s 0 10

let safe_id_component s =
  s
  |> String.map (function
       | '/' | '\\' | ' ' | '\t' | ':' -> '-'
       | c -> c)

let basename path =
  let base = Filename.basename path in
  if base = "." || base = "/" || base = "" then "repo" else base

let normalize_ref_name name =
  match strip_prefix ~prefix:"refs/heads/" name with
  | Some local -> local
  | None -> (
      match strip_prefix ~prefix:"refs/remotes/" name with
      | Some remote -> remote
      | None -> name)

let ref_kind name =
  if starts_with ~prefix:"origin/" name then "remote" else "branch"

let parse_ref_line line =
  match split_tab line with
  | name :: sha :: _rest when String.trim name <> "" && String.trim sha <> "" ->
      let name = normalize_ref_name (String.trim name) in
      if name = "origin/HEAD" then None
      else Some { name; sha = String.trim sha; ref_kind = ref_kind name }
  | _ -> None

let parse_commit_line line =
  match split_tab line with
  | sha :: parents :: committed_at :: subject_parts when String.trim sha <> "" ->
      let parents =
        parents
        |> String.split_on_char ' '
        |> List.map String.trim
        |> List.filter (fun p -> p <> "")
      in
      let subject =
        match String.concat "\t" subject_parts |> String.trim with
        | "" -> None
        | s -> Some s
      in
      let committed_at =
        match String.trim committed_at with
        | "" -> None
        | s -> Some s
      in
      Some { sha = String.trim sha; parents; committed_at; subject }
  | _ -> None

let parse_worktree_branch raw =
  let raw = String.trim raw in
  match strip_prefix ~prefix:"refs/heads/" raw with
  | Some branch -> Some branch
  | None when raw <> "" -> Some raw
  | None -> None

let finish_worktree acc current =
  match current with
  | None -> acc
  | Some row -> row :: acc

let parse_worktrees lines =
  let rec loop acc current = function
    | [] -> List.rev (finish_worktree acc current)
    | line :: rest -> (
        match strip_prefix ~prefix:"worktree " line with
        | Some path ->
            let acc = finish_worktree acc current in
            loop acc
              (Some { path = String.trim path; head = None; branch = None; detached = false; bare = false })
              rest
        | None ->
            let current =
              match current with
              | None -> None
              | Some row -> (
                  match strip_prefix ~prefix:"HEAD " line with
                  | Some head -> Some { row with head = Some (String.trim head) }
                  | None -> (
                      match strip_prefix ~prefix:"branch " line with
                      | Some branch -> Some { row with branch = parse_worktree_branch branch }
                      | None when String.trim line = "detached" -> Some { row with detached = true }
                      | None when String.trim line = "bare" -> Some { row with bare = true }
                      | None -> current))
            in
            loop acc current rest)
  in
  loop [] None lines

let conflict_codes =
  [ "DD"; "AU"; "UD"; "UA"; "DU"; "AA"; "UU" ]

let status_code line =
  let trimmed = if String.length line >= 2 then line else String.trim line in
  if String.length trimmed >= 2 then String.sub trimmed 0 2 else trimmed

let is_conflict_status line =
  List.mem (status_code line) conflict_codes

let build_agents repo_root worktrees =
  worktrees
  |> List.mapi (fun idx wt ->
       let is_root =
         String.equal
           (Filename.dirname (Filename.concat wt.path "."))
           (Filename.dirname (Filename.concat repo_root "."))
       in
       let label = if is_root then "main" else basename wt.path in
       let id =
         if is_root then "main"
         else Printf.sprintf "wt-%s" (safe_id_component label)
       in
       { id
       ; label
       ; branch = wt.branch
       ; worktree_path = wt.path
       ; color = palette.(idx mod Array.length palette)
       })

let branch_agent_map (agents : agent_lane list) =
  List.fold_left
    (fun acc (agent : agent_lane) ->
      match agent.branch with
      | None -> acc
      | Some branch when List.mem_assoc branch acc -> acc
      | Some branch -> (branch, agent) :: acc)
    [] agents

let node ?agent_id ?color ?sha ?branch ?detail ~repo_id ~kind ~label ~status ~conflict id =
  { id; kind; label; repo_id; agent_id; color; status; conflict; sha; branch; detail }

let edge ?label ~kind source target =
  { id = Printf.sprintf "%s:%s->%s" kind source target; source; target; kind; label }

let snapshot_of_outputs ?repo_id ?repo_label ~generated_at outputs =
  let repo_id = Option.value repo_id ~default:(repo_id_of_root outputs.repo_root) in
  let repo_label = Option.value repo_label ~default:(basename outputs.repo_root) in
  let refs = List.filter_map parse_ref_line outputs.refs in
  let commits = List.filter_map parse_commit_line outputs.commits in
  let worktrees = parse_worktrees outputs.worktrees in
  let agents = build_agents outputs.repo_root worktrees in
  let agents_by_branch = branch_agent_map agents in
  let status_lines = outputs.status in
  let conflict_count = List.length (List.filter is_conflict_status status_lines) in
  let dirty = status_lines <> [] in
  let repo_conflict = conflict_count > 0 || outputs.merge_state in
  let current_branch = outputs.current_branch in
  let commit_nodes =
    commits
    |> List.map (fun (c : commit_row) ->
         node ~repo_id ~kind:"commit" ~label:(short_sha c.sha) ~status:"clean"
           ~conflict:false ~sha:c.sha ?detail:c.subject
           ("commit:" ^ c.sha))
  in
  let commit_edges =
    commits
    |> List.concat_map (fun (c : commit_row) ->
         List.map
           (fun parent ->
             edge ~kind:"parent" ("commit:" ^ c.sha) ("commit:" ^ parent))
           c.parents)
  in
  let ref_nodes =
    refs
    |> List.map (fun (r : ref_pointer) ->
         let branch_name =
           if r.ref_kind = "remote" then None else Some r.name
         in
         let agent = Option.bind branch_name (fun b -> List.assoc_opt b agents_by_branch) in
         let is_current =
           match current_branch with
           | Some current -> String.equal current r.name
           | None -> false
         in
         let status =
           if is_current && repo_conflict then "conflict"
           else if is_current && dirty then "dirty"
           else if is_current then "current"
           else "clean"
         in
         node ~repo_id ~kind:r.ref_kind ~label:r.name ~status
           ~conflict:(is_current && repo_conflict) ~sha:r.sha ~branch:r.name
          ?agent_id:(Option.map (fun (a : agent_lane) -> a.id) agent)
          ?color:(Option.map (fun (a : agent_lane) -> a.color) agent)
           ("ref:" ^ r.name))
  in
  let ref_edges =
    refs
    |> List.map (fun (r : ref_pointer) ->
         edge ~kind:"points_to" ("commit:" ^ r.sha) ("ref:" ^ r.name))
  in
  let worktree_nodes =
    agents
    |> List.map (fun (a : agent_lane) ->
         let status =
           match a.branch, current_branch with
           | Some branch, Some current when String.equal branch current && repo_conflict -> "conflict"
           | Some branch, Some current when String.equal branch current && dirty -> "dirty"
           | Some branch, Some current when String.equal branch current -> "current"
           | _ -> "clean"
         in
         node ~repo_id ~kind:"worktree" ~label:a.label ~status
           ~conflict:(String.equal status "conflict") ~agent_id:a.id ~color:a.color
           ?branch:a.branch ("worktree:" ^ a.id))
  in
  let worktree_edges =
    agents
    |> List.filter_map (fun (a : agent_lane) ->
         Option.map
           (fun branch -> edge ~kind:"checked_out" ("ref:" ^ branch) ("worktree:" ^ a.id))
           a.branch)
  in
  let nodes = commit_nodes @ ref_nodes @ worktree_nodes in
  let edges = commit_edges @ ref_edges @ worktree_edges in
  let repo =
    { id = repo_id
    ; root = outputs.repo_root
    ; label = repo_label
    ; current_branch
    ; head = outputs.head
    ; dirty
    ; conflict_count
    ; branch_count = List.length refs
    ; commit_count = List.length commits
    ; worktree_count = List.length worktrees
    }
  in
  { generated_at
  ; repos = [ repo ]
  ; agents
  ; nodes
  ; edges
  ; stats =
      { repo_count = 1
      ; agent_count = List.length agents
      ; branch_count = List.length refs
      ; commit_count = List.length commits
      ; conflict_count
      ; dirty_count = List.length status_lines
      }
  ; warnings = []
  }

let run_git ~timeout_sec ~workdir args =
  match Atomic.get git_capture_hook_for_tests with
  | Some hook -> hook ~workdir args
  | None ->
      let argv = [ "git"; "-C"; workdir; "--no-optional-locks" ] @ args in
      let raw_source = String.concat " " (List.map Filename.quote argv) in
      Some
        (Masc_exec.Exec_gate.run_argv_with_status
           ~actor:"system/git_graph_snapshot"
           ~raw_source
           ~summary:"dashboard git graph snapshot"
           ~timeout_sec argv)

let run_git_output ~workdir args =
  match run_git ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ()) ~workdir args with
  | Some (Unix.WEXITED 0, output) -> Some output
  | _ -> None

let run_git_lines ~workdir args =
  run_git_output ~workdir args
  |> Option.map split_lines
  |> Option.value ~default:[]

let option_non_empty = function
  | Some s when s <> "" -> Some s
  | _ -> None

let git_path_exists ~workdir path_name =
  match run_git_output ~workdir [ "rev-parse"; "--git-path"; path_name ] with
  | None -> false
  | Some raw ->
      let path = String.trim raw in
      let path = if Filename.is_relative path then Filename.concat workdir path else path in
      Sys.file_exists path

let merge_state ~workdir =
  git_path_exists ~workdir "MERGE_HEAD"
  || git_path_exists ~workdir "rebase-merge"
  || git_path_exists ~workdir "rebase-apply"

let default_repo_root ~(config : Coord.config) =
  let candidates = [ Sys.getcwd (); config.base_path ] in
  let rec loop = function
    | [] -> None
    | candidate :: rest -> (
        match Coord_git.git_root ~base_path:candidate with
        | Some root -> Some root
        | None -> loop rest)
  in
  loop candidates

let capture_outputs ?repo_root ~config ~limit () =
  let resolved_repo_root =
    match repo_root with
    | None -> default_repo_root ~config
    | Some requested -> Coord_git.git_root ~base_path:requested
  in
  match resolved_repo_root with
  | None -> (
      match repo_root with
      | None -> Error "server cwd and configured base_path are outside a git repository"
      | Some requested ->
        Error (Printf.sprintf "configured repository is outside a git repository: %s" requested))
  | Some repo_root ->
      let head = run_git_output ~workdir:repo_root [ "rev-parse"; "HEAD" ] |> Option.map String.trim in
      let short_head =
        run_git_output ~workdir:repo_root [ "rev-parse"; "--short"; "HEAD" ]
        |> Option.map String.trim
      in
      let current_branch =
        run_git_output ~workdir:repo_root [ "branch"; "--show-current" ]
        |> Option.map String.trim
        |> option_non_empty
      in
      let refs =
        run_git_lines ~workdir:repo_root
          [ "for-each-ref"
          ; "--count=" ^ string_of_int limit
          ; "--sort=-committerdate"
          ; "--format=%(refname:short)%09%(objectname)"
          ; "refs/heads"
          ; "refs/remotes/origin"
          ]
      in
      let commits =
        run_git_lines ~workdir:repo_root
          [ "log"
          ; "--all"
          ; "--date=iso-strict"
          ; "--pretty=format:%H%x09%P%x09%ad%x09%s"
          ; "-n"
          ; string_of_int limit
          ]
      in
      let worktrees = run_git_lines ~workdir:repo_root [ "worktree"; "list"; "--porcelain" ] in
      let status =
        run_git_lines ~workdir:repo_root
          [ "status"; "--porcelain"; "--untracked-files=no" ]
      in
      Ok
        { repo_root
        ; head
        ; short_head
        ; current_branch
        ; refs
        ; commits
        ; worktrees
        ; status
        ; merge_state = merge_state ~workdir:repo_root
        }

let empty_json warning =
  { generated_at = Masc_domain.now_iso ()
  ; repos = []
  ; agents = []
  ; nodes = []
  ; edges = []
  ; stats =
      { repo_count = 0
      ; agent_count = 0
      ; branch_count = 0
      ; commit_count = 0
      ; conflict_count = 0
      ; dirty_count = 0
      }
  ; warnings = [ warning ]
  }
  |> snapshot_to_yojson

let dashboard_http_json ?repo_id ?repo_label ?repo_root ~config ~limit () =
  match capture_outputs ?repo_root ~config ~limit () with
  | Ok outputs ->
      snapshot_of_outputs ?repo_id ?repo_label
        ~generated_at:(Masc_domain.now_iso ()) outputs
      |> snapshot_to_yojson
  | Error warning ->
      empty_json warning
