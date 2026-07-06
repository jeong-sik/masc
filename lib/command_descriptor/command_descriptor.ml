type t =
  | Gh_pr_create of { title : string; base : string; draft : bool }
  | Gh_pr_search of { query : string; state : string option }
  | Gh_pr_merge of { pr_number : int; squash : bool }
  | Gh_pr_comment of { pr_number : int; body : string }
  | Gh_pr_close of { pr_number : int }
  | Gh_pr_edit of { pr_number : int; title : string option }
  | Gh_pr_review of { pr_number : int }
  | Gh_issue_create of { title : string; body : string }
  | Gh_issue_close of { issue_number : int }
  | Git_push of { remote : string; branch : string; force : bool }
  | Git_commit of { message : string }
  | Gh_api_pr_create of { repo : string; title : string; base : string }
  | Gh_api_pr_merge of { repo : string; pr_number : int }
  | Gh_api_pr_comment of { repo : string; pr_number : int; body : string }
  | Pipe_chain of { first_cmd : string; last_cmd : string; length : int }
  | Generic

type pr_action_surface =
  | Gh_cli

type pr_action =
  | Create
  | Search
  | Merge
  | Comment
  | Close
  | Edit
  | Review
  | Reopen
  | Ready

type pr_action_event =
  { surface : pr_action_surface
  ; action : pr_action
  }

let pr_action_surface_to_string = function
  | Gh_cli -> "gh_cli"
;;

let pr_action_to_string = function
  | Create -> "create"
  | Search -> "search"
  | Merge -> "merge"
  | Comment -> "comment"
  | Close -> "close"
  | Edit -> "edit"
  | Review -> "review"
  | Reopen -> "reopen"
  | Ready -> "ready"
;;

let to_json = function
  | Gh_pr_create { title; base; draft } ->
    `Assoc
      [ "kind", `String "gh_pr_create"
      ; "title", `String title
      ; "base", `String base
      ; "draft", `Bool draft
      ]
  | Gh_pr_search { query; state } ->
    `Assoc
      [ "kind", `String "gh_pr_search"
      ; "query", `String query
      ; "state", (match state with Some s -> `String s | None -> `Null)
      ; "duplicate_search", `Bool true
      ]
  | Gh_pr_merge { pr_number; squash } ->
    `Assoc
      [ "kind", `String "gh_pr_merge"; "pr_number", `Int pr_number; "squash", `Bool squash ]
  | Gh_pr_comment { pr_number; body } ->
    `Assoc
      [ "kind", `String "gh_pr_comment"; "pr_number", `Int pr_number; "body", `String body ]
  | Gh_pr_close { pr_number } ->
    `Assoc [ "kind", `String "gh_pr_close"; "pr_number", `Int pr_number ]
  | Gh_pr_edit { pr_number; title } ->
    `Assoc
      [ "kind", `String "gh_pr_edit"
      ; "pr_number", `Int pr_number
      ; "title", (match title with Some t -> `String t | None -> `Null)
      ]
  | Gh_pr_review { pr_number } ->
    `Assoc [ "kind", `String "gh_pr_review"; "pr_number", `Int pr_number ]
  | Gh_issue_create { title; body } ->
    `Assoc
      [ "kind", `String "gh_issue_create"; "title", `String title; "body", `String body ]
  | Gh_issue_close { issue_number } ->
    `Assoc [ "kind", `String "gh_issue_close"; "issue_number", `Int issue_number ]
  | Git_push { remote; branch; force } ->
    `Assoc
      [ "kind", `String "git_push"
      ; "remote", `String remote
      ; "branch", `String branch
      ; "force", `Bool force
      ]
  | Git_commit { message } ->
    `Assoc [ "kind", `String "git_commit"; "message", `String message ]
  | Gh_api_pr_create { repo; title; base } ->
    `Assoc
      [ "kind", `String "gh_api_pr_create"
      ; "repo", `String repo
      ; "title", `String title
      ; "base", `String base
      ]
  | Gh_api_pr_merge { repo; pr_number } ->
    `Assoc
      [ "kind", `String "gh_api_pr_merge"; "repo", `String repo; "pr_number", `Int pr_number ]
  | Gh_api_pr_comment { repo; pr_number; body } ->
    `Assoc
      [ "kind", `String "gh_api_pr_comment"
      ; "repo", `String repo
      ; "pr_number", `Int pr_number
      ; "body", `String body
      ]
  | Pipe_chain { first_cmd; last_cmd; length } ->
    `Assoc
      [ "kind", `String "pipe_chain"
      ; "first_cmd", `String first_cmd
      ; "last_cmd", `String last_cmd
      ; "length", `Int length
      ]
  | Generic -> `Assoc [ "kind", `String "generic" ]
;;

module Shape = Masc_exec.Shell_ir_command_shape
module Typed = Masc_exec.Shell_ir_typed_types

let extract_flag_from_rest rest ~flag ~short ~default =
  let flag_eq = flag ^ "=" in
  let rec scan = function
    | [] -> default
    | arg :: value :: _ when String.equal arg flag -> value
    | arg :: _
      when String.length arg > String.length flag_eq
           && String.sub arg 0 (String.length flag_eq) = flag_eq ->
      String.sub arg (String.length flag_eq) (String.length arg - String.length flag_eq)
    | arg :: value :: _
      when (match short with
            | Some s -> String.equal arg s
            | None -> false) -> value
    | _ :: rest -> scan rest
  in
  scan rest
;;

let extract_number_from_rest rest =
  let rec scan = function
    | [] -> 0
    | s :: _ when (match int_of_string_opt s with Some n -> n > 0 | None -> false) ->
      (match int_of_string_opt s with
       | Some n -> n
       | None -> 0)
    | _ :: rest -> scan rest
  in
  scan rest
;;

let string_or default = function
  | Some value -> value
  | None -> default
;;

let pr_action_of_gh_action = function
  | Some "create" -> Some Create
  | Some "merge" -> Some Merge
  | Some "comment" -> Some Comment
  | Some "close" -> Some Close
  | Some "edit" -> Some Edit
  | Some "review" -> Some Review
  | Some "reopen" -> Some Reopen
  | Some "ready" -> Some Ready
  | Some _ | None -> None
;;

let compute_typed : type i o r s. (i, o, r, s) Typed.command -> t = function
  | Typed.Gh { subcommand; action; title; draft; squash; body; search; state; rest; _ } ->
    (match subcommand, action with
     | "pr", Some "create" ->
       let base = extract_flag_from_rest rest ~flag:"--base" ~short:(Some "-b") ~default:"main" in
       Gh_pr_create { title = string_or "" title; base; draft }
     | "pr", Some "list" ->
       (match search with
        | Some query -> Gh_pr_search { query; state }
        | None -> Generic)
     | "pr", Some "merge" -> Gh_pr_merge { pr_number = extract_number_from_rest rest; squash }
     | "pr", Some "comment" ->
       Gh_pr_comment { pr_number = extract_number_from_rest rest; body = string_or "" body }
     | "pr", Some "close" -> Gh_pr_close { pr_number = extract_number_from_rest rest }
     | "pr", Some "edit" -> Gh_pr_edit { pr_number = extract_number_from_rest rest; title }
     | "pr", Some "review" -> Gh_pr_review { pr_number = extract_number_from_rest rest }
     | "pr", Some "reopen" -> Gh_pr_close { pr_number = extract_number_from_rest rest }
     | "pr", Some "ready" -> Gh_pr_review { pr_number = extract_number_from_rest rest }
     | "issue", Some "create" ->
       Gh_issue_create { title = string_or "" title; body = string_or "" body }
     | "issue", Some "close" -> Gh_issue_close { issue_number = extract_number_from_rest rest }
     | "issue", Some "reopen" -> Gh_issue_close { issue_number = extract_number_from_rest rest }
     | _ -> Generic)
  | Typed.Git_push { force; force_with_lease; remote; branch; _ } ->
    Git_push
      { remote = string_or "origin" remote
      ; branch = string_or "main" branch
      ; force = force || force_with_lease
      }
  | Typed.Git_commit { message; amend } ->
    Git_commit { message = if amend then message ^ " (amend)" else message }
  | Typed.Git_merge { squash; _ } -> Gh_pr_merge { pr_number = 0; squash }
  | Typed.Curl { url; method_; body; _ } ->
    let is_github_api =
      String.length url > 23 && String.sub url 0 23 = "https://api.github.com/"
    in
    if is_github_api
    then (
      let parts = String.split_on_char '/' url in
      let rec find_repo = function
        | "repos" :: owner :: repo :: _ -> Some (owner ^ "/" ^ repo)
        | _ :: rest -> find_repo rest
        | [] -> None
      in
      let rec find_pr_number = function
        | ("pulls" | "pull") :: n :: _ ->
          (match int_of_string_opt n with
           | Some i -> i
           | None -> 0)
        | _ :: rest -> find_pr_number rest
        | [] -> 0
      in
      let extract_json_string ~field body_str ~default =
        try
          let json = Yojson.Safe.from_string body_str in
          Yojson.Safe.Util.member field json |> Yojson.Safe.Util.to_string
        with
        | _ -> default
      in
      match find_repo parts with
      | Some repo ->
        (match method_ with
         | `POST ->
           let title =
             match body with
             | Some b -> extract_json_string ~field:"title" b ~default:""
             | None -> ""
           in
           let base =
             match body with
             | Some b -> extract_json_string ~field:"base" b ~default:"main"
             | None -> "main"
           in
           Gh_api_pr_create { repo; title; base }
         | `PUT -> Gh_api_pr_merge { repo; pr_number = find_pr_number parts }
         | `DELETE -> Gh_api_pr_comment { repo; pr_number = find_pr_number parts; body = "" }
         | _ -> Generic)
      | None -> Generic)
    else Generic
  | Typed.Ls _
  | Typed.Cat _
  | Typed.Rg _
  | Typed.Git_status _
  | Typed.Git_clone _
  | Typed.Rm _
  | Typed.Sudo _
  | Typed.Find _
  | Typed.Head _
  | Typed.Tail _
  | Typed.Grep _
  | Typed.Mkdir _
  | Typed.Wc _
  | Typed.Git_diff _
  | Typed.Git_log _
  | Typed.Git_pull _
  | Typed.Git_stash _
  | Typed.Git_rebase _
  | Typed.Git_branch _
  | Typed.Git_checkout _
  | Typed.Git_fetch _
  | Typed.Git_show _
  | Typed.Git_reset _
  | Typed.Git_blame _
  | Typed.Git_add _
  | Typed.Pwd _
  | Typed.Echo _
  | Typed.Which _
  | Typed.Sort _
  | Typed.Cut _
  | Typed.Tr _
  | Typed.Date _
  | Typed.Env _
  | Typed.Printenv _
  | Typed.Uniq _
  | Typed.Basename _
  | Typed.Dirname _
  | Typed.Test _
  | Typed.Stat _
  | Typed.Hostname _
  | Typed.Whoami _
  | Typed.Du _
  | Typed.Df _
  | Typed.File _
  | Typed.Printf _
  | Typed.Uname _
  | Typed.Ps _
  | Typed.Tty _
  | Typed.Wget _
  | Typed.Ssh _
  | Typed.Scp _
  | Typed.Tar _
  | Typed.Make _
  | Typed.Diff _
  | Typed.Sed _
  | Typed.Rsync _
  | Typed.Node _
  | Typed.Python _
  | Typed.Python3 _
  | Typed.Pip _
  | Typed.Patch _
  | Typed.Npm _
  | Typed.Cargo _
  | Typed.Go _
  | Typed.Chmod _
  | Typed.Chown _
  | Typed.Docker _
  | Typed.Opam _
  | Typed.Npx _
  | Typed.Yarn _
  | Typed.Pnpm _
  | Typed.Uv _
  | Typed.Glab _
  | Typed.Pytest _
  | Typed.Terminal_notifier _
  | Typed.Ruff _
  | Typed.Pyright _
  | Typed.Tsc _
  | Typed.Ocamlfind _
  | Typed.Rustc _
  | Typed.Gofmt _
  | Typed.Gradle _
  | Typed.Ninja _
  | Typed.Java _
  | Typed.Javac _
  | Typed.Mvn _
  | Typed.Cmake _
  | Typed.Dune_local_sh _
  | Typed.Osascript _
  | Typed.Play _
  | Typed.Rec _
  | Typed.Ffplay _
  | Typed.Mpg123 _
  | Typed.Open _
  | Typed.Su _
  | Typed.Dd _
  | Typed.Mkfs _
  | Typed.Cp _
  | Typed.Mv _
  | Typed.Ln _
  | Typed.Touch _
  | Typed.Tee _
  | Typed.Awk _
  | Typed.Xargs _
  | Typed.Generic _ -> Generic
;;

let compute_simple simple =
  match Masc_exec.Shell_ir_typed.of_simple simple with
  | Typed.W command -> compute_typed command
;;

let rec compute ir =
  match ir with
  | Masc_exec.Shell_ir.Simple simple -> compute_simple simple
  | Masc_exec.Shell_ir.Pipeline cmds ->
    (match List.rev cmds with
     | last_cmd :: _ ->
       (match compute last_cmd with
        | Generic ->
          (match Shape.first_command_name ir, Shape.last_command_name ir with
           | Some first_cmd, Some last_cmd ->
             let length = Shape.top_level_stage_count ir in
             Pipe_chain { first_cmd; last_cmd; length }
           | (None, Some _) | (Some _, None) | (None, None) -> Generic)
        | ( Gh_pr_create _
          | Gh_pr_search _
          | Gh_pr_merge _
          | Gh_pr_comment _
          | Gh_pr_close _
          | Gh_pr_edit _
          | Gh_pr_review _
          | Gh_issue_create _
          | Gh_issue_close _
          | Git_push _
          | Git_commit _
          | Gh_api_pr_create _
          | Gh_api_pr_merge _
          | Gh_api_pr_comment _
          | Pipe_chain _ ) as known -> known)
     | [] -> Generic)
;;

let pr_action_event_of_typed
  : type i o r s. (i, o, r, s) Typed.command -> pr_action_event option
  = function
  | Typed.Gh { subcommand; action = Some "list"; search = Some _; _ }
    when String.equal subcommand "pr" -> Some { surface = Gh_cli; action = Search }
  | Typed.Gh { subcommand; action = Some "list"; search = None; _ }
    when String.equal subcommand "pr" -> None
  | Typed.Gh { subcommand; action; _ } when String.equal subcommand "pr" ->
    Option.map (fun action -> { surface = Gh_cli; action }) (pr_action_of_gh_action action)
  | Typed.Gh _
  | Typed.Ls _
  | Typed.Cat _
  | Typed.Rg _
  | Typed.Git_status _
  | Typed.Git_clone _
  | Typed.Curl _
  | Typed.Rm _
  | Typed.Sudo _
  | Typed.Find _
  | Typed.Head _
  | Typed.Tail _
  | Typed.Grep _
  | Typed.Mkdir _
  | Typed.Wc _
  | Typed.Git_diff _
  | Typed.Git_log _
  | Typed.Git_commit _
  | Typed.Git_push _
  | Typed.Git_pull _
  | Typed.Git_stash _
  | Typed.Git_rebase _
  | Typed.Git_merge _
  | Typed.Git_branch _
  | Typed.Git_checkout _
  | Typed.Git_fetch _
  | Typed.Git_show _
  | Typed.Git_reset _
  | Typed.Git_blame _
  | Typed.Git_add _
  | Typed.Pwd _
  | Typed.Echo _
  | Typed.Which _
  | Typed.Sort _
  | Typed.Cut _
  | Typed.Tr _
  | Typed.Date _
  | Typed.Env _
  | Typed.Printenv _
  | Typed.Uniq _
  | Typed.Basename _
  | Typed.Dirname _
  | Typed.Test _
  | Typed.Stat _
  | Typed.Hostname _
  | Typed.Whoami _
  | Typed.Du _
  | Typed.Df _
  | Typed.File _
  | Typed.Printf _
  | Typed.Uname _
  | Typed.Ps _
  | Typed.Tty _
  | Typed.Wget _
  | Typed.Ssh _
  | Typed.Scp _
  | Typed.Tar _
  | Typed.Make _
  | Typed.Diff _
  | Typed.Sed _
  | Typed.Rsync _
  | Typed.Node _
  | Typed.Python _
  | Typed.Python3 _
  | Typed.Pip _
  | Typed.Patch _
  | Typed.Npm _
  | Typed.Cargo _
  | Typed.Go _
  | Typed.Chmod _
  | Typed.Chown _
  | Typed.Docker _
  | Typed.Opam _
  | Typed.Npx _
  | Typed.Yarn _
  | Typed.Pnpm _
  | Typed.Uv _
  | Typed.Glab _
  | Typed.Pytest _
  | Typed.Terminal_notifier _
  | Typed.Ruff _
  | Typed.Pyright _
  | Typed.Tsc _
  | Typed.Ocamlfind _
  | Typed.Rustc _
  | Typed.Gofmt _
  | Typed.Gradle _
  | Typed.Ninja _
  | Typed.Java _
  | Typed.Javac _
  | Typed.Mvn _
  | Typed.Cmake _
  | Typed.Dune_local_sh _
  | Typed.Osascript _
  | Typed.Play _
  | Typed.Rec _
  | Typed.Ffplay _
  | Typed.Mpg123 _
  | Typed.Open _
  | Typed.Su _
  | Typed.Dd _
  | Typed.Mkfs _
  | Typed.Cp _
  | Typed.Mv _
  | Typed.Ln _
  | Typed.Touch _
  | Typed.Tee _
  | Typed.Awk _
  | Typed.Xargs _
  | Typed.Generic _ -> None
;;

let pr_action_events_of_simple simple =
  match Masc_exec.Shell_ir_typed.of_simple simple with
  | Typed.W command ->
    (match pr_action_event_of_typed command with
     | Some event -> [ event ]
     | None -> [])
;;

let rec pr_action_events_of_ir = function
  | Masc_exec.Shell_ir.Simple simple -> pr_action_events_of_simple simple
  | Masc_exec.Shell_ir.Pipeline cmds -> List.concat_map pr_action_events_of_ir cmds
;;
