(** Mutation/destructive command classifiers for worker dev tools. *)

let is_write_operation cmd =
  let parts = String.split_on_char ' ' (String.trim cmd) in
  match parts with
  | "git" :: sub :: _ ->
    List.mem
      sub
      [ "push"
      ; "commit"
      ; "merge"
      ; "rebase"
      ; "reset"
      ; "checkout"
      ; "branch"
      ; "tag"
      ; "stash"
      ; "clone"
      ; "init"
      ]
  | "dune" :: sub :: _ -> List.mem sub [ "clean"; "promote" ]
  | "make" :: sub :: _ -> List.mem sub [ "clean"; "deploy"; "install"; "publish" ]
  | ("npm" | "pnpm" | "yarn") :: sub :: _ ->
    List.mem
      sub
      [ "add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink"; "update"; "up" ]
  | cmd_name :: _ -> List.mem cmd_name [ "mv"; "cp"; "mkdir"; "touch"; "chmod" ]
  | [] -> false
;;

let rec skip_git_global_options = function
  | [] -> []
  | "--" :: rest -> rest
  | ( "-C"
    | "-c"
    | "--git-dir"
    | "--work-tree"
    | "--namespace"
    | "--super-prefix"
    | "--config-env"
    | "--exec-path" )
    :: _
    :: rest -> skip_git_global_options rest
  | opt :: rest
    when String.length opt > 1
         && opt.[0] = '-'
         && (String.starts_with ~prefix:"--git-dir=" opt
             || String.starts_with ~prefix:"--work-tree=" opt
             || String.starts_with ~prefix:"--namespace=" opt
             || String.starts_with ~prefix:"--exec-path=" opt
             || String.starts_with ~prefix:"-c" opt) -> skip_git_global_options rest
  | parts -> parts
;;

let is_git_branch_switch cmd =
  let parts =
    let buf = Buffer.create 64 in
    let tokens = ref [] in
    String.iter
      (fun c ->
         match c with
         | ' ' | '\t' ->
           if Buffer.length buf > 0
           then (
             tokens := Buffer.contents buf :: !tokens;
             Buffer.clear buf)
         | _ -> Buffer.add_char buf c)
      (String.trim cmd);
    if Buffer.length buf > 0 then tokens := Buffer.contents buf :: !tokens;
    List.rev !tokens
  in
  let is_option arg = String.length arg > 0 && arg.[0] = '-' in
  let has_any_flag flags args = List.exists (fun a -> List.mem a flags) args in
  let rec first_non_option = function
    | [] -> None
    | a :: _ when not (is_option a) -> Some a
    | _ :: rest -> first_non_option rest
  in
  match parts with
  | "git" :: rest ->
    (match skip_git_global_options rest with
     | "checkout" :: _ -> true
     | "switch" :: _ -> true
     | "branch" :: branch_args ->
       if branch_args = []
       then false
       else if has_any_flag [ "-d"; "-D"; "--delete" ] branch_args
       then false
       else if
         has_any_flag
           [ "-l"
           ; "--list"
           ; "-a"
           ; "--all"
           ; "-r"
           ; "--remotes"
           ; "--show-current"
           ; "-v"
           ; "-vv"
           ]
           branch_args
       then false
       else if has_any_flag [ "-c"; "-C"; "--copy"; "-m"; "-M"; "--move" ] branch_args
       then true
       else Option.is_some (first_non_option branch_args)
     | _ -> false)
  | _ -> false
;;

let is_destructive_bash_operation cmd =
  let parts =
    String.split_on_char ' ' (String.trim cmd) |> List.filter (fun s -> s <> "")
  in
  let is_short_option arg = String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-' in
  let has_short_flag flag arg = is_short_option arg && String.contains arg flag in
  let is_protected_branch_target arg =
    let target = String.lowercase_ascii arg in
    List.mem
      target
      [ "main"
      ; "master"
      ; "origin/main"
      ; "origin/master"
      ; "refs/heads/main"
      ; "refs/heads/master"
      ]
    || List.exists
         (fun suffix -> String.ends_with ~suffix target)
         [ ":main"
         ; ":master"
         ; ":origin/main"
         ; ":origin/master"
         ; ":refs/heads/main"
         ; ":refs/heads/master"
         ]
  in
  match parts with
  | "git" :: "push" :: rest ->
    List.exists
      (fun arg ->
         arg = "--force"
         || arg = "-f"
         || String.starts_with ~prefix:"--force-with-lease" arg)
      rest
    || List.exists is_protected_branch_target rest
  | "git" :: "reset" :: rest -> List.mem "--hard" rest
  | "rm" :: rest ->
    let option_args =
      List.filter (fun arg -> String.length arg > 0 && arg.[0] = '-') rest
    in
    let has_recursive =
      List.exists
        (fun arg ->
           arg = "--recursive" || has_short_flag 'r' arg || has_short_flag 'R' arg)
        option_args
    in
    let has_force =
      List.exists (fun arg -> arg = "--force" || has_short_flag 'f' arg) option_args
    in
    has_recursive && has_force
  | _ ->
    (match Eval_gate.detect_destructive cmd with
     | Some _ -> true
     | None -> false)
;;
