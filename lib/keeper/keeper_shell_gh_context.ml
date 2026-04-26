(** GH repo context resolution for keeper shell commands.

    Extracted from keeper_exec_shell.ml — types and resolution logic
    for binding a keeper's active task to a git repository context,
    including worktree path validation and origin slug detection. *)

open Keeper_types
open Keeper_exec_shared

(* ── Types ────────────────────────────────────────────────── *)

type gh_repo_context =
  { task_id : string
  ; git_root : string
  ; worktree_cwd : string
  ; repo_slug : string option
  }

type gh_repo_context_error =
  { code : string
  ; detail : string
  ; hint : string
  ; task_id : string option
  ; git_root : string option
  ; worktree_path : string option
  }

(* ── Constructors ─────────────────────────────────────────── *)

let gh_repo_context_error ?task_id ?git_root ?worktree_path ~code ~detail ~hint () =
  { code; detail; hint; task_id; git_root; worktree_path }
;;

let gh_claim_first_hint =
  "Call keeper_task_claim with {} first to bind an active task before using keeper_shell \
   op=gh."
;;

(* ── JSON serialization ───────────────────────────────────── *)

let gh_repo_context_error_json ~op ~cmd_display err =
  let extra_fields =
    [ Option.map (fun task_id -> "task_id", `String task_id) err.task_id
    ; Option.map (fun git_root -> "git_root", `String git_root) err.git_root
    ; Option.map
        (fun worktree_path -> "worktree_path", `String worktree_path)
        err.worktree_path
    ]
    |> List.filter_map (fun value -> value)
  in
  Yojson.Safe.to_string
    (`Assoc
        ([ "ok", `Bool false
         ; "op", `String op
         ; "command", `String cmd_display
         ; "error", `String err.code
         ; "error_category", `String "gh_repo_context"
         ; "detail", `String err.detail
         ; "hint", `String err.hint
         ]
         @ extra_fields))
;;

(* ── Resolution ───────────────────────────────────────────── *)

let resolve_gh_repo_context ~(config : Coord.config) ~(meta : keeper_meta) ~(cwd : string)
  =
  let sandbox_git_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let sandbox_worktree_cwd = if safe_is_dir cwd then cwd else sandbox_git_root in
  match meta.current_task_id with
  | None ->
    Ok
      { task_id = "(sandbox)"
      ; git_root = sandbox_git_root
      ; worktree_cwd = sandbox_worktree_cwd
      ; repo_slug = None
      }
  | Some task_id ->
    let task_id = Keeper_id.Task_id.to_string task_id in
    (match
       Coord_query.get_tasks_safe config
       |> List.find_opt (fun (task : Types.task) -> String.equal task.id task_id)
     with
     | None ->
       Error
         (gh_repo_context_error
            ~task_id
            ~code:"gh_repo_context_task_not_found"
            ~detail:"current_task_id is set, but the task is not present in the backlog."
            ~hint:
              (gh_claim_first_hint
               ^ " If you already claimed a task, refresh the keeper task binding, then \
                  retry the gh command.")
            ())
     | Some task ->
       (match task.worktree with
        | None ->
          Error
            (gh_repo_context_error
               ~task_id
               ~code:"gh_repo_context_missing_worktree"
               ~detail:
                 "The active task has no linked worktree, so gh cannot bind repository \
                  context structurally."
               ~hint:
                 (gh_claim_first_hint
                  ^ " If the task is already claimed, create/link a task worktree first, \
                     for example with masc_worktree_create { task_id, repo_name }.")
               ())
        | Some worktree ->
          let git_root = worktree.git_root in
          let worktree_cwd =
            if Filename.is_relative worktree.path
            then Filename.concat git_root worktree.path
            else worktree.path
          in
          if String.trim worktree.path = "" || not (safe_is_dir worktree_cwd)
          then
            Error
              (gh_repo_context_error
                 ~task_id
                 ~git_root
                 ~worktree_path:worktree_cwd
                 ~code:"gh_repo_context_missing_worktree_path"
                 ~detail:"The active task worktree path is missing or not a directory."
                 ~hint:
                   (gh_claim_first_hint
                    ^ " If the task is already claimed, recreate the linked task \
                       worktree, then retry the gh command.")
                 ())
          else (
            match Keeper_gh_shared.repo_slug_of_git_root ~git_root with
            | Some repo_slug ->
              Ok { task_id; git_root; worktree_cwd; repo_slug = Some repo_slug }
            | None ->
              Error
                (gh_repo_context_error
                   ~task_id
                   ~git_root
                   ~worktree_path:worktree_cwd
                   ~code:"gh_repo_context_origin_missing"
                   ~detail:
                     "The task git root has no readable origin remote owner/repo slug."
                   ~hint:
                     (gh_claim_first_hint
                      ^ " If the task is already claimed, ensure the linked task \
                         worktree points at a sandbox clone with a valid origin remote.")
                   ()))))
;;
