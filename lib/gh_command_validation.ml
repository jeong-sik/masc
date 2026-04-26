(** Gh_command_validation — gh CLI safety classification and validation.

    Extracted from Worker_dev_tools to decompose the godfile.
    Provides R0/R1/R2 reversibility classification, command allowlist
    enforcement, and destructive-operation detection for keeper gh ops.

    @since godfile decomposition pass 2 *)

let forbidden_shell_chars = [ ';'; '|'; '&'; '>'; '<'; '`'; '$'; '\n'; '\r' ]

let contains_forbidden_shell_chars cmd =
  String.exists (fun ch -> List.mem ch forbidden_shell_chars) cmd
;;

(** Top-level gh CLI commands allowed. Commands not in this list are
    rejected at the allowlist gate. *)
let gh_allowed_commands =
  [ "api"
  ; "cache"
  ; "gist"
  ; "issue"
  ; "label"
  ; "pr"
  ; "project"
  ; "release"
  ; "repo"
  ; "ruleset"
  ; "run"
  ; "search"
  ; "status"
  ; "workflow"
  ]
;;

(** Reversibility classification for gh commands.
    Based on Thariq (Anthropic) Agent SDK workshop principle:
    "Tools for atomic/irreversible actions; bash for reversible work."
    + Anthropic Claude Code auto mode pattern:
    "Safe-tool allowlist = tools that cannot modify state; everything
    else goes to classifier; irreversible requires approval."

    - [R0_Read]: no state mutation. gh view/list, api GET, status,
      search. Free to run; only org allowlist gate.
    - [R1_Reversible]: mutates state but recoverable via inverse op.
      pr create/close/reopen/merge/ready/comment/edit, issue
      create/close/reopen, label create/delete, run cancel. Allowed
      + caller is expected to emit an audit event.
    - [R2_Irreversible]: cannot be undone via a gh inverse op.
      repo delete/archive/transfer/rename, release delete, secret
      delete, auth logout/token, ssh-key delete, workflow disable,
      api --method DELETE, graphql mutation delete*/remove*/transfer*.
      Must route through a structured keeper tool that carries
      operator-approval semantics. *)
type gh_reversibility =
  | R0_Read
  | R1_Reversible
  | R2_Irreversible

let string_of_gh_reversibility = function
  | R0_Read -> "R0"
  | R1_Reversible -> "R1"
  | R2_Irreversible -> "R2"
;;

(** (command, subcommand) pairs classified as R2 irreversible.
    Conservative: when an operation *could* leak/destroy state that
    gh itself cannot restore, we mark it R2 even if a manual recovery
    path exists. Examples: repo archive is technically reversible via
    unarchive but disrupts downstream PRs; ssh-key delete is
    re-registrable but signing/deploy keys mid-CI break. *)
let gh_irreversible_ops =
  [ "repo", [ "delete"; "archive"; "transfer"; "rename" ]
  ; "release", [ "delete" ]
  ; "secret", [ "delete"; "remove" ]
  ; "ssh-key", [ "delete" ]
  ; "workflow", [ "disable" ]
  ; "auth", [ "logout"; "token" ]
  ; "gist", [ "delete" ]
  ; "ruleset", [ "delete" ]
  ]
;;

(** (command, subcommand) pairs classified as R1 reversible mutation.
    The inverse operation is also a gh subcommand (pr close ↔ reopen,
    label create ↔ delete, run cancel is always followed by rerun).
    Allowed via op=gh but callers should audit. *)
let gh_reversible_mutations =
  [ ( "pr"
    , [ "create"
      ; "close"
      ; "reopen"
      ; "merge"
      ; "ready"
      ; "edit"
      ; "comment"
      ; "review"
      ; "lock"
      ; "unlock"
      ] )
  ; ( "issue"
    , [ "create"
      ; "close"
      ; "reopen"
      ; "edit"
      ; "comment"
      ; "lock"
      ; "unlock"
      ; "develop"
      ; "pin"
      ; "unpin"
      ] )
  ; "label", [ "create"; "edit"; "delete"; "clone" ]
  ; "release", [ "create"; "edit"; "upload"; "download" ]
  ; "run", [ "cancel"; "rerun"; "watch" ]
  ; "cache", [ "delete" ]
  ; "gist", [ "create"; "edit"; "clone"; "rename" ]
  ; "repo", [ "create"; "clone"; "fork"; "edit"; "sync"; "set-default" ]
  ; ( "project"
    , [ "create"
      ; "edit"
      ; "close"
      ; "copy"
      ; "link"
      ; "unlink"
      ; "field-create"
      ; "field-delete"
      ; "item-add"
      ; "item-archive"
      ; "item-delete"
      ; "item-edit"
      ] )
  ; "workflow", [ "enable"; "run" ]
  ; "ruleset", [ "create"; "edit" ]
  ]
;;

(** SSOT: GraphQL mutation names classified as R2 irreversible.
    Used by both [gh_api_graphql_is_destructive] (R0/R1/R2 classifier)
    and [is_gh_dangerous_operation] (legacy workflow guard).
    All names are lowercase for substring matching. *)
let gh_graphql_r2_mutations =
  [ "deletepullrequest"
  ; "deleteissue"
  ; "deletebranch"
  ; "deleteref"
  ; "deleteproject"
  ; "deletebranchprotectionrule"
  ; "removeouterfromorganization"
  ; "transferrepository"
  ; "archiverepository"
  ]
;;

let extract_gh_api_method cmd =
  let tokens =
    String.split_on_char ' ' (String.trim cmd) |> List.filter (fun s -> s <> "")
  in
  let rec find = function
    | [] -> "GET"
    | "-X" :: m :: _ | "--method" :: m :: _ -> String.uppercase_ascii m
    | tok :: _ when String.length tok > 9 && String.starts_with ~prefix:"--method=" tok ->
      String.uppercase_ascii (String.sub tok 9 (String.length tok - 9))
    | tok :: _ when String.length tok > 3 && String.starts_with ~prefix:"-X=" tok ->
      String.uppercase_ascii (String.sub tok 3 (String.length tok - 3))
    | _ :: rest -> find rest
  in
  find tokens
;;

(** Detect [gh api graphql] invocations that carry a destructive
    mutation name. Uses substring match on the query body (passed via
    -f query=... or --raw-field query=...). Conservative: unknown
    mutation names default to R1 because GraphQL mutation semantics
    are wide; only the destructive-verb-prefix set is R2. *)
let gh_api_graphql_is_destructive cmd =
  let lower = String.lowercase_ascii cmd in
  let has s = String_util.contains_substring lower s in
  has "graphql" && List.exists has gh_graphql_r2_mutations
;;

(** Legacy alias: kept so pre-classifier call sites still compile.
    Equivalent to [classify_gh_reversibility cmd = R2_Irreversible]
    for the pairs we used to block. *)
let gh_blocked_operations =
  List.concat_map (fun (c, subs) -> List.map (fun s -> c, s) subs) gh_irreversible_ops
;;

(** Extract owner from a [--repo OWNER/NAME], [--repo=OWNER/NAME], or
    [-R OWNER/NAME] flag in a gh command string. Returns [None] if no
    such flag is present — in that case gh defaults to the cwd's git
    origin, which is already org-gated at clone time.

    Only the owner segment is returned; repo/branch names are outside
    the allowlist scope. *)
let extract_gh_repo_owner cmd =
  let tokens =
    String.split_on_char ' ' (String.trim cmd) |> List.filter (fun s -> s <> "")
  in
  let owner_of_slug s =
    match String.split_on_char '/' s with
    | owner :: _ :: _ when owner <> "" -> Some owner
    | _ -> None
  in
  let rec find = function
    | [] -> None
    | "--repo" :: slug :: _ | "-R" :: slug :: _ -> owner_of_slug slug
    | tok :: rest when String.length tok > 7 && String.starts_with ~prefix:"--repo=" tok
      ->
      let slug = String.sub tok 7 (String.length tok - 7) in
      (match owner_of_slug slug with
       | Some _ as o -> o
       | None -> find rest)
    | _ :: rest -> find rest
  in
  find tokens
;;

(** Extract the top-level command and its first subcommand from a gh
    command string (the portion after "gh ").
    Flags (starting with '-') and their values are skipped when scanning
    for the subcommand, preventing bypass via flag insertion.
    Example: "pr view 123" -> (Some "pr", Some "view")
    Example: "workflow --repo o/r disable" -> (Some "workflow", Some "disable") *)
let extract_gh_command_pair cmd =
  let parts =
    String.split_on_char ' ' (String.trim cmd) |> List.filter (fun s -> s <> "")
  in
  match parts with
  | [] -> None, None
  | [ x ] -> Some x, None
  | x :: rest ->
    let rec find_subcmd = function
      | [] -> None
      | tok :: tl ->
        if String.length tok > 0 && tok.[0] = '-'
        then
          if String.contains tok '='
          then find_subcmd tl
          else (
            match tl with
            | _ :: rest' -> find_subcmd rest'
            | [] -> None)
        else Some tok
    in
    Some x, find_subcmd rest
;;

(** Validate a gh CLI command string for safety.
    Checks in order:
      (1) shell metacharacters,
      (2) top-level command allowlist,
      (3) blocked (command, subcommand) operation pairs,
      (4) [--repo OWNER/NAME] owner against [allowed_orgs] (if non-empty).

    Check 4 is skipped when [allowed_orgs] is [] (policy not configured)
    or when the command carries no [--repo] flag (gh falls back to
    cwd's origin, which is already gated at clone time).

    [cmd] is the portion after "gh ", e.g. "pr view 123". *)
let validate_gh_command ?(allowed_orgs = []) cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error "gh command must not be empty"
  else if contains_forbidden_shell_chars trimmed
  then
    Error
      "Blocked: chaining/redirect in gh command. Use a single subcommand. Good: cmd='pr \
       list --state open'. Bad: cmd='pr list && echo done'."
  else (
    match extract_gh_command_pair trimmed with
    | None, _ -> Error "gh command must not be empty"
    | Some command, subcmd ->
      let command = String.lowercase_ascii command in
      if not (List.mem command gh_allowed_commands)
      then
        (* #10561: inline the allowed list so the LLM sees valid alternatives
           on the same retry instead of random-guessing into the next
           [gh_command_blocked] error.  Same pattern as
           [path_not_found_under_allowed_roots] which surfaces roots=[...].
           Memory: feedback_tool-error-messages-teach-llm. *)
        Error
          (Printf.sprintf
             "gh command blocked: '%s' is not in the approved command list (allowed=[%s])"
             command
             (String.concat ", " gh_allowed_commands))
      else (
        let sub = Option.value ~default:"" subcmd |> String.lowercase_ascii in
        if List.exists (fun (c, s) -> c = command && s = sub) gh_blocked_operations
        then Error (Printf.sprintf "gh %s %s is blocked for safety" command sub)
        else (
          match allowed_orgs, extract_gh_repo_owner trimmed with
          | [], _ | _, None -> Ok ()
          | orgs, Some owner when List.mem owner orgs -> Ok ()
          | orgs, Some owner ->
            Error
              (Printf.sprintf
                 "gh --repo owner '%s' not in allowed_orgs [%s]. Drop --repo to use the \
                  current repo, or use an allowed org."
                 owner
                 (String.concat ", " orgs)))))
;;

(** Known destructive API endpoint patterns.
    Each pattern is checked as a substring of the full command.
    Covers merge, state-closing, and branch-merge endpoints. *)
let gh_api_destructive_patterns =
  [ "/merge"; "/merges"; "state=closed"; "state=\"closed\""; "state='closed'" ]
;;

(** Legacy alias. Callers that need the R1 workflow-mutation names
    (mergepullrequest, closepullrequest, closeissue) add them locally;
    the R2 set is [gh_graphql_r2_mutations]. *)
let gh_graphql_destructive_mutations =
  gh_graphql_r2_mutations @ [ "mergepullrequest"; "closepullrequest"; "closeissue" ]
;;

(** Check if a gh API command uses or implies a non-GET HTTP method.
    Returns [true] for explicit mutating methods (-X POST, --method PATCH,
    etc.) and for implicit POST via field flags (-f, -F, --field,
    --raw-field), matching gh CLI behavior where field flags cause an
    automatic POST. Handles both "--method POST" and "--method=POST". *)
let has_implicit_post_flags parts =
  let rec check = function
    | [] -> false
    | tok :: rest ->
      let tok_lower = String.lowercase_ascii tok in
      if
        tok = "-f"
        || tok = "-F"
        || tok = "--field"
        || tok = "--raw-field"
        || (String.length tok_lower > 3 && String.starts_with ~prefix:"-f=" tok_lower)
        || (String.length tok_lower > 8 && String.starts_with ~prefix:"--field=" tok_lower)
        || (String.length tok_lower > 12
            && String.starts_with ~prefix:"--raw-field=" tok_lower)
      then true
      else check rest
  in
  check parts
;;

let has_mutating_http_method parts =
  let cmd = String.concat " " parts in
  let m = String.lowercase_ascii (extract_gh_api_method cmd) in
  (m = "post" || m = "put" || m = "patch" || m = "delete")
  || has_implicit_post_flags parts
;;

(** Classify a gh command string by state reversibility.
    The command is the portion after "gh " — a normalized form
    without the leading "gh" literal.

    Precedence (first match wins):
      1. top command + subcommand in [gh_irreversible_ops] → R2
      2. [api] with [--method DELETE] or a destructive graphql
         mutation → R2
      3. [api] with --method POST/PUT/PATCH, or implicit POST via
         [-f]/[-F]/[--field]/[--raw-field] (gh auto-converts field
         flags to POST) → R1
      4. top command + subcommand in [gh_reversible_mutations] → R1
      5. anything else → R0 (read-only default) *)
let classify_gh_reversibility cmd =
  match extract_gh_command_pair cmd with
  | None, _ -> R0_Read
  | Some command, subcmd_opt ->
    let command = String.lowercase_ascii command in
    let sub = Option.value ~default:"" subcmd_opt |> String.lowercase_ascii in
    let in_table table =
      List.exists (fun (c, subs) -> c = command && List.mem sub subs) table
    in
    if in_table gh_irreversible_ops
    then R2_Irreversible
    else if command = "api"
    then (
      let method_ = extract_gh_api_method cmd in
      let parts =
        String.split_on_char ' ' (String.trim cmd) |> List.filter (fun s -> s <> "")
      in
      if method_ = "DELETE"
      then R2_Irreversible
      else if gh_api_graphql_is_destructive cmd
      then R2_Irreversible
      else if List.mem method_ [ "POST"; "PUT"; "PATCH" ]
      then R1_Reversible
      else if has_mutating_http_method parts
      then R1_Reversible
      else R0_Read)
    else if in_table gh_reversible_mutations
    then R1_Reversible
    else R0_Read
;;

(** Suggested next-action hint for a rejected R2 command.
    Returned in the gate response so small LLMs can self-recover
    without a second operator turn. Conservative: only returns a hint
    when the mapping is obvious; otherwise None → caller falls back
    to a generic message. *)
let structured_tool_hint_for_r2 cmd =
  match extract_gh_command_pair cmd with
  | Some "repo", Some ("delete" | "archive" | "transfer" | "rename") ->
    Some
      "Use an operator-approved path: open a board post describing the intent and wait \
       for operator action. No keeper tool performs repo-level destructive ops."
  | Some "release", Some "delete" ->
    Some
      "Open a board post with release tag + reason. Release deletion requires operator \
       approval."
  | Some "secret", _ | Some "ssh-key", _ | Some "auth", _ ->
    Some "Credential operations are operator-only. Do not attempt via any keeper tool."
  | Some "api", _ ->
    Some
      "Destructive gh api calls (DELETE or graphql mutation delete*/remove*/transfer*) \
       are blocked. Use pr/issue subcommands for R1 mutations, or open a board post."
  | _ -> None
;;

(** Filter out flag-like tokens, keeping only positional args.
    Handles boolean flag bypass (e.g. "workflow -q delete"). *)
let positional_tokens parts =
  List.filter (fun s -> String.length s = 0 || s.[0] <> '-') parts
;;

(** Shared tokenizer for destructive-operation checks. *)
let gh_op_parts cmd =
  String.split_on_char ' ' (String.trim cmd)
  |> List.filter (fun s -> s <> "")
  |> List.map String.lowercase_ascii
;;

let has_positional_subcmd subcmds rest =
  let positionals = positional_tokens rest in
  List.exists (fun s -> List.mem s subcmds) positionals
;;

(** Check if a gh command is a normal workflow mutation (merge, close).
    These are legitimate for coding-preset keepers but should still be
    gated for lower-privilege presets. *)
let is_gh_workflow_operation cmd =
  let parts = gh_op_parts cmd in
  match parts with
  | "pr" :: rest -> has_positional_subcmd [ "merge"; "close" ] rest
  | "issue" :: rest -> has_positional_subcmd [ "close" ] rest
  | "project" :: rest -> has_positional_subcmd [ "close" ] rest
  | "api" :: _ ->
    let joined = String.concat " " parts in
    has_mutating_http_method parts
    && List.exists
         (fun pat -> String_util.contains_substring joined pat)
         [ "/merge"; "/merges"; "state=closed"; "state=\"closed\""; "state='closed'" ]
  | _ -> false
;;

(** Check if a gh command is specifically [gh pr merge]. *)
let is_gh_pr_merge cmd =
  let parts = gh_op_parts cmd in
  match parts with
  | "pr" :: rest -> has_positional_subcmd [ "merge" ] rest
  | _ -> false
;;

let gh_raw_parts cmd =
  String.split_on_char ' ' (String.trim cmd) |> List.filter (fun s -> s <> "")
;;

let gh_option_takes_value tok =
  let tok = String.lowercase_ascii tok in
  (not (String_util.contains_substring tok "="))
  && List.mem
       tok
       [ "-r"
       ; "--repo"
       ; "-b"
       ; "--body"
       ; "-f"
       ; "--body-file"
       ; "-t"
       ; "--subject"
       ; "--match-head-commit"
       ; "--author-email"
       ]
;;

(** Return the explicit target passed to [gh pr merge], if any.
    Supports numeric PR ids, branch names, and PR URLs. Returns [None]
    when the merge command targets the current branch's PR. *)
let gh_pr_merge_target cmd =
  let raw_parts = gh_raw_parts cmd in
  let lower_parts = List.map String.lowercase_ascii raw_parts in
  let rec drop_until_merge raw lower =
    match raw, lower with
    | _raw_hd :: raw_tl, lower_hd :: lower_tl ->
      if lower_hd = "merge"
      then Some (raw_tl, lower_tl)
      else drop_until_merge raw_tl lower_tl
    | _ -> None
  in
  let rec find_target raw lower =
    match raw, lower with
    | [], [] -> None
    | raw_hd :: raw_tl, lower_hd :: lower_tl ->
      if String.length lower_hd > 0 && lower_hd.[0] = '-'
      then
        if gh_option_takes_value lower_hd
        then (
          match raw_tl, lower_tl with
          | _value :: raw_rest, _value_lower :: lower_rest ->
            find_target raw_rest lower_rest
          | _ -> None)
        else find_target raw_tl lower_tl
      else Some raw_hd
    | _ -> None
  in
  match lower_parts with
  | "pr" :: _ ->
    (match drop_until_merge raw_parts lower_parts with
     | Some (raw_after_merge, lower_after_merge) ->
       find_target raw_after_merge lower_after_merge
     | None -> None)
  | _ -> None
;;

(** Check if a gh command is a dangerous irreversible operation (delete,
    archive, transfer). Always gated regardless of preset. *)
let is_gh_dangerous_operation cmd =
  let parts = gh_op_parts cmd in
  match parts with
  | "issue" :: rest -> has_positional_subcmd [ "delete"; "transfer" ] rest
  | "release" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "repo" :: rest -> has_positional_subcmd [ "archive"; "rename" ] rest
  | "label" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "cache" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "project" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "workflow" :: rest -> has_positional_subcmd [ "delete" ] rest
  | "ruleset" :: _ -> false
  | "api" :: _ ->
    let joined = String.concat " " parts in
    List.mem "delete" parts
    || (List.mem "graphql" parts
        && List.exists
             (fun m -> String_util.contains_substring joined m)
             gh_graphql_destructive_mutations)
  | _ -> false
;;

(** Combined check: returns [true] for any destructive mutation.
    Use [is_gh_dangerous_operation] for always-gated ops, or
    [is_gh_workflow_operation] for preset-dependent gating. *)
let is_gh_destructive_operation cmd =
  is_gh_workflow_operation cmd || is_gh_dangerous_operation cmd
;;
