(** Mutation/destructive command classifiers — IR-typed.

    RFC-0160 S4: [_of_string] wrappers removed. All callers must
    pass [Shell_ir.t] directly. *)

open Masc_exec

(* ---- Stage-word extraction from Shell IR ---------------------- *)

(** Extract literal words from a single [Shell_ir.simple] stage:
    [[bin; arg0; arg1; ...]]. Non-literal args ([Concat], [Var])
    abort the extraction by returning [None] — these were valid IR
    parses but cannot be matched against the closed sub-command set,
    so they fall through to a [false] classification (mirroring the
    string-era behavior where [Bash_words.stages] also returned [Ok]
    for them but the [List.mem] checks could not match a [$VAR]). *)
let literal_words_of_simple (simple : Shell_ir.simple) : string list option =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (a, _) :: rest -> collect (a :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var _ :: _ -> None
  in
  match collect [] simple.args with
  | None -> None
  | Some args -> Some (Bin.to_string simple.bin :: args)
;;

(** Flatten all literal stage words into one list (matches the
    historical [shell_word_values cmd] return shape: stages
    concatenated). Non-literal-only stages contribute their literal
    prefix only. *)
let flat_stage_words (ir : Shell_ir.t) : string list =
  let rec collect acc = function
    | Shell_ir.Simple s ->
      (match literal_words_of_simple s with
       | Some ws -> ws :: acc
       | None -> acc)
    | Shell_ir.Pipeline stages ->
      List.fold_left collect acc stages
  in
  List.rev (collect [] ir) |> List.concat
;;

(* ---- IR-typed classifiers ------------------------------------- *)

let is_write_operation (ir : Shell_ir.t) : bool =
  match flat_stage_words ir with
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

let is_git_branch_switch (ir : Shell_ir.t) : bool =
  let parts = flat_stage_words ir in
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

let is_destructive_bash_operation (ir : Shell_ir.t) : bool =
  let parts = flat_stage_words ir in
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
  | _ -> false
(* RFC-0160 S1: removed [Eval_gate.detect_destructive cmd] fallback.

   Reason: typed argv (the input shape after [to_shell_ir]) cannot
   carry raw-shell evasion patterns ([\xNN] expansion, variable
   substitution, sub-shell). Each argv token is a literal by
   construction. The string-fallback covered evasion in the era when
   callers passed raw shell strings; with IR input it is dead.

   Callers that still receive raw strings (e.g. worker_oas.ml:389,
   keeper_shell_bash.ml entry) should run [Eval_gate.detect_destructive]
   on the {i raw} string {i before} lowering, separately from this
   structural classifier. *)
;;

(** Shared shell-word extractor (single source of truth for what
    used to be duplicated [shell_word_values] copies). Returns
    the flattened literal stage words across all pipeline segments
    ([[]] on parse failure or non-literal-only stages).

    Callers that already have [Shell_ir.t] should use
    {!flat_stage_words} directly. *)
let stage_words_of_string (cmd : string) : string list =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Parsed.Parsed ir -> flat_stage_words ir
  | _ -> []
;;

(** RFC-0160 S6b: Result-shaped variant that preserves the parse-failure
    signal. [stage_words_of_string] collapses failure to [[]] which suits
    classifiers (fail-closed = false). [_result] keeps [Error ()] so
    callers that route on failure (e.g. log sanitizer's sensitive-marker
    fallback) can branch.

    Single IR producer ([Bash.parse_string]) for both shapes — replaces
    the legacy [Bash_words.stages]-based [shell_word_values] copy in
    [exec_policy_log_sanitize]. *)
let stage_words_of_string_result (cmd : string) : (string list, unit) result =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Parsed.Parsed ir -> Ok (flat_stage_words ir)
  | _ -> Error ()
;;

(** Parse a string as a single simple command and extract its argv words.
    Returns [None] for pipelines, parse errors, or non-literal args.
    Replaces the duplicate parse in [Exec_policy_command_syntax.argv_words_of_split_string]. *)
let argv_words_of_string text =
  match Masc_exec_bash_parser.Bash.parse_string text with
  | Parsed.Parsed (Shell_ir.Simple simple) -> literal_words_of_simple simple
  | _ -> None
;;

(** Expose the raw [Bash.parse_string] result so that callers needing
    [Shell_ir.t Parsed.t] (e.g. gh command validation) don't need to
    import [Masc_exec_bash_parser] directly. *)
let parsed_of_string text =
  Masc_exec_bash_parser.Bash.parse_string text
;;
