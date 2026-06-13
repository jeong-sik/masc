type stage =
  { bin : string
  ; args : string list
  }

let normalize_command_name command_name =
  let command_name = Filename.basename command_name |> String.lowercase_ascii in
  if String.ends_with ~suffix:".exe" command_name
  then String.sub command_name 0 (String.length command_name - String.length ".exe")
  else command_name

let literal_args args =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (arg, _) :: rest -> loop (arg :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var (_, _) :: _ -> None
  in
  loop [] args

let stage_of_simple simple =
  match literal_args simple.Shell_ir.args with
  | None -> None
  | Some args -> Some { bin = Exec_program.to_string simple.bin; args }

let parsed_stages ir =
  let rec loop acc = function
    | Shell_ir.Simple simple -> (
      match stage_of_simple simple with
      | Some stage -> Some (stage :: acc)
      | None -> None)
    | Shell_ir.Pipeline stages ->
      List.fold_left
        (fun acc stage -> Option.bind acc (fun acc -> loop acc stage))
        (Some acc)
        stages
  in
  match loop [] ir with
  | Some stages -> List.rev stages
  | None -> []

let is_shell_identifier name =
  let len = String.length name in
  let is_head = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let is_tail = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  len > 0
  && is_head name.[0]
  && Seq.for_all is_tail (String.to_seq (String.sub name 1 (len - 1)))

let is_env_assignment token =
  match String.index_opt token '=' with
  | None -> false
  | Some 0 -> false
  | Some i -> is_shell_identifier (String.sub token 0 i)

let env_assignment_name token =
  match String.index_opt token '=' with
  | None | Some 0 -> None
  | Some i ->
    let name = String.sub token 0 i in
    if is_shell_identifier name then Some name else None

let is_git_path_env_override = function
  | "GIT_DIR" | "GIT_WORK_TREE" | "GIT_INDEX_FILE" | "GIT_OBJECT_DIRECTORY"
  | "GIT_ALTERNATE_OBJECT_DIRECTORIES" | "GIT_COMMON_DIR" ->
    true
  | _ -> false

let rec effective_stage stage =
  match normalize_command_name stage.bin, stage.args with
  | "env", args ->
    let rec scan = function
      | [] -> None
      | ("-i" | "--ignore-environment") :: rest -> scan rest
      | arg :: rest when is_env_assignment arg ->
        (match env_assignment_name arg with
         | Some name when is_git_path_env_override name -> None
         | Some _ | None -> scan rest)
      | arg :: _rest when String.starts_with ~prefix:"-" arg -> None
      | bin :: args -> Some { bin; args }
    in
    scan args
  | "opam", "exec" :: rest ->
    (match rest with
     | "--" :: bin :: args -> Some { bin; args }
     | bin :: args when not (String.starts_with ~prefix:"-" bin) ->
       Some { bin; args }
     | _ -> None)
  (* DET-OK: parsed_stages already rejected non-literal argv fragments; this
     default preserves explicit command shape for later policy checks. *)
  | _ -> Some stage

let effective_stages ir =
  parsed_stages ir |> List.filter_map effective_stage

let command_name_of_simple simple = Exec_program.to_string simple.Shell_ir.bin

let rec first_command_name = function
  | Shell_ir.Simple simple -> Some (command_name_of_simple simple)
  | Shell_ir.Pipeline (first :: _) -> first_command_name first
  | Shell_ir.Pipeline [] -> None

let rec last_command_name = function
  | Shell_ir.Simple simple -> Some (command_name_of_simple simple)
  | Shell_ir.Pipeline stages ->
    (match List.rev stages with
     | last :: _ -> last_command_name last
     | [] -> None)

let top_level_stage_count = function
  | Shell_ir.Simple _ -> 1
  | Shell_ir.Pipeline stages -> List.length stages

let git_subcommand_with_args args =
  let rec scan = function
    | [] -> None
    | ("-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace") :: _value :: rest ->
      scan rest
    | arg :: rest
      when String.starts_with ~prefix:"-C" arg && String.length arg > 2 ->
      scan rest
    | arg :: rest
      when String.starts_with ~prefix:"--git-dir=" arg
           || String.starts_with ~prefix:"--work-tree=" arg
           || String.starts_with ~prefix:"--namespace=" arg ->
      scan rest
    | arg :: rest when String.starts_with ~prefix:"-" arg -> scan rest
    | subcommand :: rest -> Some (String.lowercase_ascii subcommand, rest)
  in
  scan args

let git_subcommand args =
  Option.map fst (git_subcommand_with_args args)

let git_subcommand_is_diagnostic = function
  | "status" | "branch" | "log" | "diff" | "remote" | "rev-parse" | "fetch"
  | "worktree" ->
    true
  | _ -> false

let is_git_diagnostic_command ir =
  match effective_stages ir with
  | [ stage ] when String.equal (normalize_command_name stage.bin) "git" -> (
    match git_subcommand stage.args with
    | Some subcommand -> git_subcommand_is_diagnostic subcommand
    | None -> false)
  | _ -> false

let simple_relative_git_pathspec path =
  let path = String.trim path in
  path <> ""
  && path <> ".."
  && Filename.is_relative path
  && not (String.starts_with ~prefix:"-" path)
  && not (String.starts_with ~prefix:":" path)
  && not (String.contains path '\x00')
  && not
       (path
        |> String.split_on_char '/'
        |> List.exists (fun segment -> String.equal segment ".."))

let drop_git_quiet_flags args =
  let rec loop = function
    | ("-q" | "--quiet") :: rest -> loop rest
    | rest -> rest
  in
  loop args

let git_checkout_head_restore_args args =
  match drop_git_quiet_flags args with
  | ("HEAD" | "@") :: "--" :: paths ->
    paths <> [] && List.for_all simple_relative_git_pathspec paths
  | _ -> false

let git_checkout_main_recovery_args args =
  match drop_git_quiet_flags args with
  | [ "main" ] -> true
  | _ -> false

let git_switch_main_recovery_args args =
  match drop_git_quiet_flags args with
  | [ "main" ] -> true
  | _ -> false

let git_reset_hard_head_args args =
  let rec loop ~hard ~target = function
    | [] -> hard && (match target with Some "HEAD" | Some "@" -> true | None | Some _ -> false)
    | ("-q" | "--quiet") :: rest -> loop ~hard ~target rest
    | "--hard" :: rest -> loop ~hard:true ~target rest
    | "--" :: _ -> false
    | arg :: _ when String.starts_with ~prefix:"-" arg -> false
    | arg :: rest -> (
      match target with
      | None -> loop ~hard ~target:(Some arg) rest
      | Some _ -> false)
  in
  loop ~hard:false ~target:None args

let git_clean_short_flags_allowed arg =
  let len = String.length arg in
  len > 1
  &&
  let rec loop i =
    if i >= len then true
    else
      match arg.[i] with
      | 'f' | 'd' | 'q' -> loop (i + 1)
      | _ -> false
  in
  loop 1

let git_clean_short_flag_counts arg =
  let len = String.length arg in
  if len <= 1
  then None
  else
    let rec loop i force_count dir =
      if i >= len
      then Some (force_count, dir)
      else
        match arg.[i] with
        | 'f' -> loop (i + 1) (force_count + 1) dir
        | 'd' -> loop (i + 1) force_count true
        | 'q' -> loop (i + 1) force_count dir
        | _ -> None
    in
    loop 1 0 false

let git_clean_recovery_args args =
  let rec loop ~force_count ~dir = function
    | [] -> force_count = 1 && dir
    | "--" :: [] -> force_count = 1 && dir
    | "--force" :: rest -> loop ~force_count:(force_count + 1) ~dir rest
    | "--dir" :: rest -> loop ~force_count ~dir:true rest
    | "--quiet" :: rest -> loop ~force_count ~dir rest
    | arg :: rest
      when String.starts_with ~prefix:"-" arg && git_clean_short_flags_allowed arg ->
      (match git_clean_short_flag_counts arg with
       | Some (force_delta, short_dir) ->
         loop ~force_count:(force_count + force_delta) ~dir:(dir || short_dir) rest
       | None -> false)
    | _ -> false
  in
  loop ~force_count:0 ~dir:false args

let git_args_has_path_changing_option args =
  let rec scan = function
    | [] -> false
    | ("-C" | "--git-dir" | "--work-tree") :: _ :: _rest -> true
    | arg :: _rest
      when String.starts_with ~prefix:"-C" arg && String.length arg > 2 ->
      true
    | arg :: _rest
      when String.starts_with ~prefix:"--git-dir=" arg
           || String.starts_with ~prefix:"--work-tree=" arg ->
      true
    | _ :: rest -> scan rest
  in
  scan args
;;

let is_git_recovery_command ir =
  match effective_stages ir with
  | [ stage ] when String.equal (normalize_command_name stage.bin) "git" -> (
    if git_args_has_path_changing_option stage.args
    then false
    else
      match git_subcommand_with_args stage.args with
      | Some ("checkout", args) ->
        git_checkout_head_restore_args args || git_checkout_main_recovery_args args
      | Some ("switch", args) -> git_switch_main_recovery_args args
      | Some ("reset", args) -> git_reset_hard_head_args args
      | Some ("clean", args) -> git_clean_recovery_args args
      | _ -> false)
  | _ -> false
