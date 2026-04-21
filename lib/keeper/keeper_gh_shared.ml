
(* GH credential isolation — SSOT in Keeper_gh_env. *)
let with_keeper_gh_env = Keeper_gh_env.with_env

(* ================================================================ *)
(* GH entity cache (inlined from former keeper_gh_cache.ml).         *)
(* In-memory cache of valid PR/issue numbers per repo, populated     *)
(* lazily via [gh api repos/{slug}/pulls|issues?state=all] (REST,    *)
(* not GraphQL -- GraphQL has known false negatives, see board post  *)
(* p-10f3f0914beeb9e0d22f80e0b0e107a8).                              *)
(*                                                                   *)
(* Used by PR workflow handlers to reject hallucinated              *)
(* PR/issue numbers BEFORE invoking gh, returning the valid number   *)
(* list as alternatives. Thread-safe via Eio.Mutex, fail-open on     *)
(* fetch errors (returns [`Unknown] -> caller proceeds normally).    *)
(* ================================================================ *)

type entity_kind = PR | Issue

type validation_result =
  [ `Valid
  | `Invalid of int list
  | `Unknown
  ]

type task_repo_context = {
  task_id : string;
  git_root : string;
  repo_slug : string;
}

type task_repo_context_error =
  | Missing_current_task
  | Current_task_not_found of string
  | Current_task_missing_worktree of string
  | Current_task_origin_unavailable of {
      task_id : string;
      git_root : string;
    }
  | Current_task_origin_not_github of {
      task_id : string;
      git_root : string;
    }

type cache_entry = {
  numbers : int list;
  fetched_at : float;
  populated : bool;
}

let kind_path = function PR -> "pulls" | Issue -> "issues"

let cache : (string * entity_kind, cache_entry) Hashtbl.t = Hashtbl.create 8
let cache_lock = Eio.Mutex.create ()

let counter_hits = Atomic.make 0
let counter_misses = Atomic.make 0
let counter_bypasses = Atomic.make 0
let counter_fetch_errors = Atomic.make 0

let normalize_gh_command (cmd : string) : string =
  let tokens =
    cmd
    |> String.trim
    |> String.split_on_char ' '
    |> List.map String.trim
    |> List.filter (fun token -> token <> "")
  in
  let rec drop_leading_gh = function
    | token :: rest when String.lowercase_ascii token = "gh" ->
        drop_leading_gh rest
    | remaining -> remaining
  in
  String.concat " " (drop_leading_gh tokens)

let parse_numbers_from_jq_output (out : string) : int list =
  out
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         let s = String.trim line in
         if s = "" then None
         else
           match int_of_string_opt s with
           | Some n when n > 0 -> Some n
           | _ -> None)

let jq_filter = function
  | PR -> ".[] | .number"
  | Issue -> ".[] | select(.pull_request == null) | .number"

let fetch_entity_numbers ~(config : Coord.config) ~(repo_slug : string) ~(kind : entity_kind)
    : int list option
  =
  let endpoint =
    Printf.sprintf "repos/%s/%s?state=all&per_page=%d"
      repo_slug (kind_path kind) (Keeper_tool_policy.gh_cache_fetch_page_size ())
  in
  let raw =
    Printf.sprintf "gh api %s --jq %s"
      (Filename.quote endpoint)
      (Filename.quote (jq_filter kind))
  in
  let scoped = Keeper_gh_env.with_env config raw in
  let shell = Printf.sprintf "%s 2>/dev/null" scoped in
  match
    Process_eio.run_argv_with_status
      ~timeout_sec:(Keeper_tool_policy.gh_cache_fetch_timeout_sec ())
      [ "/bin/zsh"; "-lc"; shell ]
  with
  | Unix.WEXITED 0, out -> Some (parse_numbers_from_jq_output out)
  | _ ->
    Atomic.incr counter_fetch_errors;
    None

let now () = Unix.gettimeofday ()

let entry_is_fresh entry =
  entry.populated && now () -. entry.fetched_at < Keeper_tool_policy.gh_cache_ttl_sec ()

let get_or_populate_entry ~config ~repo_slug ~kind : cache_entry =
  Eio.Mutex.use_rw ~protect:true cache_lock (fun () ->
    let key = (repo_slug, kind) in
    match Hashtbl.find_opt cache key with
    | Some entry when entry_is_fresh entry -> entry
    | _ ->
      let entry =
        match fetch_entity_numbers ~config ~repo_slug ~kind with
        | Some numbers ->
          { numbers; fetched_at = now (); populated = true }
        | None ->
          { numbers = []; fetched_at = now (); populated = false }
      in
      Hashtbl.replace cache key entry;
      entry)

let validate_number ~config ~repo_slug ~kind ~number : validation_result =
  if number <= 0 then `Unknown
  else if repo_slug = "" then `Unknown
  else
    let entry = get_or_populate_entry ~config ~repo_slug ~kind in
    if not entry.populated then begin
      Atomic.incr counter_bypasses;
      `Unknown
    end
    else if List.mem number entry.numbers then begin
      Atomic.incr counter_hits;
      `Valid
    end
    else begin
      Atomic.incr counter_misses;
      `Invalid entry.numbers
    end

let invalidate_cache ~repo_slug ~kind =
  Eio.Mutex.use_rw ~protect:true cache_lock (fun () ->
    Hashtbl.remove cache (repo_slug, kind))

let cache_metrics () : (string * int) list =
  [ "hits", Atomic.get counter_hits
  ; "misses", Atomic.get counter_misses
  ; "bypasses", Atomic.get counter_bypasses
  ; "fetch_errors", Atomic.get counter_fetch_errors
  ]

(* ------------------------------------------------------------------ *)
(* Rejection history: tracks per-(repo, kind, number) rejection count  *)
(* locally in this module so that the gate can escalate its response   *)
(* on repeated hallucinations of the same number. #7199.               *)
(* ------------------------------------------------------------------ *)

let _rejection_history : (string * entity_kind * int, int) Hashtbl.t =
  Hashtbl.create 16

let record_rejection ~repo_slug ~kind ~number : int =
  let key = (repo_slug, kind, number) in
  let prev = match Hashtbl.find_opt _rejection_history key with
    | Some n -> n
    | None -> 0
  in
  let count = prev + 1 in
  Hashtbl.replace _rejection_history key count;
  count

(** Pre-compiled regex for gh CLI "not found" error messages.
    Matches case-insensitively against multiple known error phrases
    to detect hallucinated issue/PR numbers. *)
let gh_not_found_re =
  Re.compile
    (Re.alt
       [ Re.no_case (Re.str "Could not resolve")
       ; Re.no_case (Re.str "Could not find")
       ; Re.no_case (Re.str "No such issue")
       ; Re.no_case (Re.str "not found")
       ])

(** Return a hint field list when gh exits non-zero and output matches
    a known "not found" pattern, indicating a hallucinated issue/PR number. *)
let gh_not_found_hint ~(st : Unix.process_status) ~(out : string) =
  if st <> Unix.WEXITED 0 && Re.execp gh_not_found_re out
  then
    [ "hint", `String
        "The issue/PR number does not exist. Do not guess numbers. \
         Use 'issue list' or 'pr list' to find valid targets first." ]
  else []

(** gh subcommands that take a numeric PR/issue target as their first
    positional argument. We pre-validate the number against the
    the inlined gh entity cache before dispatching the subprocess.

    [view] is intentionally excluded from the cache check -- list-style
    [pr view] (with no number) is valid and we don't want to reject it. *)
let gh_pr_number_subcmds =
  [ "view"; "close"; "reopen"; "merge"; "comment"; "edit"
  ; "diff"; "checks"; "review"; "ready"; "status" ]

let gh_issue_number_subcmds =
  [ "view"; "close"; "reopen"; "comment"; "edit"
  ; "develop"; "lock"; "unlock"; "pin"; "unpin"; "transfer" ]

let gh_words (cmd : string) : string list =
  cmd
  |> String.map (function '\t' | '\r' | '\n' -> ' ' | c -> c)
  |> String.trim
  |> String.lowercase_ascii
  |> String.split_on_char ' '
  |> List.filter (fun s -> s <> "")

let gh_global_option_takes_value = function
  | "-r" | "--repo" | "--hostname" -> true
  | _ -> false

let gh_global_option_has_inline_value token =
  List.exists (fun prefix -> String.starts_with ~prefix token)
    [ "--repo="; "--hostname=" ]

let rec skip_gh_leading_global_options = function
  | [] -> []
  | token :: rest when gh_global_option_takes_value token ->
      (match rest with
       | _value :: tail -> skip_gh_leading_global_options tail
       | [] -> [])
  | token :: rest when gh_global_option_has_inline_value token ->
      skip_gh_leading_global_options rest
  | token :: rest when String.starts_with ~prefix:"-" token ->
      skip_gh_leading_global_options rest
  | parts -> parts

let rec first_gh_command_word = function
  | [] -> None
  | token :: rest when gh_global_option_takes_value token ->
      (match rest with
       | _value :: tail -> first_gh_command_word tail
       | [] -> None)
  | token :: rest when gh_global_option_has_inline_value token ->
      first_gh_command_word rest
  | token :: rest when String.starts_with ~prefix:"-" token ->
      first_gh_command_word rest
  | token :: _rest -> Some token

(** Parse a gh command string and return [Some (kind, number)] ONLY when
    the number is the immediate positional argument after the
    subcommand:

        pr <sub> <N> [flags...]
        issue <sub> <N> [flags...]

    This strict shape is deterministic -- no flag-table heuristic, no
    guessing which tokens are flag values. For the keeper-hallucination
    use case the real failures are simple "pr view 99999" strings, so
    the strict form catches them without risking false rejections on
    variants like "pr view --web 123" (where we simply fallthrough to
    normal execution).

    Returns [None] for:
      - list/create/status subcommands (no target number at all)
      - commands with flags between the subcommand and the number
      - commands whose first positional after the subcommand is not a
        positive integer (branch names, URLs, etc.)

    Examples:
      "pr view 123"             -> Some (PR, 123)
      "pr view 456 --json title" -> Some (PR, 456)
      "pr merge 789 --squash"   -> Some (PR, 789)
      "issue comment 42 --body hi" -> Some (Issue, 42)
      "pr view my-branch"       -> None  (not an integer)
      "pr view --web 123"       -> None  (flag precedes number)
      "pr list --state open"    -> None
      "pr create --title foo"   -> None *)
let extract_gh_target_number (cmd : string)
    : (entity_kind * int) option
  =
  let parts =
    cmd
    |> normalize_gh_command
    |> gh_words
    |> skip_gh_leading_global_options
  in
  let positive_int s =
    match int_of_string_opt s with
    | Some n when n > 0 -> Some n
    | _ -> None
  in
  match parts with
  | "pr" :: sub :: num_str :: _
    when List.mem (String.lowercase_ascii sub) gh_pr_number_subcmds ->
    Option.map (fun n -> PR, n) (positive_int num_str)
  | "issue" :: sub :: num_str :: _
    when List.mem (String.lowercase_ascii sub) gh_issue_number_subcmds ->
    Option.map (fun n -> Issue, n) (positive_int num_str)
  | _ -> None

(** Return the kind whose cached number list should be invalidated after
    this command runs successfully. Covers creation (new number appears),
    state transitions that close/reopen (membership changes under
    [state=all] is unchanged, but we still invalidate to resync state
    filters used elsewhere), and merges. *)
let gh_mutates_entity (cmd : string) : entity_kind option =
  let parts =
    cmd
    |> normalize_gh_command
    |> gh_words
    |> skip_gh_leading_global_options
  in
  match parts with
  | "pr" :: sub :: _
    when List.mem sub [ "create"; "close"; "reopen"; "merge"; "ready"; "edit" ] ->
    Some PR
  | "issue" :: sub :: _
    when List.mem sub [ "create"; "close"; "reopen"; "edit"; "transfer"; "delete" ] ->
    Some Issue
  | _ -> None

(** Deterministic blocklist for obviously destructive or credential-sensitive
    gh commands. Unlike prefix matching on the raw string, this ignores
    leading global options before inspecting the command group/action pair. *)
let gh_dangerous_command (cmd : string) : string option =
  match cmd |> normalize_gh_command |> gh_words |> skip_gh_leading_global_options with
  | "repo" :: rest ->
      begin match first_gh_command_word rest with
      | Some "delete" -> Some "repo delete"
      | Some "archive" -> Some "repo archive"
      | Some "transfer" -> Some "repo transfer"
      | _ -> None
      end
  | "auth" :: rest ->
      begin match first_gh_command_word rest with
      | Some "logout" -> Some "auth logout"
      | Some "token" -> Some "auth token"
      | _ -> None
      end
  | "secret" :: rest ->
      begin match first_gh_command_word rest with
      | Some "set" -> Some "secret set"
      | Some "delete" -> Some "secret delete"
      | _ -> None
      end
  | "ssh-key" :: rest ->
      begin match first_gh_command_word rest with
      | Some "delete" -> Some "ssh-key delete"
      | _ -> None
      end
  | _ -> None

(** Truncate gh output to prevent context explosion.
    65KB responses were observed causing 300s timeout via token overflow.
    Retained for .mli backward compatibility; runtime limit comes from
    [gh_cache.max_output_bytes] in tool_policy.toml. *)
let max_gh_output_bytes = 8192

let truncate_gh_output (out : string) : string * (string * Yojson.Safe.t) list =
  let max_bytes = Keeper_tool_policy.gh_cache_max_output_bytes () in
  let len = String.length out in
  if len <= max_bytes then out, []
  else
    let banner shown_bytes =
      Printf.sprintf
        "\n... [truncated: %d bytes total, showing first %d]"
        len shown_bytes
    in
    let render prefix =
      let shown_bytes = String.length prefix in
      let banner = banner shown_bytes in
      prefix ^ banner, shown_bytes, String.length banner
    in
    let rec fit budget =
      let prefix = Keeper_config.utf8_safe_prefix_bytes out ~max_bytes:budget in
      let rendered, shown_bytes, banner_len = render prefix in
      if String.length rendered <= max_bytes || budget = 0
      then rendered, shown_bytes
      else
        let next_budget = max 0 (max_bytes - banner_len) in
        if next_budget >= budget
        then rendered, shown_bytes
        else fit next_budget
    in
    let rendered, shown_bytes = fit max_bytes in
    rendered,
    [ "truncated", `Bool true;
      "original_bytes", `Int len;
      "shown_bytes", `Int shown_bytes ]

(** Regex matching --repo owner/name, --repo=owner/name, or -R owner/name in gh CLI commands. *)
let repo_flag_re =
  Re.compile
    (Re.seq
       [ Re.alt [ Re.str "--repo"; Re.str "-R" ]
       ; Re.alt [ Re.rep1 Re.blank; Re.str "=" ]
       ; Re.rep1 (Re.compl [ Re.blank ])
       ])

let has_repo_flag cmd =
  Re.execp repo_flag_re cmd

let is_valid_repo_segment segment =
  segment <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' -> true
         | _ -> false)
       segment

let validate_repo_slug raw =
  let slug = String.trim raw in
  match String.split_on_char '/' slug with
  | [ owner; repo ] when is_valid_repo_segment owner && is_valid_repo_segment repo ->
      Ok (owner ^ "/" ^ repo)
  | _ ->
      Error
        "repo must be an owner/repo slug without spaces or extra flags."

let rec strip_repo_flags_from_args = function
  | [] -> []
  | "--repo" :: _value :: rest
  | "-R" :: _value :: rest ->
      strip_repo_flags_from_args rest
  | arg :: rest when String.starts_with ~prefix:"--repo=" arg ->
      strip_repo_flags_from_args rest
  | arg :: rest ->
      arg :: strip_repo_flags_from_args rest

let args_have_repo_flag args =
  List.exists
    (fun arg -> arg = "--repo" || arg = "-R" || String.starts_with ~prefix:"--repo=" arg)
    args

let inject_repo_flag_args ~repo_slug args =
  strip_repo_flags_from_args args @ [ "--repo"; repo_slug ]

let run_argv_first_line_unix ~(prog : string) ~(argv : string array) : string option =
  try
    match
      With_process.with_process_args_in prog argv (fun ic ->
        With_process.drain_lines ic
        |> List.map String.trim
        |> List.find_opt (fun line -> line <> ""))
    with
    | line, Unix.WEXITED 0 -> line
    | _ -> None
  with
  | Unix.Unix_error _ | Sys_error _ -> None

let inject_repo_flag_cmd ~repo_slug cmd =
  let normalized = normalize_gh_command cmd in
  if has_repo_flag normalized
  then normalized
  else String.trim (normalized ^ " --repo " ^ repo_slug)

let repo_slug_of_remote_url url =
  let url = String.trim url in
  let strip_git s =
    if String.length s > 4 && String.sub s (String.length s - 4) 4 = ".git"
    then String.sub s 0 (String.length s - 4)
    else s
  in
  match String.split_on_char ':' url with
  | [ _; path ] when String.contains url '@' ->
      validate_repo_slug (strip_git path) |> Result.to_option
  | _ ->
      let parts = String.split_on_char '/' url in
      let n = List.length parts in
      if n >= 2
      then
        let owner = List.nth parts (n - 2) in
        let repo = strip_git (List.nth parts (n - 1)) in
        validate_repo_slug (owner ^ "/" ^ repo) |> Result.to_option
      else
        None

(** Cached owner/repo slug from git remote origin. *)
let _repo_slug_cache : string option option ref = ref None

let repo_slug_of_git_config ~git_root =
  let config_path = Filename.concat git_root ".git/config" in
  if not (Sys.file_exists config_path)
  then None
  else
    let ic = open_in_bin config_path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop ~in_origin =
          match input_line ic with
          | line ->
            let trimmed = String.trim line in
            if trimmed = "" || String.starts_with ~prefix:";" trimmed
            then loop ~in_origin
            else if String.starts_with ~prefix:"[" trimmed
            then
              loop
                ~in_origin:(String.equal trimmed "[remote \"origin\"]")
            else if in_origin
                    && (String.starts_with ~prefix:"url = " trimmed
                        || String.starts_with ~prefix:"url=" trimmed)
            then
              let value =
                if String.starts_with ~prefix:"url = " trimmed
                then String.sub trimmed 6 (String.length trimmed - 6)
                else String.sub trimmed 4 (String.length trimmed - 4)
              in
              repo_slug_of_remote_url value
            else loop ~in_origin
          | exception End_of_file -> None
        in
        loop ~in_origin:false)

let repo_slug_of_git_root ~git_root =
  match repo_slug_of_git_config ~git_root with
  | Some slug -> Some slug
  | None ->
    (match
       Process_eio.run_argv_with_status ~cwd:git_root ~timeout_sec:5.0
         [ "git"; "remote"; "get-url"; "origin" ]
     with
     | Unix.WEXITED 0, url -> repo_slug_of_remote_url url
     | _ -> None)

let project_repo_slug () : string option =
  match !_repo_slug_cache with
  | Some cached -> cached
  | None ->
      let slug =
        repo_slug_of_git_root ~git_root:(Sys.getcwd ())
      in
      _repo_slug_cache := Some slug;
      slug

let resolve_task_repo_context
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
  : (task_repo_context, task_repo_context_error) result
  =
  match meta.current_task_id with
  | None -> Error Missing_current_task
  | Some current_task_id ->
    let task_id = Keeper_id.Task_id.to_string current_task_id in
    match
         Coord_query.get_tasks_safe config
      |> List.find_opt (fun (task : Types.task) -> String.equal task.id task_id)
    with
    | None -> Error (Current_task_not_found task_id)
    | Some task ->
      match task.worktree with
      | None -> Error (Current_task_missing_worktree task_id)
      | Some wt ->
        let git_root = wt.git_root in
        (match
           run_argv_first_line_unix
             ~prog:"git"
             ~argv:[| "git"; "-C"; git_root; "remote"; "get-url"; "origin" |]
         with
         | Some origin_url ->
           let origin_url = String.trim origin_url in
           (match Tool_code_write.extract_github_org_repo origin_url with
            | Some repo_slug -> Ok { task_id; git_root; repo_slug }
            | None ->
              Error
                (Current_task_origin_not_github
                   { task_id; git_root }))
         | None ->
           Error
             (Current_task_origin_unavailable
                { task_id; git_root }))

(** Replace a wrong --repo/-R slug in cmd with the correct one.
    Returns (corrected_cmd, was_corrected). *)
let correct_repo_flag ~(correct_slug : string) (cmd : string) : string * bool =
  if Re.execp repo_flag_re cmd then
    let corrected =
      Re.replace repo_flag_re
        ~f:(fun g ->
          let matched = Re.Group.get g 0 in
          let flag = if String.length matched > 2 && matched.[0] = '-' && matched.[1] = 'R'
                     then "-R" else "--repo" in
          flag ^ " " ^ correct_slug)
        cmd
    in
    (corrected, corrected <> cmd)
  else (cmd, false)
