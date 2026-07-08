(** Shell_ir_risk — phantom-typed risk envelope for Shell IR.

    RFC-0160 S3: every Shell_ir.t that reaches dispatch carries a
    risk_class computed once at the classification boundary. Producers
    create [Shell_ir.t] unchanged; consumers wrap via [undecided],
    classify, then dispatch via [Exec_dispatch.dispatch_decided].

    Phantom types ([undecided] / [decided]) enforce at compile time
    that no IR reaches [dispatch_decided] without classification.
    Zero runtime overhead: the phantom parameter is erased. *)

type undecided
type decided

type risk_class =
  | R0_Read
  | R1_Reversible_mutation
  | R2_Irreversible
  | Destructive_protected

let string_of_risk_class = function
  | R0_Read -> "R0"
  | R1_Reversible_mutation -> "R1"
  | R2_Irreversible -> "R2"
  | Destructive_protected -> "Destructive_protected"
;;

let pp_risk_class fmt rc = Format.pp_print_string fmt (string_of_risk_class rc)

type _ t = T of Shell_ir.t

let undecided (ir : Shell_ir.t) : undecided t = T ir

let unwrap : type phase. phase t -> Shell_ir.t = fun (T ir) -> ir

type 'phase decided_ir = { ir : Shell_ir.t; risk : risk_class }

let risk_class (envelope : decided decided_ir) = envelope.risk
let is_r0 e = e.risk = R0_Read
let is_r1 e = e.risk = R1_Reversible_mutation
let is_r2 e = e.risk = R2_Irreversible
let is_destructive e = e.risk = Destructive_protected

(* --- Write sub-classification --------------------------------------- *)

let is_short_option arg = String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-'
let has_short_flag flag arg = is_short_option arg && String.contains arg flag

let is_eq_flag flag arg =
  String.equal arg flag || String.starts_with ~prefix:(flag ^ "=") arg
;;

let git_branch_has_flag flags args =
  List.exists
    (fun arg ->
       List.exists
         (fun flag ->
            if String.length flag = 2 && flag.[0] = '-'
            then has_short_flag flag.[1] arg
            else is_eq_flag flag arg)
         flags)
    args
;;

let git_branch_args_are_read_only args =
  let mutating_flags =
    [ "-d"; "-D"; "--delete"; "-m"; "-M"; "--move"; "-c"; "-C"; "--copy"
    ; "-f"; "--force"; "-u"; "--set-upstream-to"; "--unset-upstream"
    ; "--track"; "--no-track"; "--edit-description"; "--create-reflog"
    ]
  in
  let read_flags =
    [ "-l"; "--list"; "-a"; "--all"; "-r"; "--remotes"; "--show-current"
    ; "-v"; "--contains"; "--no-contains"; "--merged"; "--no-merged"
    ; "--points-at"; "--format"; "--sort"; "--color"; "--no-color"; "--column"
    ; "--no-column"; "--ignore-case"; "--abbrev"; "--no-abbrev"
    ]
  in
  match args with
  | [] -> true
  | _ when git_branch_has_flag mutating_flags args -> false
  | _ -> git_branch_has_flag read_flags args
;;

let is_env_assignment arg =
  match String.index_opt arg '=' with
  | None -> false
  | Some 0 -> false
  | Some i ->
    let name = String.sub arg 0 i in
    String.for_all
      (function
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
        | _ -> false)
      name
;;

let rec strip_env_prefix words =
  let rec strip_env_args = function
    | [] -> []
    | "--" :: rest -> rest
    | ("-i" | "--ignore-environment" | "--null" | "-0") :: rest ->
      strip_env_args rest
    | ("-u" | "--unset") :: _ :: rest -> strip_env_args rest
    | arg :: rest
      when String.starts_with ~prefix:"--unset=" arg
           || String.starts_with ~prefix:"-u" arg
           || is_env_assignment arg ->
      strip_env_args rest
    (* env -S/--split-string splits a string into arguments and executes
       the resulting command — arbitrary command execution. Cannot safely
       extract and classify the embedded command string at the word level.
       Return a sentinel that triggers Destructive_protected escalation
       via shell_interpreter_names. *)
    | ("-S" | "--split-string") :: _ -> ["bash"]
    | arg :: _
      when String.starts_with ~prefix:"--split-string=" arg
           || (String.length arg > 2 && String.starts_with ~prefix:"-S" arg) ->
      ["bash"]
    | rest -> rest
  in
  match words with
  | "env" :: rest -> strip_env_prefix (strip_env_args rest)
  | _ -> words
;;

let rec skip_git_global_options = function
  | [] -> []
  | "--" :: rest -> rest
  | ("-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" | "--super-prefix"
    | "--config-env" | "--exec-path") :: _ :: rest ->
    skip_git_global_options rest
  | ("--bare" | "--no-pager" | "--paginate" | "--no-replace-objects"
    | "--literal-pathspecs" | "--glob-pathspecs" | "--noglob-pathspecs"
    | "--icase-pathspecs" | "--no-optional-locks" | "--version" | "-v") :: rest ->
    skip_git_global_options rest
  | opt :: rest
    when String.length opt > 1
         && opt.[0] = '-'
         && (String.starts_with ~prefix:"--git-dir=" opt
             || String.starts_with ~prefix:"--work-tree=" opt
             || String.starts_with ~prefix:"--namespace=" opt
             || String.starts_with ~prefix:"--exec-path=" opt
             || String.starts_with ~prefix:"--config-env=" opt
             || String.starts_with ~prefix:"-c" opt) ->
    skip_git_global_options rest
  | parts -> parts
;;

let rec skip_gh_global_options = function
  | [] -> []
  | ("--repo" | "-R" | "--hostname" | "--config" | "--git-protocol") :: _ :: rest ->
    skip_gh_global_options rest
  | ("--help" | "-h" | "--version" | "--debug" | "--verbose" | "--no-color"
    | "--paginate") :: rest ->
    skip_gh_global_options rest
  | opt :: rest
    when String.length opt > 1
         && opt.[0] = '-'
         && (String.starts_with ~prefix:"--repo=" opt
             || String.starts_with ~prefix:"-R=" opt
             || String.starts_with ~prefix:"--hostname=" opt
             || String.starts_with ~prefix:"--config=" opt
             || String.starts_with ~prefix:"--git-protocol=" opt) ->
    skip_gh_global_options rest
  | parts -> parts
;;

let shell_arg_literal = function
  | Shell_ir.Lit (s, _) -> Some s
  | Shell_ir.Var _ | Shell_ir.Concat _ -> None
;;

let gh_global_value_option = function
  | "--repo" | "-R" | "--hostname" | "--config" | "--git-protocol" -> true
  | _ -> false
;;

let gh_global_bool_option = function
  | "--help" | "-h" | "--version" | "--debug" | "--verbose" | "--no-color"
  | "--paginate" ->
    true
  | _ -> false
;;

let gh_global_eq_value_option opt =
  String.length opt > 1
  && opt.[0] = '-'
  && (String.starts_with ~prefix:"--repo=" opt
      || String.starts_with ~prefix:"-R=" opt
      || String.starts_with ~prefix:"--hostname=" opt
      || String.starts_with ~prefix:"--config=" opt
      || String.starts_with ~prefix:"--git-protocol=" opt)
;;

let gh_floor_words_of_simple (simple : Shell_ir.simple) =
  match Exec_program.known simple.bin with
  | Some Exec_program.Gh ->
    let rec collect acc = function
      | [] -> Some (Exec_program.to_string simple.bin :: List.rev acc)
      | arg :: rest ->
        (match shell_arg_literal arg with
         | Some opt when gh_global_value_option opt ->
           let rest =
             match rest with
             | [] -> []
             | _value :: rest -> rest
           in
           collect acc rest
         | Some opt when gh_global_bool_option opt || gh_global_eq_value_option opt ->
           collect acc rest
         | Some word -> collect (word :: acc) rest
         | None -> collect ("" :: acc) rest)
    in
    collect [] simple.args
  | Some
      ( Exec_program.Ls | Exec_program.Cat | Exec_program.Pwd | Exec_program.Echo
      | Exec_program.Head | Exec_program.Tail | Exec_program.Rg | Exec_program.Grep
      | Exec_program.Find | Exec_program.Which | Exec_program.Test
      | Exec_program.Basename | Exec_program.Dirname | Exec_program.Stat
      | Exec_program.Du | Exec_program.Df | Exec_program.Sort | Exec_program.Uniq
      | Exec_program.Wc | Exec_program.Cut | Exec_program.Tr | Exec_program.File
      | Exec_program.Printf | Exec_program.Date | Exec_program.Env
      | Exec_program.Printenv | Exec_program.Hostname | Exec_program.Whoami
      | Exec_program.Uname | Exec_program.Ps | Exec_program.Tty | Exec_program.Cp
      | Exec_program.Mv | Exec_program.Ln | Exec_program.Touch | Exec_program.Tee
      | Exec_program.Awk | Exec_program.Xargs | Exec_program.Git
      | Exec_program.Docker | Exec_program.Curl | Exec_program.Wget | Exec_program.Ssh
      | Exec_program.Scp | Exec_program.Tar | Exec_program.Rsync | Exec_program.Make
      | Exec_program.Cmake | Exec_program.Dune_local_sh | Exec_program.Diff
      | Exec_program.Patch | Exec_program.Mkdir | Exec_program.Npm | Exec_program.Node
      | Exec_program.Npx | Exec_program.Yarn | Exec_program.Pnpm | Exec_program.Pip
      | Exec_program.Python | Exec_program.Python3 | Exec_program.Pytest
      | Exec_program.Pyright | Exec_program.Ruff | Exec_program.Opam
      | Exec_program.Ocamlfind | Exec_program.Tsc | Exec_program.Cargo
      | Exec_program.Rustc | Exec_program.Go | Exec_program.Gofmt | Exec_program.Gradle
      | Exec_program.Java | Exec_program.Javac | Exec_program.Mvn | Exec_program.Ninja
      | Exec_program.Sed | Exec_program.Uv | Exec_program.Glab
      | Exec_program.Terminal_notifier | Exec_program.Osascript | Exec_program.Play
      | Exec_program.Rec | Exec_program.Ffplay | Exec_program.Mpg123 | Exec_program.Open
      | Exec_program.Psql | Exec_program.Mysql | Exec_program.Mariadb
      | Exec_program.Cockroach | Exec_program.Sudo | Exec_program.Su
      | Exec_program.Chmod | Exec_program.Chown | Exec_program.Rm | Exec_program.Dd
      | Exec_program.Mkfs | Exec_program.Shutdown | Exec_program.Reboot
      | Exec_program.Halt | Exec_program.Poweroff ) ->
    None
  | None -> None
;;

let normalize_command_words words =
  match strip_env_prefix words with
  | "git" :: rest -> "git" :: skip_git_global_options rest
  | "gh" :: rest -> "gh" :: skip_gh_global_options rest
  | words -> words
;;

let normalized_head_name = function
  | [] -> None
  | raw :: _ ->
    Some (raw |> Filename.basename |> String.lowercase_ascii)
;;

let head_name_in names words =
  match normalized_head_name words with
  | Some name -> List.mem name names
  | None -> false
;;

let shell_interpreter_names =
  [ "sh"; "bash"; "zsh"; "fish"; "ksh"; "dash"; "csh"; "tcsh"; "ash" ]
;;

let network_primitive_names =
  [ "curl"; "wget"; "ssh"; "scp"; "rsync"; "ftp"; "sftp"; "nc" ]
;;

let shell_capable_executable_names =
  [ "node"; "npx"; "pip"; "python"; "python3" ]
;;

(* STR-OK: Shell argv boundary parser; git option strings are normalized here
   before risk is converted into the typed [risk_class] envelope. *)
let git_config_arg_is_read_flag = function
  | "--get" | "--get-all" | "--get-regexp" | "--list" | "-l" | "--show-origin"
  | "--show-scope" | "--name-only" | "--null" | "-z" ->
    true
  | _ -> false
;;

let git_config_arg_is_write_flag = function
  | "--add" | "--replace-all" | "--unset" | "--unset-all" | "--remove-section"
  | "--rename-section" | "--edit" | "-e" ->
    true
  | _ -> false
;;

let git_config_args_are_read_only args =
  match args with
  | [] -> false
  | _ ->
    List.exists git_config_arg_is_read_flag args
    && not (List.exists git_config_arg_is_write_flag args)
;;

let git_remote_args_are_read_only = function
  | [] -> true
  | ("-v" | "--verbose") :: _ -> true
  | ("show" | "get-url") :: _ -> true
  | _ -> false
;;

let git_tag_args_are_read_only = function
  | [] -> true
  | args ->
    let is_read_flag = function
      | "-l" | "--list" | "-n" | "--points-at" -> true
      | _ -> false
    in
    let is_write_flag = function
      | "-a" | "--annotate" | "-s" | "--sign" | "-d" | "--delete" | "-f" ->
        true
      | _ -> false
    in
    List.exists is_read_flag args && not (List.exists is_write_flag args)
;;

let git_clean_args_are_dry_run args =
  let is_dry_run_flag = function
    | "-n" | "--dry-run" -> true
    | _ -> false
  in
  List.exists is_dry_run_flag args
;;

let classify_write_detail (words : string list) : risk_class option =
  match words with
  | "git" :: sub :: rest ->
    (match sub with
     | "push" | "merge" | "rebase" | "commit" | "add" | "apply" | "am"
     | "cherry-pick" | "revert" | "switch" | "restore" | "pull" | "fetch"
     | "worktree" | "submodule" | "config" | "remote" ->
       Some R1_Reversible_mutation
     | "reset" -> Some R2_Irreversible
     | "clean" ->
       if git_clean_args_are_dry_run rest then None else Some R2_Irreversible
     | "branch" ->
       if git_branch_args_are_read_only rest
       then None
       else Some R1_Reversible_mutation
     | "checkout" | "tag" | "stash" | "clone" | "init" ->
       Some R1_Reversible_mutation
     | _ -> None)
  | ("npm" | "pnpm" | "yarn") :: _ -> Some R1_Reversible_mutation
  | "dune" :: _ -> Some R1_Reversible_mutation
  | "make" :: _ -> Some R1_Reversible_mutation
  | ("mv" | "cp" | "mkdir" | "touch" | "chmod" | "chown" | "chgrp"
    | "truncate" | "mktemp" | "tee") :: _ ->
    Some R1_Reversible_mutation
  | ("rm" | "rmdir" | "ln" | "unlink" | "install" | "dd" | "shred") :: _ ->
    Some R2_Irreversible
  | _ -> None

(* --- Repo-hosting CLI classification on IR words -------------------- *)

let repo_hosting_cli_irreversible_ops =
  [
    (* RFC-0309 W4/G-9 + follow-up: [pr] has NO irreversible action. [ready] is
       reversible ([--undo]); [merge] is reversible too — [git revert] restores
       the base-branch tree, exactly as a created repo can be deleted. What made
       [merge] feel R2 ("it writes the base branch / triggers deploys") is a
       durable-remote externality — a CAPABILITY concern, not a reversibility
       fact. So [merge] moves to the reversible table and the "keeper may not
       merge unsupervised" decision lives on the capability axis
       ([Gh_capability_policy.creates_durable_remote_surface] -> Requires_approval,
       i.e. non-blocking human approval), mirroring [gh repo create]. Same
       policy-as-risk correction W4/G-9 applied to repo create/fork/discussion.
       Operator decision 2026-07-08: gh pr merge -> Ask, not Deny. *)
    (* RFC-0309 W4/G-9: repo create/fork are factually REVERSIBLE (a created or
       forked repo can be deleted), so they move to the reversible table below.
       Only the genuinely irreversible repo ops stay here. This restores the
       risk axis to state a fact; the "keeper may not create repos
       unsupervised" decision now lives on the capability axis
       ([Gh_capability_policy]) as [Requires_approval], superseding #23362's
       policy-as-risk encoding. *)
    ("repo", [ "delete"; "archive"; "transfer"; "rename" ]);
    (* Only [delete] is irreversible; create/comment/edit/close/reopen/lock/
       unlock/answer/unanswer are reversible discussion mutations (W4/G-9). *)
    ("discussion", [ "delete" ]);
    ("release", [ "delete" ]);
    ("secret", [ "delete"; "remove" ]);
    ("ssh-key", [ "delete" ]);
    ("workflow", [ "disable" ]);
    ("auth", [ "logout"; "token" ]);
    ("gist", [ "delete" ]);
    ("ruleset", [ "delete" ]);
  ]
;;

let repo_hosting_cli_reversible_mutations =
  [
    ("pr",
     [ "create"; "close"; "reopen"; "edit"; "comment"; "review"; "lock"; "checkout";
       "unlock"; "ready"; "merge" ]);
    ("issue",
     [ "create"; "close"; "reopen"; "edit"; "comment"; "lock"; "unlock";
       "develop"; "pin"; "unpin" ]);
    ("label", [ "create"; "edit"; "delete"; "clone" ]);
    ("release", [ "create"; "edit"; "upload"; "download" ]);
    ("run", [ "cancel"; "rerun"; "watch" ]);
    ("cache", [ "delete" ]);
    ("gist", [ "create"; "edit"; "clone"; "rename" ]);
    (* RFC-0309 W4/G-9: create/fork are reversible remote mutations. The
       capability axis ([Gh_capability_policy]) routes create/fork/edit/sync to
       [Requires_approval] because they touch a durable remote surface; the
       risk axis only states they are reversible (R1). *)
    ("repo",
     [ "clone"; "create"; "fork"; "edit"; "sync"; "set-default" ]);
    (* RFC-0309 W4/G-9: reversible discussion mutations (delete stays R2 in the
       irreversible table). The capability axis routes these to
       [Requires_approval] via the Discussion durable-remote family. *)
    ("discussion",
     [ "create"; "comment"; "edit"; "close"; "reopen"; "lock"; "unlock";
       "answer"; "unanswer" ]);
    ("project",
     [ "create"; "edit"; "close"; "copy"; "link"; "unlink"; "field-create";
       "field-delete"; "item-add"; "item-archive"; "item-delete"; "item-edit" ]);
    ("workflow", [ "enable"; "run" ]);
    ("ruleset", [ "create"; "edit" ]);
  ]
;;

let in_table table command sub =
  List.exists
    (fun (c, subs) -> c = command && List.mem sub subs)
    table

let has_mutating_method parts =
  List.exists
    (fun tok ->
       let lower = String.lowercase_ascii tok in
       String.starts_with ~prefix:"-f" lower
       || String.starts_with ~prefix:"-f=" lower
       || String.starts_with ~prefix:"--field" lower
       || String.starts_with ~prefix:"--raw-field" lower)
    parts

let extract_method_from_parts parts =
  let rec find = function
    | [] -> None
    | "-X" :: m :: _ | "--method" :: m :: _ -> Some (String.uppercase_ascii m)
    | tok :: _rest
      when String.length tok > 3
           && String.starts_with ~prefix:"-X=" tok ->
      Some
        (String.uppercase_ascii (String.sub tok 3 (String.length tok - 3)))
    | tok :: _rest
      when String.length tok > 9
           && String.starts_with ~prefix:"--method=" tok ->
      Some
        (String.uppercase_ascii (String.sub tok 9 (String.length tok - 9)))
    (* The repo-hosting CLI accepts `-X<METHOD>` as a single token. Stress test
       2026-05-26: `gh api -XDELETE /repos/o/r` fell through to GET -> R0
       even though Execute, Shell IR, and worker-dev dispatch paths depend on
       this for the live gate. *)
    | tok :: _rest
      when String.length tok > 2
           && String.starts_with ~prefix:"-X" tok
           && tok.[2] <> '=' ->
      Some
        (String.uppercase_ascii (String.sub tok 2 (String.length tok - 2)))
    | _ :: rest -> find rest
  in
  find parts

(* GraphQL mutation fragments that mark a query body as R2 irreversible.
   Conservative deny-list. Keep this in Shell IR risk so Execute has one
   parser-owned source for command risk instead of a product-level GH family. *)
let repo_hosting_graphql_r2_fragments =
  [ "deletepullrequest"; "deleteissue"; "deletebranch"; "deleteref";
    "deleteproject"; "deletebranchprotectionrule";
    "removeouterfromorganization"; "transferrepository";
    "archiverepository";
    (* RFC-0309 W4/G-9: only irreversible discussion graphql mutations stay R2.
       createDiscussion/addDiscussionComment/closeDiscussion/updateDiscussion/
       etc. are reversible and are gated by the capability axis, not the risk
       floor (they were added to R2 by #23362's policy-as-risk encoding).
       createRepository/cloneTemplateRepository are likewise reversible. *)
    "deletediscussion"; "deletediscussioncomment";
    (* Forward-looking verb prefixes for mutations GitHub may introduce.
       Over-block here is acceptable — under-block (silent miss) is not. *)
    "purgerepository" ]

let strip_graphql_comments s =
  let buf = Buffer.create (String.length s) in
  let in_comment = ref false in
  String.iter
    (fun c ->
       if !in_comment then
         (if c = '\n' then begin in_comment := false; Buffer.add_char buf c end)
       else if c = '#' then in_comment := true
       else Buffer.add_char buf c)
    s;
  Buffer.contents buf

let graphql_body_lower words =
  String.concat " " words |> String.lowercase_ascii |> strip_graphql_comments

(* Substring-scan the (comment-stripped, lowercased) graphql body for any of
   [fragments]. Shared by the R2 deny-list and the durable-remote capability
   list so both use one parser-owned body reader. *)
let body_contains_fragment (fragments : string list) (words : string list) : bool
  =
  let body = graphql_body_lower words in
  let m = String.length body in
  List.exists
    (fun frag ->
       let n = String.length frag in
       if n = 0 || n > m then false
       else
         let rec scan i =
           if i + n > m then false
           else if String.sub body i n = frag then true
           else scan (i + 1)
         in
         scan 0)
    fragments

let body_contains_r2_mutation words =
  body_contains_fragment repo_hosting_graphql_r2_fragments words

(* GraphQL mutation fragments that establish or modify a durable REMOTE
   repository/discussion surface and are reversible (R1). W4/G-9 moved these out
   of [repo_hosting_graphql_r2_fragments] (they are reversible, so the risk floor
   no longer denies them). The capability axis escalates them to Ask, mirroring
   the typed [gh repo create] / [gh discussion create] path — without this the
   string-borne graphql form would auto-run under the autonomous overlay while
   the typed form asks (an axis-asymmetry bypass). Irreversible graphql mutations
   (delete*/transfer/archive/purge) stay in [repo_hosting_graphql_r2_fragments]
   and are denied by the floor, so they are deliberately absent here.
   Over-inclusion only adds an approval prompt (safe); under-inclusion silently
   auto-runs a durable-remote write (unsafe). *)
let repo_hosting_graphql_durable_remote_fragments =
  [ "createrepository"; "clonetemplaterepository"; "updaterepository";
    "creatediscussion"; "updatediscussion"; "adddiscussioncomment";
    "updatediscussioncomment"; "adddiscussionpollvote"; "closediscussion";
    "reopendiscussion"; "markdiscussioncommentasanswer";
    "unmarkdiscussioncommentasanswer" ]

let gh_api_graphql_creates_durable_remote (words : string list) : bool =
  (* Guard on the [graphql] endpoint token: a REST [gh api /path] call whose
     path merely contains a mutation name must not be over-flagged. *)
  List.mem "graphql" (List.map String.lowercase_ascii words)
  && body_contains_fragment repo_hosting_graphql_durable_remote_fragments words

let classify_repo_hosting_cli (words : string list) : risk_class =
  match words with
  | [] | [ _ ] -> R0_Read
  | _ :: command_raw :: rest ->
    let command = String.lowercase_ascii command_raw in
    (* Boolean-default sub extraction: any [-foo] is treated as a
       boolean flag (does NOT consume the next token). Previously
       `-q delete some-wf` had -q swallow "delete" and let the
       block-list miss. Stress test 2026-05-26: flag-bool-prefix-bypass.
       Trade-off: a real value-taking flag positioned before the subcmd
       may surface its value as sub. We accept over-block; silent
       bypass is unacceptable. *)
    let sub =
      let is_flag tok = String.length tok > 0 && tok.[0] = '-' in
      let rec first_non_flag = function
        | [] -> ""
        | tok :: tl ->
          if is_flag tok then first_non_flag tl
          else String.lowercase_ascii tok
      in
      first_non_flag rest
    in
    (* Path-unification: scan ALL positional tokens (not just sub) for
       any dangerous keyword belonging to this top-level command. A
       value token like `.` from `repo --jq . delete o/r` would be
       picked as sub but the real dangerous keyword is `delete` later
       in the list. *)
    let dangerous_subs_for_cmd =
      List.fold_left
        (fun acc (c, subs) -> if c = command then acc @ subs else acc)
        [] repo_hosting_cli_irreversible_ops
    in
    let positional_dangerous_hit =
      let is_flag tok = String.length tok > 0 && tok.[0] = '-' in
      List.exists
        (fun t ->
           not (is_flag t)
           && List.mem (String.lowercase_ascii t) dangerous_subs_for_cmd)
        rest
    in
    if in_table repo_hosting_cli_irreversible_ops command sub
       || positional_dangerous_hit
    then R2_Irreversible
    else if command = "api" then
      let method_ =
        match extract_method_from_parts words with
        | Some m -> m
        | None -> "GET"
      in
      if method_ = "DELETE" then R2_Irreversible
      else if sub = "graphql" then begin
        (* graphql endpoint always POSTs. Look inside the query body
           for known destructive mutation fragments; default to R1
           when none match (mutation is still a write). Stress test
           2026-05-26: deletePullRequest/purgeRepository previously
           returned R1 — silent miss. *)
        if body_contains_r2_mutation words then R2_Irreversible
        else R1_Reversible_mutation
      end
      else if List.mem method_ [ "POST"; "PUT"; "PATCH" ] then R1_Reversible_mutation
      else if has_mutating_method words then R1_Reversible_mutation
      else R0_Read
    else if in_table repo_hosting_cli_reversible_mutations command sub then R1_Reversible_mutation
    else R0_Read

(* Subcommand-table risk for a known gh family. Shared by [risk_of_gh_verb]
   (typed opinion) and [repo_hosting_cli_floor_risk] (enforcement floor) so the
   subcommand tables are the single risk source. A table-absent action is a
   read (R0): most such actions in a known family are reads (view/list/status)
   and we cannot distinguish them from a genuinely unknown action without a
   reads table. *)
let table_risk_of_gh_family (command : string) (action : string) : risk_class =
  if in_table repo_hosting_cli_irreversible_ops command action then R2_Irreversible
  else if in_table repo_hosting_cli_reversible_mutations command action then
    R1_Reversible_mutation
  else R0_Read

(* Well-known gh read actions shared across families ([gh pr view], [gh repo
   list], [gh run view], [gh pr diff], [gh pr checks], ...). Kept deliberately
   TIGHT: an action wrongly omitted here is only over-gated to non-blocking
   approval (safe), whereas an action wrongly included would let an unrecognized
   mutation auto-run as a read. *)
let gh_read_actions =
  [ "view"; "list"; "status"; "diff"; "checks"; "browse"; "download" ]
;;

let gh_action_is_known_read (action : string) : bool =
  List.mem (String.lowercase_ascii action) gh_read_actions
;;

(* Typed classification of a gh verb, shared by [risk_of_gh_verb] (risk axis)
   and [Gh_capability_policy.disposition_of] (capability axis) so both read one
   source. This closes the known-family-unknown-action gap: an action on a
   mutating-capable family that is neither a table mutation nor a known read is
   [Gh_unrecognized_action] — the risk axis keeps it R0 (its reversibility is
   genuinely unknown; fabricating R1/R2 would be the #23362 policy-as-risk
   mistake), while the capability axis routes it to non-blocking approval rather
   than auto-running it as a read. *)
type gh_verb_class =
  | Gh_read (* known read action, or a bare family invocation *)
  | Gh_reversible_mutation (* action in the reversible table *)
  | Gh_irreversible_mutation (* action in the irreversible table *)
  | Gh_unrecognized_action
      (* known mutating-capable family, action neither a mutation nor a read *)
  | Gh_string_borne (* [gh api]: risk is the -X method / graphql body (floor) *)
  | Gh_unrecognized_family (* [Gh_verb.Other] *)

let classify_gh_verb (v : Gh_verb.t) : gh_verb_class =
  match v.Gh_verb.family with
  | Gh_verb.Api -> Gh_string_borne
  | Gh_verb.Other _ -> Gh_unrecognized_family
  | ( Gh_verb.Pr | Gh_verb.Issue | Gh_verb.Repo | Gh_verb.Discussion
    | Gh_verb.Release | Gh_verb.Secret | Gh_verb.Ssh_key | Gh_verb.Workflow
    | Gh_verb.Auth | Gh_verb.Gist | Gh_verb.Ruleset | Gh_verb.Label
    | Gh_verb.Run | Gh_verb.Cache | Gh_verb.Project ) as fam ->
    (match v.Gh_verb.action with
     | None -> Gh_read (* bare family: a read *)
     | Some action ->
       let command = Gh_verb.family_token fam in
       if in_table repo_hosting_cli_irreversible_ops command action then
         Gh_irreversible_mutation
       else if in_table repo_hosting_cli_reversible_mutations command action then
         Gh_reversible_mutation
       else if gh_action_is_known_read action then Gh_read
       else Gh_unrecognized_action)

(* RFC-0309 §3.1 (W1): the typed-family risk opinion for a gh command.

   [risk_of_gh_verb] is the closed-sum lens over [classify_repo_hosting_cli]:
   it reads the SAME subcommand tables (the risk SSOT) for known families, so
   its opinion equals the word-list floor for every recognized [family/action]
   pair. It differs in exactly one place — a wholly-unrecognized top-level gh
   area ([Gh_verb.Other]) opines [R2_Irreversible] (fail-closed) instead of the
   floor's [R0_Read] fall-through. That is the whole delta this function adds:
   an unrecognized gh command carries a non-read typed opinion rather than
   silently reading as R0.

   Deliberately NOT fail-closed here:
   - [Api]: the risk of [gh api] is the HTTP method / graphql body, which are
     string-borne. [risk_of_gh_verb] returns [R0_Read] and lets the word-list
     floor ([classify]'s [max_risk] with [classify_repo_hosting_cli]) own it,
     exactly as RFC-0208 requires.
   - a known family with a table-absent action ([gh pr view], [gh repo list]):
     a KNOWN read stays [R0_Read]. An UNRECOGNIZED action
     ([Gh_unrecognized_action], e.g. [gh repo upsert-magic]) also stays
     [R0_Read] on the RISK axis — its reversibility is genuinely unknown, and
     fabricating R1/R2 here would repeat #23362's policy-as-risk mistake. The
     gating of unrecognized actions is a CAPABILITY decision
     ([Gh_capability_policy.disposition_of] -> [Requires_approval]), not a risk
     claim; both read [classify_gh_verb] so they cannot disagree.

   This function is the capability-identity substrate for W2 (per-keeper policy)
   and W3 (approval routing). It never returns [Destructive_protected]: gh ops
   are R0/R1/R2 only, and [Destructive_protected] is the one class the dispatch
   layer special-cases. *)
let risk_of_gh_verb (v : Gh_verb.t) : risk_class =
  match classify_gh_verb v with
  (* string-borne: -X METHOD / graphql body owned by the word-list floor. *)
  | Gh_string_borne -> R0_Read
  (* fail-closed: unrecognized gh area is not a known read shape. *)
  | Gh_unrecognized_family -> R2_Irreversible
  | Gh_read -> R0_Read
  | Gh_reversible_mutation -> R1_Reversible_mutation
  | Gh_irreversible_mutation -> R2_Irreversible
  (* Risk genuinely unknown; capability axis gates it. Not fabricated to R1/R2. *)
  | Gh_unrecognized_action -> R0_Read

(* Human-readable label for the gh verb classification, for surfacing the
   gating rationale on operator approval prompts (why this gh command needs
   approval). *)
let gh_verb_class_to_string = function
  | Gh_read -> "read"
  | Gh_reversible_mutation -> "reversible mutation"
  | Gh_irreversible_mutation -> "irreversible mutation"
  | Gh_unrecognized_action -> "unrecognized action (capability-gated)"
  | Gh_string_borne -> "string-borne (word-list floor)"
  | Gh_unrecognized_family -> "unrecognized family (fail-closed)"

(* Flag-robust gh verb identity for the capability axis (RFC-0309 W3, #23599).
   The word-list [Gh_verb.classify] reads a leading value-taking global flag's
   value as the subcommand ([gh --repo O/R pr view] -> [Gh_verb.Other "O/R"]),
   which routes reversible reads/mutations to [Requires_approval]. The typed
   lowering ([Shell_ir_typed.of_simple], whose gh parser consumes gh global
   value-flags exactly like gh) locates the real subcommand/action, so this is
   the same source the enforcement floor ([repo_hosting_cli_floor_risk]) already
   trusts — the risk and capability axes cannot disagree on the subcommand.

   [None] when the command does not lower to a typed [Gh] (the [Generic] escape
   hatch for non-literal argv, e.g. [gh $CMD]); the caller then keeps its
   word-list fallback, preserving today's behavior for that case. The [Api]
   family is preserved by the typed parser ([gh api graphql] lowers to
   [subcommand="api"; action="graphql"], including the leading-flag form), so the
   caller's [gh api graphql] opacity fail-closed (RFC-0208) is not weakened. *)
let gh_verb_of_simple (simple : Shell_ir.simple) : Gh_verb.t option =
  match Shell_ir_typed.of_simple simple with
  | Shell_ir_typed.W (Shell_ir_typed_types.Gh { subcommand; action; _ }) ->
    Some (Gh_verb.of_fields ~subcommand ~action)
  | Shell_ir_typed.W _ -> None
[@@warning "-4"]

(* --- Stage-word extraction (local copy; dependency direction prevents
    reference to Exec_policy_mutation_classifier in the top-level lib). --- *)

let literal_words_of_simple (simple : Shell_ir.simple) : string list option =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (a, _) :: rest -> collect (a :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var _ :: _ -> None
  in
  match collect [] simple.args with
  | None -> None
  | Some args -> Some (Exec_program.to_string simple.bin :: args)
;;

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

(* --- Write-level classification (pure, on word list) ---------------- *)

let is_write_operation (words : string list) =
  match words with
  | "git" :: "branch" :: rest -> not (git_branch_args_are_read_only rest)
  | "git" :: "clean" :: rest -> not (git_clean_args_are_dry_run rest)
  | "git" :: "config" :: rest -> not (git_config_args_are_read_only rest)
  | "git" :: "remote" :: rest -> not (git_remote_args_are_read_only rest)
  | "git" :: "tag" :: rest -> not (git_tag_args_are_read_only rest)
  | "git" :: sub :: _ ->
    not
      (List.mem
         sub
         [ "status"; "log"; "show"; "diff"; "blame"; "rev-parse"; "merge-base";
           "ls-files"; "ls-tree"; "cat-file"; "describe"; "name-rev"; "for-each-ref";
           "shortlog"; "grep"; "help"; "--help"; "--version"; "version" ])
  | "dune" :: sub :: _ -> List.mem sub [ "clean"; "promote" ]
  | "make" :: sub :: _ -> List.mem sub [ "clean"; "deploy"; "install"; "publish" ]
  | ("npm" | "pnpm" | "yarn") :: sub :: _ ->
    List.mem
      sub
      [ "add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink";
        "update"; "up" ]
  | cmd_name :: _ ->
    List.mem
      cmd_name
      [ "mv"
      ; "cp"
      ; "mkdir"
      ; "touch"
      ; "chmod"
      ; "rm"
      ; "rmdir"
      ; "ln"
      ; "unlink"
      ; "install"
      ; "dd"
      ; "chown"
      ; "chgrp"
      ; "truncate"
      ; "mktemp"
      ; "tee"
      ; "shred"
      ]
  | [] -> false
;;

let is_destructive_bash_operation (words : string list) =
  match words with
  | "git" :: "push" :: rest ->
    List.exists
      (fun arg ->
         arg = "--force" || arg = "-f"
         || String.starts_with ~prefix:"--force-with-lease" arg)
      rest
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
;;

(* --- Action-flag danger (read-shaped tools, dangerous flags) ---

   find/sed/sort are legitimate read-shaped tools, but a single flag turns
   them destructive or write-capable while the command identity stays read-like.
   [is_write_operation]/[classify_write_detail] (head-token
   keyed) therefore never see the danger. The Find/Sort typed GADT does
   not model these flags either — like [gh], the risk is string-borne — so
   [classify_words] owns it as the floor. ([Sed.in_place] IS modeled, so
   [risk_of_typed] escalates it on the typed path too; the floor stays
   redundant there.)

   Mapping rationale: [-exec]/[-execdir]/[-ok]/[-okdir] run an arbitrary
   command and [-delete] removes files —
   the intent is "nobody destroys", so [Destructive_protected] blocks all
   keepers (dev included). The file-writing primaries ([-fprintf]/[-fls]/
   [-fprint]/[-fprint0], [sed -i], [sort -o]) are ordinary writes: [R1]
   (readonly keeper blocked, dev keeper allowed — a split that belongs to
   risk classification rather than executable-name admission). *)

let find_destructive_primaries = [ "-delete"; "-exec"; "-execdir"; "-ok"; "-okdir" ]
let find_write_primaries = [ "-fprintf"; "-fls"; "-fprint"; "-fprint0" ]

(* sed [-i]/[-i.bak]/[-Ei]/[--in-place]/[--in-place=.bak]. No other sed
   short option carries 'i', so a bundled short flag containing 'i' is
   in-place edit. *)
let sed_is_in_place arg =
  has_short_flag 'i' arg
  || String.equal arg "--in-place"
  || String.starts_with ~prefix:"--in-place=" arg
;;

(* sort [-o FILE]/[-ro FILE]/[--output FILE]/[--output=FILE]. 'o' is the
   only sort short option, so any short flag containing 'o' writes a file. *)
let sort_writes_file arg =
  has_short_flag 'o' arg
  || String.equal arg "--output"
  || String.starts_with ~prefix:"--output=" arg
;;

let action_flag_risk (words : string list) : risk_class =
  match words with
  | "find" :: rest ->
    if List.exists (fun a -> List.mem a find_destructive_primaries) rest
    then Destructive_protected
    else if List.exists (fun a -> List.mem a find_write_primaries) rest
    then R1_Reversible_mutation
    else R0_Read
  | "sed" :: rest ->
    if List.exists sed_is_in_place rest then R1_Reversible_mutation else R0_Read
  | "sort" :: rest ->
    if List.exists sort_writes_file rest then R1_Reversible_mutation else R0_Read
  | _ -> R0_Read
;;

(* --- Word-list decision (pre-typed-GADT path) -----------------------

   Retained for the [Generic] escape hatch (env/redirect/$VAR/unknown
   bin), for [Pipeline]s, and as the differential baseline that
   [risk_of_typed] must never under-classify. *)

let classify_words (words : string list) : risk_class =
  let words = normalize_command_words words in
  if head_name_in shell_interpreter_names words then Destructive_protected
  else if head_name_in shell_capable_executable_names words
  then Destructive_protected
  else if head_name_in network_primitive_names words then R1_Reversible_mutation
  else if is_destructive_bash_operation words then Destructive_protected
  else
    (* find/sed/sort action-flags are checked before the write/gh/R0
       fall-through; these heads do not overlap [is_write_operation] or
       [classify_write_detail], so an early escalation here is the max. *)
    match action_flag_risk words with
    | (Destructive_protected | R1_Reversible_mutation | R2_Irreversible) as r -> r
    | R0_Read ->
      if is_write_operation words then
        (match classify_write_detail words with
         | Some r -> r
         | None -> R2_Irreversible)
      else
        (match words with
         | "gh" :: _ -> classify_repo_hosting_cli words
         | _ -> R0_Read)
;;

(* --- Typed-GADT decision substrate (RFC-0160 §S1 completion) ----------

   [risk_of_typed] is the risk opinion implied by the typed command
   shape alone — the first decision path that reads the [Shell_ir_typed]
   GADT instead of re-flattening to a word list. [classify] combines it
   with the word-list floor ([classify_words]) by taking the stricter of
   the two, so the overall decision is monotone-safe by construction.

   The match is exhaustive (no [_ ->] catch-all): adding a constructor
   to [Shell_ir_typed_types.command] forces a compile error here, so a
   new typed command cannot reach dispatch without a risk decision.
   CLAUDE.md §"FSM Sparse Match" — every constructor named, no wildcard.

   Policy (2026-06-07, Shell IR SSOT — monotone-safe, escalate dangerous
   gaps only): the type closes word-list holes it makes visible —
   [Sudo] (privilege escalation; the word-list head token was "sudo" so
   its "rm"/"git push" arms never fired -> silent R0), [Su] and [Mkfs]
   (R0 -> R2), plus network primitives ([Curl]/[Wget]/[Ssh]/[Scp]/[Rsync])
   that are not local reads and must not promote to Safe_IR. Commands the
   word-list already classifies keep their risk (sed/git pull stay R0;
   git push/commit stay R1; rm -rf protected stays Destructive). [Gh] and
   [Generic] return R0 here because the
   type cannot see their risk-bearing tokens (gh -X METHOD / graphql
   body / -f fields live in argv strings, not the typed shape); the
   word-list floor in [classify] supplies it. For gh this is by design
   and permanent — gh risk is irreducibly string-borne, so floor
   retirement (P7) is scoped to structurally-typed classes and never
   covers gh. *)

let npm_write_subcommands =
  [ "add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink";
    "update"; "up" ]
;;

let risk_of_typed (w : Shell_ir_typed.wrapped) : risk_class =
  let open Shell_ir_typed in
  match w with
  (* --- read / inspection: R0_Read ----------------------------------- *)
  | W (Ls _) -> R0_Read
  | W (Cat _) -> R0_Read
  | W (Rg _) -> R0_Read
  (* find -delete / -exec / -fprintf carry their danger in action-flags the
     Find GADT does not model, so (like gh) the risk is string-borne and
     classify_words owns it as the floor. The typed shape alone is R0. *)
  | W (Find _) -> R0_Read
  | W (Head _) -> R0_Read
  | W (Tail _) -> R0_Read
  | W (Grep _) -> R0_Read
  | W (Wc _) -> R0_Read
  | W (Pwd _) -> R0_Read
  | W (Echo _) -> R0_Read
  | W (Which _) -> R0_Read
  (* sort -o FILE writes a file; the Sort GADT does not model [-o], so
     classify_words owns it as the floor (string-borne, like find). R0 here. *)
  | W (Sort _) -> R0_Read
  | W (Cut _) -> R0_Read
  | W (Tr _) -> R0_Read
  | W (Date _) -> R0_Read
  | W (Env _) -> R0_Read
  | W (Printenv _) -> R0_Read
  | W (Uniq _) -> R0_Read
  | W (Basename _) -> R0_Read
  | W (Dirname _) -> R0_Read
  | W (Test _) -> R0_Read
  | W (Stat _) -> R0_Read
  | W (Hostname _) -> R0_Read
  | W (Whoami _) -> R0_Read
  | W (Du _) -> R0_Read
  | W (Df _) -> R0_Read
  | W (File _) -> R0_Read
  | W (Printf _) -> R0_Read
  | W (Uname _) -> R0_Read
  | W (Ps _) -> R0_Read
  | W (Tty _) -> R0_Read
  | W (Diff _) -> R0_Read
  (* git read subcommands: R0 (parity with word-list) *)
  | W (Git_status _) -> R0_Read
  | W (Git_diff _) -> R0_Read
  | W (Git_log _) -> R0_Read
  (* git pull: word-list does not list "pull" as write -> R0 (kept under
     option B; escalation deferred to a correctness follow-up) *)
  | W (Git_pull _) -> R0_Read
  | W (Git_stash _) -> R0_Read
  | W (Git_rebase _) -> R0_Read
  | W (Git_merge _) -> R0_Read
  | W (Git_branch _) -> R0_Read
  (* RFC-0208 P3: checkout mutates the working tree / HEAD (and -b creates
     a branch); the word-list floor classifies all [git checkout] as a
     write (R1). Match it on the typed path so the floor is redundant
     here. *)
  | W (Git_checkout _) -> R1_Reversible_mutation
  | W (Git_fetch _) -> R0_Read
  | W (Git_show _) -> R0_Read
  (* RFC-0208 P3: the word-list floor classifies all [git reset] as R2
     (classify_write_detail). Match it on the typed path. A future,
     deliberate de-escalation could rate --soft/--mixed as R1, but only
     by lowering the floor in lockstep — never below it (monotone). *)
  | W (Git_reset _) -> R2_Irreversible
  | W (Git_blame _) -> R0_Read
  | W (Git_add _) -> R0_Read
  (* Network primitives are not local reads. Keep this in Shell IR risk so
     Execute/safe_sh consume one classification substrate instead of each
     keeping executable-name gates. *)
  | W (Curl _) -> R1_Reversible_mutation
  | W (Wget _) -> R1_Reversible_mutation
  | W (Ssh _) -> R1_Reversible_mutation
  | W (Scp _) -> R1_Reversible_mutation
  | W (Tar _) -> R0_Read
  (* sed -i / --in-place edits files in place (R1). The GADT models
     [in_place], so the typed path escalates it; classify_words owns the
     word-list floor for parity. Non-in-place sed is a read filter (R0). *)
  | W (Sed { in_place; _ }) ->
    if in_place then R1_Reversible_mutation else R0_Read
  | W (Rsync _) -> R1_Reversible_mutation
  (* Shell-capable interpreters/package entrypoints can run arbitrary
     filesystem and process mutations even when their argv looks read-shaped. *)
  | W (Node _) -> Destructive_protected
  | W (Python _) -> Destructive_protected
  | W (Python3 _) -> Destructive_protected
  | W (Pip _) -> Destructive_protected
  | W (Npx _) -> Destructive_protected
  (* build and analysis tools the word-list leaves at R0 *)
  | W (Patch _) -> R0_Read
  | W (Cargo _) -> R0_Read
  | W (Go _) -> R0_Read
  | W (Opam { subcommand; _ }) ->
    if String.equal subcommand "exec" then Destructive_protected
    else R0_Read
  | W (Uv _) -> R0_Read
  | W (Glab _) -> R0_Read
  | W (Pytest _) -> R0_Read
  | W (Terminal_notifier _) -> R0_Read
  | W (Ruff _) -> R0_Read
  | W (Pyright _) -> R0_Read
  | W (Tsc _) -> R0_Read
  | W (Ocamlfind _) -> R0_Read
  | W (Rustc _) -> R0_Read
  | W (Gofmt _) -> R0_Read
  | W (Gradle _) -> R0_Read
  | W (Ninja _) -> R0_Read
  | W (Java _) -> R0_Read
  | W (Javac _) -> R0_Read
  | W (Mvn _) -> R0_Read
  | W (Cmake _) -> R0_Read
  | W (Dune_local_sh _) -> R0_Read
  | W (Osascript _) -> R0_Read
  | W (Play _) -> R0_Read
  | W (Rec _) -> R0_Read
  | W (Ffplay _) -> R0_Read
  | W (Mpg123 _) -> R0_Read
  | W (Open _) -> R0_Read
  (* --- reversible mutation: R1 (parity with word-list write list) --- *)
  | W (Mkdir _) -> R1_Reversible_mutation
  | W (Chmod _) -> R1_Reversible_mutation
  | W (Chown _) -> R1_Reversible_mutation
  | W (Make _) -> R1_Reversible_mutation
  | W (Git_clone _) -> R1_Reversible_mutation
  | W (Git_commit _) -> R1_Reversible_mutation
  (* node package managers: write subcommands -> R1, else R0 *)
  | W (Npm { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands then R1_Reversible_mutation
    else R0_Read
  | W (Yarn { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands then R1_Reversible_mutation
    else R0_Read
  | W (Pnpm { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands then R1_Reversible_mutation
    else R0_Read
  (* git push: force / force-with-lease is Destructive_protected;
     protected-branch escalation lives in policy hooks (RFC-0208). *)
  | W (Git_push { force; force_with_lease; _ }) ->
    if force || force_with_lease then Destructive_protected
    else R1_Reversible_mutation
  (* --- irreversible: R2 --------------------------------------------- *)
  (* Su / Dd / Mkfs: word-list head-token match missed Su/Mkfs (-> R0);
     the type makes them visible. Dd was already R2 in the word-list. *)
  | W (Su _) -> R2_Irreversible
  | W (Dd _) -> R2_Irreversible
  | W (Mkfs _) -> R2_Irreversible
  (* rm: recursive + force -> Destructive_protected, else R2 (word-list
     parity with [is_destructive_bash_operation] / [classify_write_detail]) *)
  | W (Rm { recursive; force; _ }) ->
    if recursive && force then Destructive_protected else R2_Irreversible
  (* --- privilege escalation: Destructive_protected ------------------ *)
  (* sudo wraps an arbitrary argv; the word-list head was "sudo" so its
     "rm"/"git push" arms never fired (silent R0). Privilege escalation
     always requires approval. *)
  | W (Sudo _) -> Destructive_protected
  (* RFC-0208 + RFC-0309 §2/§3.1 (W1): gh's string-borne risk stays
     floor-owned, but its top-level *area* is now a closed typed family.

     The HTTP method (-X DELETE), -f/--field values, and the graphql body
     remain in argv strings; [classify]'s [max_risk] with the word-list floor
     ([classify_repo_hosting_cli] on the original, un-round-tripped words) owns
     that risk, so gh api / -X DELETE / graphql mutations classify exactly as
     before. This arm does NOT re-parse those words (the round-trip that an
     earlier version tried mis-parsed `-X DELETE` to R0 — strictly worse than
     the floor).

     What changed: instead of a blanket [R0_Read] abstention, we read the
     already-parsed [subcommand]/[action] fields (no re-tokenization) into a
     [Gh_verb.t] and take [risk_of_gh_verb]. For every recognized family that
     opinion equals the floor (same tables), so [max_risk] is unchanged for
     known gh. It differs only for an unrecognized top-level area
     ([Gh_verb.Other]): the typed opinion is [R2_Irreversible] (fail-closed)
     while the floor stays [R0_Read], so [max_risk] lifts an unknown gh command
     to R2. That composed value is observability for W1 (the keeper approval
     gate reads the word-list floor, not this opinion); it becomes enforcement
     in W3 when unknown gh routes to non-blocking approval. *)
  | W (Gh { subcommand; action; _ }) ->
    risk_of_gh_verb (Gh_verb.of_fields ~subcommand ~action)
  | W (Docker _) -> R0_Read
  (* File operations — cp/mv/ln/touch are reversible or low-risk mutations *)
  | W (Cp _) -> R1_Reversible_mutation
  | W (Mv _) -> R1_Reversible_mutation
  | W (Ln _) -> R1_Reversible_mutation
  | W (Touch _) -> R1_Reversible_mutation
  | W (Tee _) -> R1_Reversible_mutation
  | W (Awk _) -> R0_Read
  | W (Xargs _) -> R2_Irreversible
  (* escape hatch (env/redirect/$VAR/unknown bin): no typed shape to
     read; [classify]'s word-list floor classifies it. *)
  | W (Generic _) -> R0_Read
;;

(* --- Main classifier ------------------------------------------------ *)

let risk_rank = function
  | R0_Read -> 0
  | R1_Reversible_mutation -> 1
  | R2_Irreversible -> 2
  | Destructive_protected -> 3
;;

let max_risk a b = if risk_rank a >= risk_rank b then a else b

(* Enforcement-floor risk for a gh command, robust to leading global flags.

   [classify_repo_hosting_cli] locates the subcommand as the first non-flag
   token after "gh", so a leading value-taking global flag ([gh --repo o/r pr
   merge]) shifts the flag's value ("o/r") into the subcommand slot and the
   destructive verb ("merge") is missed — the command classifies R0 and the
   approval catastrophic floor never fires (issue #23390: gh accepts flags
   before the subcommand via Cobra, so the op executes). This is the floor's
   SSOT for gh risk, so the miss is an autonomous-keeper bypass.

   Fix: combine three views with [max_risk].
   - [words]: the existing word-list classifier — retains the string-borne
     risk it alone sees ([gh api -X DELETE], graphql mutation bodies,
     positional-token scans) when argv is all literal.
   - [simple] arg words: an enforcement-only view that consumes known gh global
     value flags directly from [Shell_ir.arg], so dynamic flag values cannot
     shadow the real family/action slot.
   - [simple]: the typed lowering ([Shell_ir_typed.of_simple], whose gh parser
     consumes value-flags exactly like gh) yields the correctly-located
     subcommand; [table_risk_of_gh_family] then reads the same subcommand
     tables. [Api]/[Other]/bare family stay R0 here — this fix restores correct
     subcommand location WITHOUT changing the historical "unknown gh subcommand
     is R0" floor semantics (fail-closing unknown gh is RFC-0309 W3, not this
     bug fix). *)
let repo_hosting_cli_floor_risk (words : string list) (simple : Shell_ir.simple)
  : risk_class
  =
  let word_risk = classify_repo_hosting_cli words in
  let arg_word_risk =
    match gh_floor_words_of_simple simple with
    | Some words -> classify_repo_hosting_cli words
    | None -> R0_Read
  in
  let typed_risk =
    (* [@warning "-4"]: only the [Gh] constructor is of interest; every other
       typed command (and the [Generic] escape hatch for non-literal argv) is
       not a repo-hosting op, so it floors nothing here and the word-list path
       above already covers it. Same find-first rationale as
       [Approval_policy.find_destructive_repo_hosting_cli]. *)
    match Shell_ir_typed.of_simple simple with
    | Shell_ir_typed.W (Shell_ir_typed_types.Gh { subcommand; action; _ }) -> (
      let v = Gh_verb.of_fields ~subcommand ~action in
      match v.Gh_verb.family, v.Gh_verb.action with
      | (Gh_verb.Api | Gh_verb.Other _), _ | _, None -> R0_Read
      | ( ( Gh_verb.Pr | Gh_verb.Issue | Gh_verb.Repo | Gh_verb.Discussion
          | Gh_verb.Release | Gh_verb.Secret | Gh_verb.Ssh_key
          | Gh_verb.Workflow | Gh_verb.Auth | Gh_verb.Gist | Gh_verb.Ruleset
          | Gh_verb.Label | Gh_verb.Run | Gh_verb.Cache | Gh_verb.Project ) as
        fam )
      , Some action ->
        table_risk_of_gh_family (Gh_verb.family_token fam) action)
    | Shell_ir_typed.W _ -> R0_Read
  in
  max_risk word_risk (max_risk arg_word_risk typed_risk)
[@@warning "-4"]

let redirect_risk = function
  | Redirect_scope.File { mode = (Redirect_scope.Write | Redirect_scope.Append); _ } ->
    R1_Reversible_mutation
  | Redirect_scope.File { mode = Redirect_scope.Read; _ }
  | Redirect_scope.Fd_to_fd _ ->
    R0_Read
;;

let redirect_floor redirects =
  List.fold_left
    (fun acc redirect -> max_risk acc (redirect_risk redirect))
    R0_Read
    redirects
;;

(* Per-[Simple] decision: the stricter of the typed-shape opinion and
   the word-list floor for that single command. Both opinions are scoped
   to one command's own words, so a pipeline can compose them stage by
   stage instead of flattening every stage into one head-anchored list.
   When [literal_words_of_simple] returns [None] (env/redirect/$VAR present)
   the word-list floor cannot be computed and falls back to [R0_Read];
   the typed opinion still supplies escalation for those cases. Redirect
   writes are command syntax rather than argv tokens, so they get their
   own floor here; otherwise [echo hi > file] can remain R0 in receipts
   even though capability policy correctly sees [Write_path]. *)
let decision_of_simple (s : Shell_ir.simple) : risk_class =
  let typed = risk_of_typed (Shell_ir_typed.of_simple s) in
  let floor =
    match literal_words_of_simple s with
    | Some words -> classify_words words
    | None -> R0_Read
  in
  max_risk (redirect_floor s.redirects) (max_risk typed floor)
;;

(* RFC-0208 P0: compose the per-stage decision across a pipeline with
   [max_risk], rather than the previous blanket [Pipeline -> R0_Read]
   for the typed path. Before this, a privilege-escalation or destructive
   command in any non-head pipeline stage (e.g.
   [echo x | sudo tee /etc/passwd], [cat f | git push --force origin main],
   [sudo cat f | grep y]) was invisible to both the typed path (which
   read no stage) and the word-list floor (which matches only the head
   token of the flattened word list). The fold reuses the existing
   per-constructor [risk_of_typed] and [classify_words] per stage — in
   particular the [W (Sudo)] arm now fires for sudo anywhere in a
   pipeline — so it adds no new string classifier. *)
let rec composed_decision (ir : Shell_ir.t) : risk_class =
  match ir with
  | Shell_ir.Simple s -> decision_of_simple s
  | Shell_ir.Pipeline stages ->
    List.fold_left
      (fun acc stage -> max_risk acc (composed_decision stage))
      R0_Read
      stages
;;

(* RFC-0208 P6: [classify] returns [composed_decision] directly.
   The legacy flat word-list floor was removed: per-stage [max_risk]
   composition (P0) already covers every cross-stage scenario the flat
   floor caught, and P2 harness data showed 84% redundancy / 0%
   structural load-bearing. Any remaining string-borne gaps are owned by
   Hook/Policy pre-flight checks, not core classification. *)
let classify (T ir : undecided t) : decided decided_ir =
  { ir; risk = composed_decision ir }
;;

(* RFC-0208 P1 observability: did the typed lowering classify every
   [Simple] node via a real constructor, or did it fall to the [Generic]
   escape hatch? [classify] folds the typed and word-list verdicts into a
   single [risk_class] and discards which path won, so the 110 typed
   constructors are invisible in production. [typed_hit_of_ir] recovers
   the typed-vs-Generic signal so the dispatch log and the differential
   harness can measure real coverage. A pipeline is a typed hit only when
   all of its stages are. *)
let rec typed_hit_of_ir (ir : Shell_ir.t) : bool =
  match ir with
  | Shell_ir.Simple s -> not (Shell_ir_typed.is_generic (Shell_ir_typed.of_simple s))
  | Shell_ir.Pipeline stages -> List.for_all typed_hit_of_ir stages
;;
