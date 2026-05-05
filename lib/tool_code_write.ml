module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Code Write Tools — File write, edit, delete, shell, git for keeper agents.

    Security model:
    - Write operations restricted to allowed sandboxes
      (.worktrees/ checkouts and keeper playground clones)
    - Shell commands restricted to allowlist
    - Git push to main/master blocked
    - Git clone restricted to allowed GitHub orgs (config/tool_policy.toml)
    - File size limit: 1MB for writes
    - Binary file extension check inherited from Tool_code

    @since 2.128.0 *)

open Masc_domain
open Tool_args

type context = {
  config : Coord.config;
  agent_name : string;
}

type tool_result = bool * string

let max_write_size = 1024 * 1024  (* 1 MiB *)

let normalize_dir_prefix path =
  Tool_code.normalize_path path ^ "/"

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> not (String.equal s ""))

(* Shell command allowlist *)
let allowed_shell_commands = [
  "dune"; "make"; "npm"; "npx"; "node";
  "git"; "ls"; "cat"; "head"; "tail"; "wc";
  "rg"; "find"; "diff"; "patch"; "mkdir";
  "opam"; "ocamlfind"; "tsc";
]

let validate_code_shell_command (command : string) : (unit, string) Result.t =
  Worker_dev_tools.validate_command_coding_with_allowlist
    ~allow_pipes:true
    ~allowed_commands:allowed_shell_commands
    command
  |> Result.map_error Worker_dev_tools.block_reason_to_string

let git_common_root path =
  try
    match
      Process_eio.run_argv_with_status
        ~timeout_sec:5.0
        [ "git"; "-C"; path; "rev-parse"; "--git-common-dir" ]
    with
    | Unix.WEXITED 0, output ->
      (match first_nonempty_line output with
       | None -> None
       | Some git_common_dir ->
         let git_common_dir =
           if Filename.is_relative git_common_dir
           then Filename.concat path git_common_dir
           else git_common_dir
         in
         Some (Tool_code.normalize_path (Filename.dirname git_common_dir)))
    | _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Unix.Unix_error _ -> None
  | Sys_error _ -> None

let dedupe_keep_order paths =
  let seen = Hashtbl.create (List.length paths) in
  List.filter
    (fun path ->
      if Hashtbl.mem seen path then false
      else (
        Hashtbl.replace seen path ();
        true))
    paths

let allowed_worktree_prefixes config =
  [ git_common_root config.Coord.base_path;
    git_common_root (Sys.getcwd ()) ]
  |> List.filter_map (fun root -> root)
  |> dedupe_keep_order
  |> List.map (fun root -> normalize_dir_prefix (Filename.concat root ".worktrees"))

(* Security: Validate path is within an allowed writable sandbox.
   Uses canonical paths from Tool_code.validate_path — already normalized.
   Worktree paths are anchored to actual git common roots so a nested
   "/.worktrees/" segment elsewhere in the tree is not accepted.

   Playground writes are gated per-agent (#6527 iter 6): the caller
   must only be allowed to write inside its own
   [.masc/playground/<agent_name>/] bundle. This prevents one agent
   from mutating another agent's playground via the shared
   `masc_code_*` dispatch. Server-wide `.worktrees/` remains allowed
   so legacy server operations that need to touch repo worktrees
   continue to work. *)
let validate_writable_path ~(agent_name : string) config path =
  let path = Tool_code.normalize_agent_relative_path ~config ~agent_name path in
  match Tool_code.validate_path config path with
  | Error e -> Error e
  | Ok canonical_path ->
    let worktree_prefixes = allowed_worktree_prefixes config in
    let agent_playground_prefix =
      normalize_dir_prefix
        (Filename.concat config.Coord.base_path
           (Keeper_alerting_path.playground_path_of_keeper agent_name))
    in
    if List.exists
         (fun prefix -> String.starts_with ~prefix canonical_path)
         worktree_prefixes
       || String.starts_with ~prefix:agent_playground_prefix canonical_path then
      Ok canonical_path
    else
      Error (System (System_error.IoError (Printf.sprintf
        "Write restricted to allowed sandboxes for agent %s. \
         Expected path prefix: %s (or /.worktrees/ for server ops). \
         Got: %s. Cross-agent playground writes are blocked — write \
         under your own playground only. Call masc_status if you are \
         unsure of your agent_name."
        agent_name
        agent_playground_prefix
        canonical_path)))

(* Issue #8522: Variant SSOT for git action.  Adding a constructor
   forces compilation in [git_action_to_string] AND extends
   [valid_git_action_strings]; the schema enum below derives from
   the SSOT, the allowlist [allowed_git_actions] is the SSOT (no
   separate hand-list), and downstream inline checks pattern-match
   on the Variant for push-force and clone special paths. *)
type git_action =
  | Add
  | Commit
  | Push
  | Diff
  | Status
  | Log
  | Branch
  | Checkout
  | Stash
  | Fetch
  | Clone

let git_action_to_string = function
  | Add -> "add"
  | Commit -> "commit"
  | Push -> "push"
  | Diff -> "diff"
  | Status -> "status"
  | Log -> "log"
  | Branch -> "branch"
  | Checkout -> "checkout"
  | Stash -> "stash"
  | Fetch -> "fetch"
  | Clone -> "clone"

let git_action_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "add" -> Some Add
  | "commit" -> Some Commit
  | "push" -> Some Push
  | "diff" -> Some Diff
  | "status" -> Some Status
  | "log" -> Some Log
  | "branch" -> Some Branch
  | "checkout" -> Some Checkout
  | "stash" -> Some Stash
  | "fetch" -> Some Fetch
  | "clone" -> Some Clone
  | _ -> None

let all_git_actions =
  [ Add; Commit; Push; Diff; Status; Log; Branch; Checkout; Stash; Fetch; Clone ]

let valid_git_action_strings = List.map git_action_to_string all_git_actions

(* Allowlist re-uses the SSOT — kept as the prior name for any other
   call sites that grep for it. *)
let allowed_git_actions = valid_git_action_strings

let max_output_bytes = 10 * 1024
let max_output_label = "10KB"

let truncate_output s =
  if String.length s > max_output_bytes then
    String.sub s 0 max_output_bytes ^ "\n... (truncated)"
  else s

(* ── Git clone config (cycle-free) ──────────────────────────────── *)

(* Loads tool_policy.toml config directly via Keeper_tool_policy_config
   to avoid circular dependency with Keeper_tool_policy (which imports
   Tool_code_write.schemas for schema assembly).  Enforcement paths must
   distinguish "loaded with an empty allowlist" from "policy unavailable". *)
type policy_config_cache_entry = {
  base_path : string;
  env_config_dir : string option;
  result : (Keeper_tool_policy_config.t, string) Result.t;
}

let _policy_config_cache : policy_config_cache_entry option ref = ref None

(** Reset internal config cache — for test isolation only. *)
let reset_policy_config_cache () = _policy_config_cache := None

let observe_policy_config_load_error ~base_path ~env_config_dir msg =
  let config_dir =
    Option.value ~default:"<resolved-from-base-path>" env_config_dir
  in
  Prometheus.inc_counter Prometheus.metric_keeper_tool_policy_failures
    ~labels:[("site", "tool_code_write_load_failed"); ("preset", "n/a")]
    ();
  Log.Keeper.warn
    "tool_code_write: tool_policy.toml load failed; git clone policy is \
     unavailable (base_path=%S config_dir=%S): %s"
    base_path config_dir msg

let get_policy_config_result ~base_path =
  let env_config_dir = Env_config.config_dir_opt () in
  match !_policy_config_cache with
  | Some { base_path = cached_base_path; env_config_dir = cached_env; result }
    when String.equal cached_base_path base_path && Option.equal String.equal cached_env env_config_dir ->
    result
  | _ ->
    let result = Keeper_tool_policy_config.load ~base_path in
    (match result with
     | Ok _ -> ()
     | Error msg ->
         observe_policy_config_load_error ~base_path ~env_config_dir msg);
    _policy_config_cache := Some { base_path; env_config_dir; result };
    result

let get_policy_config ~base_path =
  match get_policy_config_result ~base_path with
  | Ok cfg -> Some cfg
  | Error _ -> None

let load_clone_allowed_orgs ~base_path =
  match get_policy_config ~base_path with
  | Some cfg -> Keeper_tool_policy_config.git_clone_allowed_orgs cfg
  | None ->
    []

let valid_github_org_slug org =
  let valid_org_char c =
    (match c with 'a'..'z' | '0'..'9' | '-' -> true | _ -> false)
  in
  not (String.equal org "") && Stdlib.Seq.for_all valid_org_char (Stdlib.String.to_seq org)

(** Extract GitHub org from clone URL (case-normalized to lowercase).
    Strict matching: URL must start with an exact known prefix to prevent
    authority spoofing (e.g. github.com.evil.com).
    Handles:
    - [https://github.com/ORG/repo\[.git\]]
    - [git@github.com:ORG/repo\[.git\]]
    - [ssh://git@github.com/ORG/repo\[.git\]] *)
let extract_github_org url =
  let lc = String.lowercase_ascii (String.trim url) in
  let prefixes = [
    "https://github.com/";
    "git@github.com:";
    "ssh://git@github.com/";
  ] in
  let after_prefix =
    List.find_map (fun prefix ->
      if String.starts_with ~prefix lc then
        let len = String.length prefix in
        Some (String.sub lc len (String.length lc - len))
      else None
    ) prefixes
  in
  match after_prefix with
  | None -> None
  | Some rest ->
    (* rest must be "org/repo[.git]" — reject if org contains suspicious chars *)
    match String.index_opt rest '/' with
    | None -> None
    | Some idx ->
      let org = String.sub rest 0 idx in
      if not (valid_github_org_slug org) then
        None
      else
        Some org

(** Extract "org/repo" from a GitHub clone URL (lowercase, .git and trailing
    slash stripped). Returns exactly two path segments or None. *)
let extract_github_org_repo url =
  let lc = String.lowercase_ascii (String.trim url) in
  let prefixes = [
    "https://github.com/";
    "git@github.com:";
    "ssh://git@github.com/";
  ] in
  let after_prefix =
    List.find_map (fun prefix ->
      if String.starts_with ~prefix lc then
        Some (String.sub lc (String.length prefix)
                (String.length lc - String.length prefix))
      else None
    ) prefixes
  in
  match after_prefix with
  | None -> None
  | Some rest ->
    (* Strip trailing slash, then .git suffix *)
    let rest =
      if String.ends_with ~suffix:"/" rest
      then String.sub rest 0 (String.length rest - 1)
      else rest
    in
    let stripped =
      if String.ends_with ~suffix:".git" rest
      then String.sub rest 0 (String.length rest - 4)
      else rest
    in
    (* Validate exactly "org/repo" — two segments, no deeper paths *)
    match String.split_on_char '/' stripped with
    | [org; repo] when valid_github_org_slug org && not (String.equal repo "") ->
      Some (org ^ "/" ^ repo)
    | _ -> None

let canonical_github_https_clone_url url =
  match extract_github_org_repo url with
  | Some slug -> Some ("https://github.com/" ^ slug ^ ".git")
  | None -> None

let normalize_github_clone_url url =
  match canonical_github_https_clone_url url with
  | Some normalized -> normalized
  | None -> url

let load_clone_denied_repos ~base_path =
  match get_policy_config ~base_path with
  | Some cfg -> Keeper_tool_policy_config.git_clone_denied_repos cfg
  | None -> []

let validate_clone_url ~base_path url =
  match get_policy_config_result ~base_path with
  | Error msg ->
    Error (Printf.sprintf "Git clone policy unavailable: %s" msg)
  | Ok cfg ->
    let allowed = Keeper_tool_policy_config.git_clone_allowed_orgs cfg in
    let denied = Keeper_tool_policy_config.git_clone_denied_repos cfg in
    let allowed_lc = List.map String.lowercase_ascii allowed in
    let denied_lc = List.map String.lowercase_ascii denied in
    match extract_github_org_repo url with
    | None ->
      Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)
    | Some org_repo ->
      if List.mem org_repo denied_lc then
        Error (Printf.sprintf "Repository '%s' is in the denied list" org_repo)
      else
        match String.split_on_char '/' org_repo with
        | _org :: _ when Stdlib.List.length allowed_lc = 0 ->
          (* Explicit empty allowed_orgs means "any supported GitHub org",
             still bounded by URL parsing and denied_repos. *)
          Ok ()
        | org :: _ when List.mem org allowed_lc ->
          Ok ()
        | org :: _ ->
          Error
            (Printf.sprintf
               "GitHub org '%s' not in allowed list: %s. Use the actual GitHub owner from the clone URL; do not infer an org from local workspace path segments."
               org (String.concat ", " allowed))
        | [] ->
          Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)

(** Validate cwd for clone: allows .worktrees/ itself (not just subdirs)
    and THIS agent's own .masc/playground/<agent_name>/repos/ directory.

    #6527 iter 6 scoped this per-agent so agent A cannot drop a clone
    into agent B's playground/repos/ via masc_code_git action=clone. *)
let validate_clone_cwd ~(agent_name : string) config cwd =
  let cwd = Tool_code.normalize_agent_relative_path ~config ~agent_name cwd in
  match Tool_code.validate_path config cwd with
  | Error e -> Error e
  | Ok canonical_path ->
    match Coord_git.git_root ~base_path:config.Coord.base_path with
    | None -> Error (System (System_error.IoError "Not in a git repository"))
    | Some root ->
      let worktree_prefix = Tool_code.normalize_path
        (Filename.concat root ".worktrees") in
      let agent_playground_prefix = Tool_code.normalize_path
        (Filename.concat root
           (Keeper_alerting_path.playground_path_of_keeper agent_name)) in
      let in_worktrees =
        String.equal canonical_path worktree_prefix ||
        String.starts_with ~prefix:(worktree_prefix ^ "/") canonical_path
      in
      let in_agent_playground_repos =
        (* Match <agent_playground_prefix>/repos or subdirs thereof.
           [playground_path_of_keeper] already ends with "/", and the
           canonical normalisation strips trailing slashes, so we strip
           the trailing slash before prefix matching. *)
        let prefix_no_slash =
          if String.length agent_playground_prefix > 0
             && Char.equal agent_playground_prefix.[String.length agent_playground_prefix - 1] '/'
          then String.sub agent_playground_prefix 0
                 (String.length agent_playground_prefix - 1)
          else agent_playground_prefix
        in
        String.equal canonical_path (Stdlib.Filename.concat prefix_no_slash "repos")
        || String.starts_with
             ~prefix:(Filename.concat prefix_no_slash "repos/")
             canonical_path
      in
      if in_worktrees || in_agent_playground_repos then
        Ok canonical_path
      else
        Error (System (System_error.IoError (Printf.sprintf
          "Clone restricted to /.worktrees/ or this agent's own \
           %srepos/ (got: %s). Cross-agent playground clones are blocked \
           — clone into %srepos/<repo-name> instead. Call masc_status \
           if you are unsure of your agent_name (currently %s)."
          agent_playground_prefix
          canonical_path
          agent_playground_prefix
          agent_name)))

(* Handler: masc_code_write — Create or overwrite a file *)
let handle_code_write ctx args =
  let path = get_string args "path" "" in
  let content = get_string args "content" "" in
  let create_dirs = get_bool args "create_dirs" false in

  if String.equal path "" then
    (false, "path parameter required")
  else if String.length content > max_write_size then
    (false, Printf.sprintf "Content too large: %d bytes (max: %d)"
       (String.length content) max_write_size)
  else if Tool_code.is_binary_file path then
    (false, "Binary file extension not allowed for write")
  else begin
    match validate_writable_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> (false, Masc_domain.masc_error_to_string e)
    | Ok abs_path ->
      try
        if create_dirs then begin
          let dir = Filename.dirname abs_path in
          Fs_compat.mkdir_p dir
        end;
        Fs_compat.save_file abs_path content;
        let response = `Assoc [
          ("status", `String "ok");
          ("path", `String path);
          ("bytes_written", `Int (String.length content));
          ("agent", `String ctx.agent_name);
        ] in
        (true, Yojson.Safe.to_string response)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        (false, Printf.sprintf "Write failed: %s" (Stdlib.Printexc.to_string exn))
  end

(* Handler: masc_code_edit — Replace old_string with new_string in a file *)
let handle_code_edit ctx args =
  let path = get_string args "path" "" in
  let old_string = get_string args "old_string" "" in
  let new_string = get_string args "new_string" "" in
  let replace_all = get_bool args "replace_all" false in

  if String.equal path "" then (false, "path parameter required")
  else if String.equal old_string "" then (false, "old_string parameter required")
  else if String.equal old_string new_string then (false, "old_string and new_string are identical")
  else begin
    match validate_writable_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> (false, Masc_domain.masc_error_to_string e)
    | Ok abs_path ->
      if not (Sys.file_exists abs_path) then
        (false, Printf.sprintf "File not found: %s" path)
      else begin
        try
          let content = Fs_compat.load_file abs_path in
          (* Count occurrences *)
          let count = ref 0 in
          let pos = ref 0 in
          let old_len = String.length old_string in
          while !pos <= String.length content - old_len do
            if String.equal (Stdlib.String.sub content !pos old_len) old_string then begin
              Stdlib.incr count;
              pos := !pos + old_len
            end else
              Stdlib.incr pos
          done;

          if !count = 0 then
            (* Exact match failed. Look for the first line of old_string
               (trimmed) inside the file and surface up to 3 matching
               lines — the LLM almost always got whitespace / indent /
               trailing newline wrong, and showing the real line(s) it
               meant to target lets the next attempt succeed without
               re-reading the whole file.

               Evidence: 2026-04-16 /loop iter 3 — 17/19 masc_code_edit
               failures are "old_string not found", single root cause. *)
            let first_line =
              match String.index_opt old_string '\n' with
              | Some i -> String.sub old_string 0 i
              | None -> old_string
            in
            let needle = String.trim first_line in
            if String.length needle < 8 then
              (false, "old_string not found in file")
            else
              let matches =
                String.split_on_char '\n' content
                |> List.filter (fun line ->
                     String_util.contains_substring line needle)
                |> List.filteri (fun i _ -> i < 3)
              in
              let hint =
                match matches with
                | [] -> ""
                | samples ->
                  "\nLines in file matching the first trimmed line of \
                   old_string (check whitespace/indent):\n  "
                  ^ String.concat "\n  " samples
              in
              (false, "old_string not found in file." ^ hint)
          else if !count > 1 && not replace_all then
            (false, Printf.sprintf
               "old_string found %d times. Use replace_all=true or provide more context"
               !count)
          else begin
            (* Perform replacement *)
            let new_content =
              if replace_all then begin
                let buf = Buffer.create (String.length content) in
                let i = ref 0 in
                while !i <= String.length content - old_len do
                  if String.equal (Stdlib.String.sub content !i old_len) old_string then begin
                    Buffer.add_string buf new_string;
                    i := !i + old_len
                  end else begin
                    Buffer.add_char buf content.[!i];
                    Stdlib.incr i
                  end
                done;
                (* Add remaining characters *)
                if !i < String.length content then
                  Buffer.add_string buf
                    (String.sub content !i (String.length content - !i));
                Buffer.contents buf
              end else begin
                (* Replace first occurrence only *)
                let idx = ref (-1) in
                let i = ref 0 in
                while !idx = -1 && !i <= String.length content - old_len do
                  if String.equal (Stdlib.String.sub content !i old_len) old_string then
                    idx := !i
                  else
                    Stdlib.incr i
                done;
                match !idx with
                | -1 -> content (* should not happen *)
                | pos ->
                  String.sub content 0 pos
                  ^ new_string
                  ^ String.sub content (pos + old_len)
                      (String.length content - pos - old_len)
              end
            in
            Fs_compat.save_file abs_path new_content;
            let response = `Assoc [
              ("status", `String "ok");
              ("path", `String path);
              ("replacements", `Int !count);
              ("agent", `String ctx.agent_name);
            ] in
            (true, Yojson.Safe.to_string response)
          end
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          (false, Printf.sprintf "Edit failed: %s" (Stdlib.Printexc.to_string exn))
      end
  end

(* Handler: masc_code_delete — Delete a file *)
let handle_code_delete ctx args =
  let path = get_string args "path" "" in

  if String.equal path "" then (false, "path parameter required")
  else begin
    match validate_writable_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> (false, Masc_domain.masc_error_to_string e)
    | Ok abs_path ->
      if not (Sys.file_exists abs_path) then
        (false, Printf.sprintf "File not found: %s" path)
      else if Sys.is_directory abs_path then
        (false, "Cannot delete directories, only files")
      else begin
        try
          Sys.remove abs_path;
          let response = `Assoc [
            ("status", `String "ok");
            ("path", `String path);
            ("agent", `String ctx.agent_name);
          ] in
          (true, Yojson.Safe.to_string response)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          (false, Printf.sprintf "Delete failed: %s" (Stdlib.Printexc.to_string exn))
      end
  end

(* Handler: masc_code_shell — Bounded shell execution *)
let handle_code_shell ctx args =
  let command = get_string args "command" "" in
  let cwd = get_string args "cwd" "" in
  let timeout = get_int args "timeout" 30 in

  if String.equal command "" then (false, "command parameter required")
  else
    match validate_code_shell_command command with
    | Error reason -> (false, reason)
    | Ok () ->
        (* Validate cwd if provided *)
        let cwd_result =
          if String.equal cwd "" then Ok None
          else
            match validate_writable_path ~agent_name:ctx.agent_name ctx.config cwd with
            | Ok abs_cwd -> Ok (Some abs_cwd)
            | Error e -> Error e
        in
        (match cwd_result with
         | Error e -> (false, Masc_domain.masc_error_to_string e)
         | Ok cwd_opt ->
             let safe_timeout = Float.of_int (max 5 (min 120 timeout)) in
             let cmd_parts = ["sh"; "-c"; command] in
             let full_cmd =
               match cwd_opt with
               | None -> cmd_parts
               | Some dir ->
                   [ "sh"; "-c"; Printf.sprintf "cd %s && %s"
                       (Filename.quote dir) command ]
             in
             match Process_eio.run_argv_with_status ~timeout_sec:safe_timeout full_cmd with
             | Unix.WEXITED code, output ->
                 let response = `Assoc [
                   ("status", `String (if code = 0 then "ok" else "error"));
                   ("exit_code", `Int code);
                   ("output", `String (truncate_output output));
                   ("command", `String command);
                   ("agent", `String ctx.agent_name);
                 ] in
                 (code = 0, Yojson.Safe.pretty_to_string response)
             | _, output ->
                 (false, Printf.sprintf "Command failed: %s" (truncate_output output)))

(* Handler: masc_code_git — Git operations *)
let handle_code_git ctx args =
  let action = get_string args "action" "" in
  let git_args = match args with
    | `Assoc fields ->
      (match List.assoc_opt "args" fields with
       | Some (`List l) ->
         List.filter_map (function `String s -> Some s | _ -> None) l
       | _ -> [])
    | _ -> []
  in
  let cwd = get_string args "cwd" "" in

  if String.equal action "" then (false, "action parameter required")
  else if not (List.mem action allowed_git_actions) then
    (false, Printf.sprintf "Git action '%s' not allowed. Allowed: %s"
       action (String.concat ", " allowed_git_actions))
  else if String.equal action "clone" then begin
    (* Clone: validate org allowlist + cwd within .worktrees/.
       Block all flag-like args to prevent --upload-pack injection (CVE-like). *)
    let url = match git_args with url :: _ -> url | [] -> "" in
    let has_flag_args = List.exists (fun a -> String.length a > 0 && Char.equal a.[0] '-') git_args in
    if String.equal url "" then
      (false, "clone requires a repository URL as first argument")
    else if has_flag_args then
      (false, "clone does not accept flags (security: --upload-pack injection blocked)")
    else if String.equal cwd "" then
      (false, "cwd parameter required for clone")
    else
      match validate_clone_url ~base_path:ctx.config.Coord.base_path url with
      | Error msg -> (false, msg)
      | Ok () ->
        match validate_clone_cwd ~agent_name:ctx.agent_name ctx.config cwd with
        | Error e -> (false, Masc_domain.masc_error_to_string e)
        | Ok abs_cwd ->
          let clone_url = normalize_github_clone_url url in
          (* Only pass the validated URL — no extra args allowed.
             Depth and timeout are config-driven via [git_clone] in tool_policy.toml. *)
          let depth = match get_policy_config ~base_path:ctx.config.Coord.base_path with
            | Some cfg -> Keeper_tool_policy_config.clone_depth cfg
            | None -> 0
          in
          let depth_flag =
            if depth > 0 then Printf.sprintf " --depth %d" depth else ""
          in
          let timeout = match get_policy_config ~base_path:ctx.config.Coord.base_path with
            | Some cfg -> Keeper_tool_policy_config.clone_timeout_sec cfg
            | None -> 120.0
          in
          let cmd = ["sh"; "-c";
                     Printf.sprintf "cd %s && git clone%s %s"
                       (Filename.quote abs_cwd)
                       depth_flag
                       (Filename.quote clone_url)]
          in
          match Process_eio.run_argv_with_status ~timeout_sec:timeout cmd with
          | Unix.WEXITED code, output ->
            let response = `Assoc [
              ("status", `String (if code = 0 then "ok" else "error"));
              ("exit_code", `Int code);
              ("output", `String (truncate_output output));
              ("action", `String "clone");
              ("url", `String url);
              ("agent", `String ctx.agent_name);
            ] in
            (code = 0, Yojson.Safe.pretty_to_string response)
          | _, output ->
            (false, Printf.sprintf "Git clone failed: %s" (truncate_output output))
  end
  else begin
    (* Non-clone actions: existing validation *)
    let is_dangerous =
      (String.equal action "push" && List.mem "--force" git_args) ||
      (String.equal action "push" && List.mem "-f" git_args) ||
      (String.equal action "push" && List.exists (fun a ->
         String.equal a "main" || String.equal a "master" || String.equal a "origin/main" || String.equal a "origin/master"
       ) git_args) ||
      (String.equal action "checkout" && List.mem "--" git_args &&
       List.mem "." git_args)
    in
    if is_dangerous then
      (false, "Dangerous git operation blocked (force push, main push, or checkout .)")
    else begin
      let cwd_result =
        if String.equal cwd "" then (false, "cwd parameter required for git operations") |> fun (ok, msg) ->
          if ok then Ok None else Error (System (System_error.IoError msg))
        else match validate_writable_path ~agent_name:ctx.agent_name ctx.config cwd with
          | Ok abs_cwd -> Ok (Some abs_cwd)
          | Error e -> Error e
      in
      match cwd_result with
      | Error e -> (false, Masc_domain.masc_error_to_string e)
      | Ok cwd_opt ->
        let dir = match cwd_opt with Some d -> d | None -> "." in
        let cmd = ["sh"; "-c";
                   Printf.sprintf "cd %s && git %s %s"
                     (Filename.quote dir)
                     action
                     (String.concat " " (List.map Filename.quote git_args))]
        in
        let env_opt =
          if String.equal action "commit" then
            Some (Keeper_identity.git_env_for_keeper ~keeper_name:ctx.agent_name)
          else None
        in
        match Process_eio.run_argv_with_status ~timeout_sec:30.0 ?env:env_opt cmd with
        | Unix.WEXITED code, output ->
          let response = `Assoc [
            ("status", `String (if code = 0 then "ok" else "error"));
            ("exit_code", `Int code);
            ("output", `String (truncate_output output));
            ("action", `String action);
            ("agent", `String ctx.agent_name);
          ] in
          (code = 0, Yojson.Safe.pretty_to_string response)
        | _, output ->
          (false, Printf.sprintf "Git command failed: %s" (truncate_output output))
    end
  end

(* Dispatch *)
let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_code_write" -> Some (handle_code_write ctx args)
  | "masc_code_edit" -> Some (handle_code_edit ctx args)
  | "masc_code_delete" -> Some (handle_code_delete ctx args)
  | "masc_code_shell" -> Some (handle_code_shell ctx args)
  | "masc_code_git" -> Some (handle_code_git ctx args)
  | _ -> None

(* Tool schemas *)
let schemas : Masc_domain.tool_schema list = [
  {
    name = "masc_code_write";
    description = "Create or overwrite a file in an allowed coding sandbox \
(.worktrees/ or .masc/playground/). \
Use to generate new source files, configs, or replace entire file contents. \
For partial edits (change a function, fix a line), use masc_code_edit instead. \
Returns bytes_written. Max 1MB. Set up a worktree first with masc_worktree_create.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to write (must be within .worktrees/ or .masc/playground/)");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "File content to write");
        ]);
        ("create_dirs", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Create intermediate directories if needed (default: false)");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "path"; `String "content"]);
    ];
  };

  {
    name = "masc_code_edit";
    description = "Replace text in a file in an allowed coding sandbox \
(.worktrees/ or .masc/playground/). \
Use for surgical edits: fix a bug, update a function, change a config value. \
old_string must match exactly once (unless replace_all=true). Returns replacement_count. \
For full file replacement, use masc_code_write. Read the file first with masc_code_read \
to get the exact text to replace.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to edit (must be within .worktrees/ or .masc/playground/)");
        ]);
        ("old_string", `Assoc [
          ("type", `String "string");
          ("description", `String "Exact string to find and replace");
        ]);
        ("new_string", `Assoc [
          ("type", `String "string");
          ("description", `String "Replacement string");
        ]);
        ("replace_all", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Replace all occurrences (default: false, requires unique match)");
          ("default", `Bool false);
        ]);
      ]);
      ("required", `List [`String "path"; `String "old_string"; `String "new_string"]);
    ];
  };

  {
    name = "masc_code_delete";
    description = "Delete a file in an allowed coding sandbox \
(.worktrees/ or .masc/playground/). Cannot delete directories. \
Use when removing generated, obsolete, or conflicting files during code work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to delete (must be within .worktrees/ or .masc/playground/)");
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  {
    name = "masc_code_shell";
    description = "Run an allowlisted command in an allowed coding sandbox \
(.worktrees/ or .masc/playground/). \
Allowed: dune, make, npm, npx, node, git, ls, cat, head, tail, wc, rg, find, \
diff, patch, mkdir, opam, ocamlfind, tsc. Use for building and testing code \
in isolated worktrees. For unrestricted shell at project root, use keeper_bash. \
Returns exit_code and stdout (truncated at " ^ max_output_label ^ ").";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("command", `Assoc [
          ("type", `String "string");
          ("description", `String "Single shell command to run (no pipes/chaining; first token must be in allowlist)");
        ]);
        ("cwd", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory (must be within .worktrees/ or .masc/playground/)");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("description", `String "Timeout in seconds (default: 30, max: 120)");
          ("default", `Int 30);
        ]);
      ]);
      ("required", `List [`String "command"]);
    ];
  };

  {
    name = "masc_code_git";
    description = "Run git commands in an allowed coding sandbox \
(.worktrees/ or .masc/playground/). Structured alternative \
to masc_code_shell for git operations. Supports: add, commit, push, diff, status, \
log, branch, checkout, stash, fetch, clone. Force push and push to main/master are blocked. \
Clone is restricted to allowed GitHub orgs (configured in config/tool_policy.toml). \
Returns git command output.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          (* Issue #8522: derive from Variant SSOT — adding a new
             constructor flows through here automatically. *)
          ("enum", `List (List.map (fun s -> `String s) valid_git_action_strings));
          ("description", `String "Git action to perform");
        ]);
        ("args", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Additional git arguments");
        ]);
        ("cwd", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory (must be within .worktrees/ or .masc/playground/)");
        ]);
      ]);
      ("required", `List [`String "action"; `String "cwd"]);
    ];
  };
]

(** Tool names for keeper gating *)
let tool_names : string list =
  schemas |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_code_write
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
