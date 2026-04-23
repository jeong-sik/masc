open Keeper_types
open Keeper_exec_shared

(* Issue #8524: Variant SSOT for keeper_shell op.  Adding a constructor
   forces compilation in [shell_op_to_string] AND extends
   [valid_shell_op_strings]; the schema in [tool_shard.ml] mirrors
   the SSOT (cycle-aware, sync test) and [supported_ops] in
   [handle_keeper_shell_unsupported] derives from it (replaced the
   hand-rolled list which had drifted from the dispatcher). The
   schema previously omitted [git_worktree] even though the
   dispatcher and supported_ops both list it — same drift class as
   #8430 / #8471 / #8474 / #8493 / #8513. *)
type shell_op =
  | Pwd
  | Ls
  | Cat
  | Rg
  | Git_status
  | Find
  | Head
  | Tail
  | Wc
  | Tree
  | Git_log
  | Git_diff
  | Git_worktree
  | Bash
  | Git_clone
  | Gh

let shell_op_to_string = function
  | Pwd -> "pwd"
  | Ls -> "ls"
  | Cat -> "cat"
  | Rg -> "rg"
  | Git_status -> "git_status"
  | Find -> "find"
  | Head -> "head"
  | Tail -> "tail"
  | Wc -> "wc"
  | Tree -> "tree"
  | Git_log -> "git_log"
  | Git_diff -> "git_diff"
  | Git_worktree -> "git_worktree"
  | Bash -> "bash"
  | Git_clone -> "git_clone"
  | Gh -> "gh"

let all_shell_ops =
  [ Pwd; Ls; Cat; Rg; Git_status; Find; Head; Tail; Wc; Tree;
    Git_log; Git_diff; Git_worktree; Bash; Git_clone; Gh ]

let valid_shell_op_strings = List.map shell_op_to_string all_shell_ops

(** Shell operation timeout constants.
    - [io_timeout_sec]: commands that may block on network/disk I/O
      (git status, ls with large dirs, custom bash).
    - [read_timeout_sec]: fast read-only commands on local files
      (cat, rg, head, tail, find, git_log, tree).
    - [user_timeout_max_sec]: upper bound for user-provided timeout_sec
      in keeper_bash (prevents indefinite blocking). *)
let env_float name default =
  match Sys.getenv_opt name with
  | Some s -> (match float_of_string_opt s with Some f -> f | None -> default)
  | None -> default

let io_timeout_sec = env_float "MASC_KEEPER_IO_TIMEOUT_SEC" 30.0
let read_timeout_sec = env_float "MASC_KEEPER_READ_TIMEOUT_SEC" 15.0
let user_timeout_max_sec = env_float "MASC_KEEPER_USER_TIMEOUT_MAX_SEC" 180.0

(* Floor for gh op timeout_sec. GitHub API + gh auth handshake is
   usually 3-10s; previous floors (1s, then 5s) produced 41
   gh_command_timed_out rejections in 2 days, every single one at
   timeout_sec=5 (#8688). 15s keeps keepers from requesting a
   sub-network-latency timeout without masking genuine hangs. *)
let gh_min_timeout_sec = 15.0

let clamp_shell_timeout ?(min_sec = 1.0) ~default args =
  Safe_ops.json_float ~default "timeout_sec" args
  |> fun n -> max min_sec (min user_timeout_max_sec n)

let lowercase_shell_words = Keeper_exec_shared.lowercase_shell_words

let git_global_option_takes_value = function
  | "-c" | "-C" | "--exec-path" | "--git-dir" | "--work-tree"
  | "--namespace" | "--super-prefix" | "--config-env" -> true
  | _ -> false

let git_global_option_has_inline_value token =
  List.exists (fun prefix -> String.starts_with ~prefix token)
    [ "--exec-path="; "--git-dir="; "--work-tree="; "--namespace="; "--config-env=" ]

let rec first_git_subcommand = function
  | [] -> None
  | token :: rest when git_global_option_takes_value token ->
      (match rest with
       | _value :: tail -> first_git_subcommand tail
       | [] -> None)
  | token :: rest when git_global_option_has_inline_value token ->
      first_git_subcommand rest
  | token :: rest when String.starts_with ~prefix:"-" token ->
      first_git_subcommand rest
  | token :: _rest -> Some token

let readonly_shell_token_match tokens =
  match tokens with
  | [] -> None
  | "git" :: rest ->
      (match first_git_subcommand rest with
       | Some "push" -> Some ("git push", "git_write")
       | Some "reset" -> Some ("git reset", "git_write")
       | Some "checkout" -> Some ("git checkout", "git_write")
       | Some "rebase" -> Some ("git rebase", "git_write")
       | _ -> None)
  | "pip" :: "install" :: _ -> Some ("pip install", "package_install")
  | "npm" :: "install" :: _ -> Some ("npm install", "package_install")
  | "opam" :: "install" :: _ -> Some ("opam install", "package_install")
  | "rm" :: _ -> Some ("rm ", "destructive")
  | "rmdir" :: _ -> Some ("rmdir", "destructive")
  | "mv" :: _ -> Some ("mv ", "destructive")
  | "cp" :: _ -> Some ("cp ", "destructive")
  | "chmod" :: _ -> Some ("chmod", "destructive")
  | "chown" :: _ -> Some ("chown", "destructive")
  | "kill" :: _ -> Some ("kill", "destructive")
  | "pkill" :: _ -> Some ("pkill", "destructive")
  | "dd" :: _ -> Some ("dd ", "destructive")
  | "mkfs" :: _ -> Some ("mkfs", "destructive")
  | "wget" :: _ -> Some ("wget ", "destructive")
  | "curl" :: rest when List.exists (String.equal "-o") rest ->
      Some ("curl -o", "destructive")
  | "curl" :: rest when List.exists (String.equal "--output") rest ->
      Some ("curl --output", "destructive")
  | _ -> None

(* Each branch ends with concrete Good:/Bad: examples so small-LLM keepers
   can self-correct without a retry loop. Prior form only named the
   category, which left 57 command_blocked_readonly rejections on
   2026-04-17/18 without a wire-level rewrite. See masc-mcp#8688. *)
let readonly_hint_of_category = function
  | "chaining" ->
      "`&&`, `||`, and `;` chaining are blocked in readonly shell. \
       Issue one command per keeper_shell call, or use a dedicated \
       sub-op: git_log, git_status, git_diff, git_worktree, find, \
       ls, rg, head, tail, wc, tree, cat, pwd. \
       Good: command='git status'. Bad: command='git status && git log -1'."
  | "redirect" ->
      "Redirects (`>`, `>>`, `| tee`) are blocked in readonly shell. \
       Use keeper_fs_edit to write files, or keeper_bash with the \
       coding preset for write operations. \
       Good: keeper_fs_edit path=notes.md content='...'. \
       Bad: command='echo hi > notes.md'."
  | "git_write" ->
      "Use keeper_bash with coding preset for git write operations. \
       Good: keeper_bash cmd='git add lib/foo.ml'. \
       Bad: keeper_shell command='git commit -m x' (readonly shell \
       does not accept git write commands)."
  | "package_install" ->
      "Package installation requires keeper_bash with coding preset. \
       Good: keeper_bash cmd='opam install -y eio'. \
       Bad: keeper_shell command='opam install eio' (readonly shell \
       does not accept package installs)."
  | "destructive" ->
      "Use keeper_bash for write operations, not readonly shell. \
       Good: keeper_bash cmd='rm .tmp/scratch.log'. \
       Bad: keeper_shell command='rm -rf .tmp/' (readonly shell does \
       not accept destructive commands)."
  | _ -> "This operation is not allowed in readonly shell."

(* P8: Structured diagnosis per readonly category.  The hint field is
   human-oriented prose; the diagnosis field is machine-parseable so
   small-LLM keepers can extract rule_id + rewrite without regex. *)
let diagnosis_of_readonly_category category =
  match category with
  | "chaining" ->
      Some { Exec_core.rule_id = "readonly_chaining_blocked"
            ; explanation =
                "&&, ||, and ; chain multiple commands; the readonly shell \
                 validates one command per call."
            ; rewrite =
                Some "Split into two calls: keeper_shell op='custom' \
                      command='git status' then keeper_shell op='custom' \
                      command='git log -1'."
            ; tool_suggestion = None }
  | "redirect" ->
      Some { Exec_core.rule_id = "readonly_redirect_blocked"
            ; explanation =
                "> and >> modify the filesystem; readonly shell forbids writes."
            ; rewrite = None
            ; tool_suggestion =
                Some "keeper_fs_edit" }
  | "git_write" ->
      Some { Exec_core.rule_id = "readonly_git_write_blocked"
            ; explanation =
                "git commit/push/checkout modify state; readonly shell only \
                 allows read-only git subcommands (log, diff, status, show)."
            ; rewrite =
                Some "Use keeper_bash with coding preset: keeper_bash \
                      cmd='git add lib/foo.ml && git commit -m \"msg\"'."
            ; tool_suggestion = None }
  | "package_install" ->
      Some { Exec_core.rule_id = "readonly_package_install_blocked"
            ; explanation =
                "opam install / npm install mutate the global environment; \
                 readonly shell forbids package mutations."
            ; rewrite =
                Some "Use keeper_bash with coding preset: keeper_bash \
                      cmd='opam install -y eio'."
            ; tool_suggestion = None }
  | "destructive" ->
      Some { Exec_core.rule_id = "readonly_destructive_blocked"
            ; explanation =
                "rm, curl -o, and similar destructive commands modify or \
                 delete state; readonly shell forbids them."
            ; rewrite =
                Some "Use keeper_bash with coding preset: keeper_bash \
                      cmd='rm .tmp/scratch.log'."
            ; tool_suggestion = None }
  | _ -> None

let diagnosis_of_block_reason reason =
  match reason with
  | Worker_dev_tools.Chain_or_redirect ->
      Some { Exec_core.rule_id = "command_chaining_blocked"
            ; explanation =
                "Pipe | and chain && or ; combine multiple commands; the \
                 keeper validates one command per call."
            ; rewrite =
                Some "Split into two keeper_bash calls, or use keeper_shell \
                      with a specific op (rg, ls, find)."
            ; tool_suggestion = None }
  | Worker_dev_tools.Pipes_not_allowed ->
      Some { Exec_core.rule_id = "command_pipe_blocked"
            ; explanation =
                "Pipes (|) connect two processes; each needs separate \
                 validation in the keeper security model."
            ; rewrite =
                Some "Run the first command, then pipe the output into \
                      the second keeper_bash call."
            ; tool_suggestion = None }
  | Worker_dev_tools.Unsafe_redirect ->
      Some { Exec_core.rule_id = "command_redirect_blocked"
            ; explanation =
                "> and >> redirect output to files; use a dedicated write tool."
            ; rewrite = None
            ; tool_suggestion = Some "keeper_fs_edit" }
  | Worker_dev_tools.Injection ->
      Some { Exec_core.rule_id = "command_injection_blocked"
            ; explanation =
                "Shell metacharacters ($(), ``, eval) can inject arbitrary \
                 commands; they are blocked for safety."
            ; rewrite =
                Some "Compute the value first, then pass it as a literal \
                      argument in a second keeper_bash call."
            ; tool_suggestion = None }
  | Worker_dev_tools.Process_substitution ->
      Some { Exec_core.rule_id = "command_process_subst_blocked"
            ; explanation =
                "<() and >() process substitutions create sub-processes; \
                 they are blocked for safety."
            ; rewrite =
                Some "Write the intermediate result to a temp file, then \
                      reference it in the second command."
            ; tool_suggestion = None }
  | Worker_dev_tools.Command_not_allowed name ->
      Some { Exec_core.rule_id = "command_not_allowed"
            ; explanation =
                Printf.sprintf
                  "'%s' is not on the allowed command list for this preset."
                  name
            ; rewrite = None
            ; tool_suggestion = Some "keeper_shell" }
  | Worker_dev_tools.Empty_command ->
      Some { Exec_core.rule_id = "command_empty"
            ; explanation = "The command string is empty."
            ; rewrite =
                Some "Provide a command: keeper_bash cmd='ls -la lib/'."
            ; tool_suggestion = None }

let process_status_is_timeout = function
  | Unix.WSIGNALED sig_num -> sig_num = Sys.sigterm
  | Unix.WEXITED 124 -> true  (* Process_eio returns 124 on Eio.Time.Timeout *)
  | _ -> false

let replace_all_substrings ~needle ~replacement text =
  let needle_len = String.length needle in
  if needle_len = 0 || not (String_util.contains_substring text needle) then text
  else
    let text_len = String.length text in
    let buf = Buffer.create text_len in
    let rec loop i =
      if i >= text_len then ()
      else if i + needle_len <= text_len
              && String.sub text i needle_len = needle then (
        Buffer.add_string buf replacement;
        loop (i + needle_len))
      else (
        Buffer.add_char buf text.[i];
        loop (i + 1))
    in
    loop 0;
    Buffer.contents buf

let rewrite_turn_runtime_paths_to_host
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      text
  =
  replace_all_substrings
    ~needle:(Keeper_sandbox.container_root meta.name)
    ~replacement:(Keeper_sandbox.host_root_abs_of_meta ~config meta)
    text

let run_argv_with_status_retry_eintr ?cwd ~timeout_sec argv =
  let max_eintr_retries = 8 in
  let rec loop attempts_left =
    let result = Process_eio.run_argv_with_status ?cwd ~timeout_sec argv in
    match result with
    | Unix.WEXITED 127, out
      when attempts_left > 0
           && String_util.contains_substring_ci out "interrupted system call" ->
        loop (attempts_left - 1)
    | _ -> result
  in
  loop max_eintr_retries

let shell_command_available name =
  let probe =
    Printf.sprintf "command -v %s >/dev/null 2>&1" (Filename.quote name)
  in
  match run_argv_with_status_retry_eintr ~timeout_sec:2.0 [ "/bin/sh"; "-c"; probe ] with
  | Unix.WEXITED 0, _ -> true
  | _ -> false
(** Write playground repo state cache after successful clone/pull.
    Reads git metadata from [repo_path] and upserts into
    [playground_dir/.playground_state.json]. Best-effort: failures are logged
    but do not propagate. *)
let update_playground_repo_cache
      ~(playground_dir : string) ~(repo_name : string) ~(repo_path : string)
      ~(action : string) ~(shallow : bool) : unit =
  try
    let branch =
      let st, s = Process_eio.run_argv_with_status ~timeout_sec:5.0
        [ "git"; "-C"; repo_path; "rev-parse"; "--abbrev-ref"; "HEAD" ] in
      if st = Unix.WEXITED 0 then String.trim s else "unknown"
    in
    let commit =
      let st, s = Process_eio.run_argv_with_status ~timeout_sec:5.0
        [ "git"; "-C"; repo_path; "log"; "--oneline"; "-1" ] in
      if st = Unix.WEXITED 0 then String.trim s else ""
    in
    let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
    let entry = `Assoc [
      "name", `String repo_name;
      "branch", `String branch;
      "latest_commit", `String commit;
      "shallow", `Bool shallow;
      "last_action", `String action;
      "updated_at", `String ts;
    ] in
    let cache_path = Filename.concat playground_dir ".playground_state.json" in
    let existing =
      try
        let json = Yojson.Safe.from_file cache_path in
        (match Yojson.Safe.Util.member "repos" json with
         | `List repos -> repos
         | _ -> [])
      with Sys_error _ | Yojson.Json_error _ -> []
    in
    let updated =
      entry :: List.filter (fun r ->
        match Yojson.Safe.Util.member "name" r with
        | `String n -> n <> repo_name
        | _ -> true) existing
    in
    let json = `Assoc [
      "repos", `List updated;
      "last_updated", `String ts;
    ] in
    (match Fs_compat.save_file_atomic cache_path
       (Yojson.Safe.pretty_to_string json ^ "\n") with
     | Ok () -> ()
     | Error e ->
         Logs.warn (fun f -> f "playground cache save failed: %s" e))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Logs.warn (fun f -> f "playground cache update failed: %s"
      (Printexc.to_string exn))

let resolve_keeper_shell_read_cwd
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_read_root ~config ~meta)
    else resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd -> Error (Printf.sprintf "cwd_not_directory: %s" cwd)

let resolve_keeper_shell_write_cwd
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_write_root ~config ~meta)
    else resolve_keeper_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd -> Error (Printf.sprintf "cwd_not_directory: %s" cwd)

(* Docker playground path mapping: host → container.
   Host:      <base_path>/.masc/playground/<keeper>/repos/X
   Container: <container_playground_root>/<keeper>/repos/X
   The container-side root comes from
   [Env_config_keeper.DockerPlayground.container_playground_root] so the
   mount point is configurable (default "/home/keeper/playground"). *)
let _docker_playground_cwd ~(config : Coord.config) ~(meta : keeper_meta) host_cwd =
  let root = Keeper_alerting_path.project_root_of_config config in
  let playground_prefix =
    Filename.concat root Playground_paths.all_playgrounds_prefix
  in
  let container_root =
    Env_config_keeper.DockerPlayground.container_playground_root
  in
  (* Boundary-safe prefix match: require either an exact match or a
     prefix ending at a path separator. Without this, host paths like
     "<root>/.masc/playgroundXYZ/..." would match "<root>/.masc/playground"
     and leak into the container playground. *)
  let prefix_with_sep = playground_prefix ^ "/" in
  let starts_at_boundary =
    host_cwd = playground_prefix
    || String.starts_with ~prefix:prefix_with_sep host_cwd
  in
  if starts_at_boundary then
    if host_cwd = playground_prefix then container_root
    else
      let raw_suffix =
        String.sub host_cwd (String.length prefix_with_sep)
          (String.length host_cwd - String.length prefix_with_sep)
      in
      (* A [host_cwd] like ".../.masc/playground//cheolsu/..." produces a
         [raw_suffix] that starts with "/". [Filename.concat] would then
         treat [raw_suffix] as an absolute path and drop [container_root],
         silently escaping the mount. Strip any leading slashes so the
         suffix is always a strict relative segment. *)
      let suffix =
        let n = String.length raw_suffix in
        let i = ref 0 in
        while !i < n && raw_suffix.[!i] = '/' do incr i done;
        if !i = 0 then raw_suffix
        else String.sub raw_suffix !i (n - !i)
      in
      if suffix = "" then container_root
      else Filename.concat container_root suffix
  else
    (* meta.name is sanitized through Playground_paths so a poisoned
       name cannot escape the container_root. *)
    Filename.concat container_root
      (Playground_paths.sanitize_keeper_name meta.name)

(* Common wrong path prefixes that keepers use.
   Maps wrong prefix → corrected relative path using the keeper
   playground SSOT ([Playground_paths]). [sanitize_keeper_name] in the
   SSOT rejects "", "." and ".." as whole-name segments (substituting
   "_", "_", "__" respectively), so a poisoned [meta.name] cannot
   produce a ".."/"." directory component and cannot escape the
   playground bundle via [Filename.concat]. *)
let auto_correct_path ~(meta : keeper_meta) (raw : string) : string option =
  (* bundle_root yields ".masc/playground/<safe>/" — strip the trailing
     slash so we can append "/repos/..." cleanly. *)
  let playground_bundle = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let playground =
    if String.length playground_bundle > 0
       && playground_bundle.[String.length playground_bundle - 1] = '/'
    then String.sub playground_bundle 0 (String.length playground_bundle - 1)
    else playground_bundle
  in
  let try_strip prefix replacement =
    let plen = String.length prefix in
    if String.length raw >= plen
       && String.sub raw 0 plen = prefix
    then Some (replacement ^ String.sub raw plen (String.length raw - plen))
    else None
  in
  (* /repos/X → .masc/playground/<safe-name>/repos/X *)
  match try_strip "/repos/" (playground ^ "/repos/") with
  | Some _ as r -> r
  | None ->
  match try_strip "repos/" (playground ^ "/repos/") with
  | Some _ as r -> r
  | None ->
  match try_strip "playground/" (Playground_paths.all_playgrounds_prefix ^ "/") with
  | Some _ as r -> r
  | None -> None

let resolve_keeper_shell_read_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  let resolve_with_autocorrect raw_path_to_resolve =
    match resolve_keeper_read_path ~config ~meta ~raw_path:raw_path_to_resolve with
    | Ok _ as ok -> ok
    | Error original_err ->
      (* Try auto-correcting common wrong prefixes *)
      match auto_correct_path ~meta raw_path_to_resolve with
      | Some corrected ->
        (match resolve_keeper_read_path ~config ~meta ~raw_path:corrected with
         | Ok resolved ->
           Log.Keeper.info "%s: auto-corrected path %S → %S"
             meta.name raw_path_to_resolve resolved;
           Ok resolved
         | Error _ -> Error original_err)
      | None -> Error original_err
  in
  match resolve_keeper_shell_read_cwd ~config ~meta ~args with
  | Error _ as err when raw_path = "" -> err
  | Error _ ->
    let fallback_path = if raw_path = "" then "." else raw_path in
    resolve_with_autocorrect fallback_path
  | Ok cwd ->
    let resolved_raw_path =
      if raw_path = "" then
        cwd
      else if not (Filename.is_relative raw_path) then
        raw_path
      else
        (* Guard against playground path doubling: when cwd already
           contains a playground prefix (e.g. .../playground/keeper/)
           and raw_path also starts with a playground-relative segment
           (e.g. ".masc/playground/keeper/repos"), concatenating would
           produce a doubled path.  Detect and resolve against project
           root instead. *)
        let pg = Playground_paths.all_playgrounds_prefix in
        let contains s sub =
          let sl = String.length s and nl = String.length sub in
          if nl > sl then false
          else
            let rec scan i =
              if i + nl > sl then false
              else if String.sub s i nl = sub then true
              else scan (i + 1)
            in scan 0
        in
        let cwd_has_pg = contains cwd pg in
        let path_has_pg = contains raw_path pg in
        if cwd_has_pg && path_has_pg then
          raw_path
        else
          Filename.concat cwd raw_path
    in
    resolve_with_autocorrect resolved_raw_path

(* Docker/sandbox infrastructure delegated to Keeper_shell_docker.
   Aliases retained for backward compatibility with callers that
   reference Keeper_exec_shell.* directly (tests, doc refs). *)
let effective_sandbox_profile = Keeper_shell_docker.effective_sandbox_profile
let cmd_targets_git_or_gh = Keeper_shell_docker.cmd_targets_git_or_gh
let ensure_keeper_sandbox_runtime = Keeper_shell_docker.ensure_keeper_sandbox_runtime
let command_uses_nested_container_runtime = Keeper_shell_docker.command_uses_nested_container_runtime
let run_docker_shell_command_with_status = Keeper_shell_docker.run_docker_shell_command_with_status
let run_docker_with_git_bash = Keeper_shell_docker.run_docker_with_git_bash
let run_docker_hardened_bash = Keeper_shell_docker.run_docker_hardened_bash

let handle_keeper_bash
      ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
      ~(turn_sandbox_runtime_git : Keeper_turn_sandbox_runtime.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let root = Keeper_alerting_path.project_root_of_config config in
  let cmd_for_log =
    cmd
    |> Worker_dev_tools.sanitize_command_for_log
    |> Worker_dev_tools.truncate_for_log
  in
  let timeout_sec = clamp_shell_timeout ~default:io_timeout_sec args in
  let run_in_background =
    Safe_ops.json_bool ~default:false "run_in_background" args
  in
  (* Write access is config-driven via permissions.shell_write_presets *)
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  if cmd = ""
  then error_json "cmd is required. Good: cmd='ls -la lib/'. Bad: cmd=''."

  else begin
    (* Tick 22: dark-launch shadow logger.  Runs
       [Worker_dev_tools.diff_command] side-by-side with the
       live gate and emits a structured line for every non-[Agree]
       outcome so operators can collect flip-blocker evidence
       (Legacy_deny_shadow_allow) and inverted-gap cases
       (Legacy_allow_shadow_deny) from real traffic without
       changing any behavior.  Flag-gated by
       [MASC_BASH_AST_SHADOW_LOG]; default off. *)
    (if Worker_dev_tools.shadow_diff_log_enabled () then begin
       let diff, legacy, shadow = Worker_dev_tools.diff_command cmd in
       Legendary_counters.incr_gate_diff diff;
       (* Histogram refinement of the Shadow_cannot_parse bucket —
          per-reason counters let operators prioritise A1-PR-N
          grammar expansion by construct frequency.  Only increments
          when diff=Shadow_cannot_parse; other diff variants do not
          map to a parse-reason tag.  The parse_tag inside
          Shadow_parse_unsupported carries the bare reason
          (e.g. "too_complex:redirect") emitted by
          Worker_dev_tools.shadow_parse_outcome. *)
       (match diff, shadow with
        | Worker_dev_tools.Shadow_cannot_parse,
          Worker_dev_tools.Shadow_parse_unsupported { parse_tag } ->
          Legendary_counters.incr_too_complex_by_tag parse_tag
        | Worker_dev_tools.Shadow_cannot_parse, _ ->
          (* Defensive: diff_of_verdicts only returns
             Shadow_cannot_parse when shadow is
             Shadow_parse_unsupported.  If that invariant changes,
             the "other" bucket preserves the count. *)
          Legendary_counters.incr_too_complex_by_tag "other"
        | _ -> ());
       (match diff with
        | Worker_dev_tools.Agree -> ()
        | _ ->
          Log.Keeper.info
            "gate_diff_shadow keeper=%s cmd_hash=%s diff=%s legacy=%s shadow=%s"
            meta.name
            (Worker_dev_tools.cmd_hash_for_log cmd)
            (Worker_dev_tools.gate_diff_to_string diff)
            (Worker_dev_tools.legacy_verdict_to_tag legacy)
            (Worker_dev_tools.shadow_verdict_to_tag shadow))
     end);
    (* Resolve cwd early — needed for playground detection before validation. *)
    match resolve_keeper_shell_write_cwd ~config ~meta ~args with
    | Error e -> error_json e
    | Ok cwd ->
    let env_snap =
      try Some (Exec_core.snapshot_env ~cwd)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> None
    in
    let normalize_path_for_containment path =
      Keeper_alerting_path.normalize_path_for_check path
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    let cwd_canonical =
      normalize_path_for_containment cwd
    in
    let playground_rel =
      Keeper_sandbox.allowed_root_rel_of_meta ~meta
    in
    let playground_abs =
      normalize_path_for_containment (Filename.concat root playground_rel)
    in
    let in_playground =
      String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
      || String.equal playground_abs cwd_canonical
    in
    let base_profile, base_network_mode =
      effective_sandbox_profile ~meta ~in_playground
    in
    (* Docker git-credential dispatch. When base profile is Docker and the
       command's leading token is git/gh, upgrade network to inherit and
       enable read-only mounts of ~/.config/gh and ~/.gitconfig for the
       duration of this command. Disabled when
       MASC_KEEPER_SANDBOX_GIT_DISPATCH=false.
       [git_creds_enabled] replaces the former Docker_with_git variant:
       the external profile stays Docker; the dispatcher reads this flag
       to choose between run_docker_with_git_bash and run_docker_hardened_bash. *)
    let sandbox_profile, sandbox_network_mode, git_creds_enabled =
      if base_profile = Docker
         && Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled ()
         && cmd_targets_git_or_gh cmd
      then (Docker, Network_inherit, true)
      else (base_profile, base_network_mode, false)
    in
    (* Destructive guard: always active regardless of Docker or preset *)
    if Worker_dev_tools.is_destructive_bash_operation cmd
    then (
      Log.Keeper.warn "keeper_bash DESTRUCTIVE blocked: %s (keeper=%s)" cmd_for_log meta.name;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"destructive_operation_blocked"
           ~reason:
             "This command is destructive (force push, push to main, rm -rf, \
              etc.) and is blocked for all presets."
           ~alternatives:
             [ "Use `git push` without --force for normal pushes."
             ; "For cleanup, target specific files instead of rm -rf."
             ; "Ask a human operator to perform this destructive action."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "destructive_operation_blocked"
                    ; explanation =
                        "force push, rm -rf, and similar destructive \
                         commands are blocked for all presets to protect \
                         shared state."
                    ; rewrite =
                        Some "For git: use 'git push' without --force. \
                              For cleanup: target specific files (rm file) \
                              instead of rm -rf."
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ~env_snapshot:env_snap
           ()))
    else if sandbox_profile = Docker && git_creds_enabled then (
      Log.Keeper.info
        "DOCKER_GIT_EXEC: keeper=%s cwd=%s cmd=%s"
        meta.name cwd cmd_for_log;
      run_docker_with_git_bash
        ~turn_sandbox_runtime:turn_sandbox_runtime_git
        ~config ~meta ~cwd ~timeout_sec ~cmd ())
    else if sandbox_profile = Docker then (
      Log.Keeper.info
        "DOCKER_EXEC: keeper=%s cwd=%s cmd=%s network=%s"
        meta.name cwd cmd_for_log (network_mode_to_string sandbox_network_mode);
      run_docker_hardened_bash
        ~turn_sandbox_runtime
        ~config ~meta ~cwd ~timeout_sec ~cmd
        ~network_mode:sandbox_network_mode)
    else
      (* Local execution path: full validation applies *)
      let validate =
        if write_enabled then Worker_dev_tools.validate_command_coding
        else Worker_dev_tools.validate_command
      in
      match validate cmd with
      | Error reason ->
        let reason_str = Worker_dev_tools.block_reason_to_string reason in
        Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason_str cmd_for_log;
        let hint =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String.lowercase_ascii name = "gh" ->
            "`gh` is not allowed via keeper_bash. Use keeper_shell with \
             op=\"gh\" (e.g. keeper_shell op=gh cmd=\"pr list --state open\")."
          | Chain_or_redirect | Pipes_not_allowed | Unsafe_redirect ->
            "Use separate tool calls instead of chaining. Call keeper_bash once per command."
          | Injection | Process_substitution ->
            "Avoid shell metacharacters. Use keeper_shell with a specific op (rg, find, ls) instead."
          | Command_not_allowed _ ->
            "Check the command for blocked patterns. Use keeper_shell for structured ops (rg, ls, find)."
          | Empty_command ->
            "Provide a non-empty command string."
        in
        let alternatives =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String.lowercase_ascii name = "gh" ->
            [ "Use keeper_shell with op=\"gh\" for GitHub CLI operations."
            ; "Example: keeper_shell op=gh cmd=\"pr list --state open\"."
            ]
          | Chain_or_redirect | Pipes_not_allowed | Unsafe_redirect ->
            [ "Break the pipeline into separate keeper_bash calls."
            ; "Save intermediate output to a file, then process it in the next call."
            ]
          | Injection | Process_substitution ->
            [ "Use keeper_shell with a specific op (rg, find, ls) for structured queries."
            ; "Avoid $(...) and backtick substitution in commands."
            ]
          | Command_not_allowed _ ->
            [ "Use keeper_shell for structured ops (rg, ls, find)."
            ; "Check if the command is available under a different name or op."
            ]
          | Empty_command ->
            [ "Provide a non-empty command string."
            ; "Example: keeper_bash cmd='ls -la lib/'."
            ]
        in
        Yojson.Safe.to_string
          (Exec_core.blocked_result_json
             ~cmd
             ~error:"command_blocked"
             ~reason:reason_str
             ~hint
             ~alternatives
             ~diag:(diagnosis_of_block_reason reason)
             ~extra:[ "execution_time_ms", `Int 0 ]
             ~env_snapshot:env_snap
             ())
      | Ok () ->
        (* Branch-switch guard *)
        let sandbox_root = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
        if Worker_dev_tools.is_git_branch_switch cmd
                && not (write_enabled && in_playground)
        then (
          Log.Keeper.info
            "keeper_bash branch-switch blocked: %s (keeper=%s, write_enabled=%b, playground=%b)"
            cmd_for_log meta.name write_enabled in_playground;
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"branch_switch_blocked"
               ~reason:
                 "git checkout/switch/branch mutations require a write-enabled preset \
                  (Coding/Delivery/Full) and a keeper-owned sandbox repo or \
                  worktree. Clone into your sandbox first \
                  (keeper_shell op=git_clone), then create or enter a worktree \
                  under repos/<repo>/.worktrees/<task>."
               ~hint:(Printf.sprintf
                        "Use cwd=%srepos/REPO/.worktrees/TASK"
                        sandbox_root)
               ~alternatives:
                 [ Printf.sprintf
                     "Clone the repo first: keeper_shell op=git_clone, then use cwd=%srepos/REPO/.worktrees/TASK."
                     sandbox_root
                 ; "Use keeper_shell op=git op_cmd='branch -a' to list available branches."
                 ]
               ~retryability:Exec_core.Operator_required
               ~diag:
                 (Some { Exec_core.rule_id = "branch_switch_blocked"
                        ; explanation =
                            "git checkout/switch/branch mutations need a                              write-enabled preset and a sandbox clone."
                        ; rewrite =
                            Some (Printf.sprintf
                              "First: keeper_shell op=git_clone.                                Then: set cwd=%srepos/REPO/.worktrees/TASK"
                              sandbox_root)
                        ; tool_suggestion = None })
               ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
               ()))
        (* Write gate — preset layer *)
        else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
        then (
          Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s, playground=%b)"
            cmd_for_log meta.name in_playground;
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"write_operation_gated"
               ~reason:
                 "This command modifies state (git push/commit, make deploy, etc.). \
                  A write-enabled preset (Coding/Delivery/Full) is required."
               ~alternatives:
                 [ "Read-only alternatives: use keeper_bash for git log, git diff, git status."
                 ; "If you need write access, ask the operator to assign a Coding/Delivery/Full preset."
                 ]
               ~retryability:Exec_core.Operator_required
               ~diag:
                 (Some { Exec_core.rule_id = "write_operation_gated"
                        ; explanation =
                            "This command modifies state but the current preset                              is read-only. Write operations require Coding,                              Delivery, or Full preset."
                        ; rewrite = None
                        ; tool_suggestion =
                            Some "Ask the operator for a write-enabled preset" })
               ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
               ~env_snapshot:env_snap
               ()))
        (* Write gate — playground containment layer (#6527 iter 3).
           A write-enabled keeper still must not mutate anything outside
           its own playground bundle. branch-switch already requires
           in_playground; match the same invariant for the general
           write operations (git push/commit, make deploy, etc.) so
           a coding-preset keeper cannot push from, e.g., a
           workspace-default `.worktrees/` path or `lib/` on the server
           repo. *)
        else if write_enabled
                && Worker_dev_tools.is_write_operation cmd
                && not in_playground
        then (
          Log.Keeper.info
            "keeper_bash write-containment blocked: %s (keeper=%s, cwd=%s, playground=%b)"
            cmd_for_log meta.name cwd in_playground;
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"write_outside_playground_blocked"
               ~reason:
                 (Printf.sprintf
                    "Write operations (git push/commit, make deploy, etc.) \
                     must run with cwd inside your keeper-owned sandbox clone \
                     or one of its worktrees under %srepos/<repo>/.worktrees/. \
                     Open a sandbox clone first with keeper_shell op=git_clone \
                     if needed, then use masc_worktree_create and set cwd to \
                     the returned worktree path."
                    sandbox_root)
               ~hint:(Printf.sprintf
                        "cwd must start with %s and usually looks like %srepos/REPO/.worktrees/TASK"
                        sandbox_root
                        sandbox_root)
               ~alternatives:
                 [ Printf.sprintf
                     "Clone into your sandbox: keeper_shell op=git_clone, then cd to %srepos/REPO/."
                     sandbox_root
                 ; "Create a worktree inside your sandbox with masc_worktree_create."
                 ; "Use keeper_bash with a cwd pointing to your sandbox worktree."
                 ]
               ~retryability:Exec_core.Operator_required
               ~diag:
                 (Some { Exec_core.rule_id = "write_outside_playground_blocked"
                        ; explanation =
                            "Write operations must run inside the keeper sandbox.                              The current cwd is outside the sandbox root."
                        ; rewrite =
                            Some (Printf.sprintf
                              "Clone into sandbox: keeper_shell op=git_clone,                                then set cwd=%srepos/REPO/.worktrees/TASK"
                              sandbox_root)
                        ; tool_suggestion = None })
               ~extra:[ "cmd", `String cmd_for_log; "cwd", `String cwd; "execution_time_ms", `Int 0 ]
               ()))
        else (
            (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd with
             | Error e -> error_json e
             | Ok () ->
               if write_enabled
                  && Worker_dev_tools.is_write_operation cmd then
                 Log.Keeper.info "WRITE_AUDIT: keeper=%s cwd=%s cmd=%s playground=%b"
                   meta.name cwd cmd_for_log in_playground;
               (* Tick 7: background mode keeps stdout/stderr separate
                  so [keeper_bash_output] can report them distinctly.
                  Foreground mode merges via [2>&1] for backward
                  compatibility with the single [output] JSON field. *)
               if run_in_background then begin
                 let argv = [ "/bin/bash"; "-lc"; cmd ] in
                 match
                   Bg_task.spawn
                     ~base_path:root
                     ~keeper:meta.name
                     ~argv
                     ~cwd
                     ~envp:(Unix.environment ())
                     ~timeout_sec
                     ()
                 with
                 | Ok tid ->
                     Log.Keeper.info
                       "BG_SPAWN: keeper=%s task_id=%s cmd=%s"
                       meta.name (Bg_task.task_id_to_string tid) cmd_for_log;
                     Yojson.Safe.to_string
                       (`Assoc
                         [
                           ("ok", `Bool true);
                           ( "background_task_id",
                             `String (Bg_task.task_id_to_string tid) );
                           ("cmd", `String cmd);
                           ("cwd", `String cwd);
                           ( "hint",
                             `String
                               "Task running in background. Poll with \
                                keeper_bash_output or stop with \
                                keeper_bash_kill." );
                         ])
                 | Error (Bg_task.Spawn_failed e) ->
                     error_json
                       (Printf.sprintf "background spawn failed: %s" e)
                 | Error (Bg_task.Too_many_tasks { keeper = k; limit }) ->
                     error_json
                       (Printf.sprintf
                          "keeper %s exceeded background task limit (%d)"
                          k limit)
                 | Error (Bg_task.Invalid_cwd msg) ->
                     error_json (Printf.sprintf "invalid cwd: %s" msg)
               end
               else begin
                 (* Tick 11: Foreground path with optional auto-background
                    race.  When [MASC_BASH_AUTO_BG] is enabled and an Eio
                    clock is available, route through
                    [Masc_exec.Exec_run.run_with_auto_bg]: the command
                    spawns as a Bg_task, races its exit against
                    [MASC_BLOCKING_BUDGET_MS] (default 15000), and on
                    budget expiry returns a [Promoted] handle the LLM
                    can poll via [keeper_bash_output].  Without the
                    flag, fall back to the legacy blocking call so
                    existing consumers see no shape change. *)
                 let auto_bg_enabled =
                   match Sys.getenv_opt "MASC_BASH_AUTO_BG" with
                   | Some ("1" | "true" | "yes" | "on") -> true
                   | _ -> false
                 in
                 let argv_merged =
                   [ "/bin/bash"; "-lc"; cmd ^ " 2>&1" ]
                 in
                 (* Tick 23: AUTO_BG dark-launch observer.  When
                    [MASC_BASH_AUTO_BG_OBSERVE] is set, time the
                    foreground run and emit a structured log line
                    if the elapsed duration would have tripped the
                    blocking budget had [MASC_BASH_AUTO_BG] been
                    on.  No behavior change; cheap measurement
                    feeds future default-flip decisions. *)
                 let auto_bg_observe_enabled =
                   match Sys.getenv_opt "MASC_BASH_AUTO_BG_OBSERVE" with
                   | Some ("1" | "true" | "TRUE" | "yes" | "on" | "log") -> true
                   | _ -> false
                 in
                 match
                   if auto_bg_enabled
                   then Eio_context.get_clock_opt ()
                   else None
                 with
                 | None ->
                   let t0 = Unix.gettimeofday () in
                   let st, out =
                     Process_eio.run_argv_with_status
                       ~cwd ~timeout_sec argv_merged
                   in
                   let elapsed_ms =
                     int_of_float ((Unix.gettimeofday () -. t0) *. 1000.)
                   in
                   (if auto_bg_observe_enabled then begin
                      let budget_ms =
                        Masc_exec.Exec_run.default_budget_ms ()
                      in
                      let promoted_candidate = elapsed_ms >= budget_ms in
                      Legendary_counters.incr_auto_bg_observed
                        ~promoted_candidate;
                      if promoted_candidate then
                        Log.Keeper.info
                          "auto_bg_would_have_promoted keeper=%s \
                           cmd_hash=%s duration_ms=%d budget_ms=%d"
                          meta.name
                          (Worker_dev_tools.cmd_hash_for_log cmd)
                          elapsed_ms
                          budget_ms
                    end);
                   Yojson.Safe.to_string
                     (Exec_core.process_result_json
                        ~base_path:root
                        ~keeper_name:meta.name
                        ~cmd
                        ~extra:[
                          "cwd", `String cwd;
                          "execution_time_ms", `Int elapsed_ms;
                        ]
                        ~status:st
                        ~output:out
                        ~env_snapshot:env_snap
                        ())
                 | Some clock ->
                   let budget_ms = Masc_exec.Exec_run.default_budget_ms () in
                   let t0_bg = Unix.gettimeofday () in
                   let outcome =
                     Masc_exec.Exec_run.run_with_auto_bg
                       ~clock
                       ~base_path:root
                       ~budget_ms
                       ~keeper:meta.name
                       ~argv:argv_merged
                       ~cwd
                       ~envp:(Unix.environment ())
                       ~timeout_sec
                       ()
                   in
                   (match outcome with
                    | Masc_exec.Exec_run.Completed r ->
                      let elapsed_ms =
                        int_of_float ((Unix.gettimeofday () -. t0_bg) *. 1000.)
                      in
                      Yojson.Safe.to_string
                        (Exec_core.process_result_json
                           ~base_path:root
                           ~keeper_name:meta.name
                           ~cmd
                           ~extra:[
                             "cwd", `String cwd;
                             "execution_time_ms", `Int elapsed_ms;
                           ]
                           ~status:r.status
                           ~output:r.stdout
                           ~env_snapshot:env_snap
                           ())
                    | Masc_exec.Exec_run.Promoted p ->
                      let elapsed_ms =
                        int_of_float ((Unix.gettimeofday () -. t0_bg) *. 1000.)
                      in
                      Log.Keeper.info
                        "BG_PROMOTE: keeper=%s task_id=%s budget_ms=%d cmd=%s"
                        meta.name
                        (Bg_task.task_id_to_string p.task_id)
                        budget_ms
                        cmd_for_log;
                      Yojson.Safe.to_string
                        (`Assoc
                          [
                            ("ok", `Bool false);
                            ("promoted", `Bool true);
                            ( "background_task_id",
                              `String
                                (Bg_task.task_id_to_string p.task_id) );
                            ("cmd", `String cmd);
                            ("cwd", `String cwd);
                            ("partial_output", `String p.partial_stdout);
                            ( "bytes_dropped",
                              `Int p.bytes_dropped_stdout );
                            ("budget_ms", `Int budget_ms);
                            ("execution_time_ms", `Int elapsed_ms);
                            ( "hint",
                              `String
                                (Printf.sprintf
                                   "Command exceeded \
                                    MASC_BLOCKING_BUDGET_MS=%d. Still \
                                    running in background; poll with \
                                    keeper_bash_output or stop with \
                                    keeper_bash_kill."
                                   budget_ms) );
                          ])
                    | Masc_exec.Exec_run.Spawn_error
                        (Bg_task.Spawn_failed e) ->
                      error_json
                        (Printf.sprintf
                           "auto-bg spawn failed: %s" e)
                    | Masc_exec.Exec_run.Spawn_error
                        (Bg_task.Too_many_tasks { keeper = k; limit }) ->
                      error_json
                        (Printf.sprintf
                           "keeper %s exceeded background task limit (%d)"
                           k limit)
                    | Masc_exec.Exec_run.Spawn_error
                        (Bg_task.Invalid_cwd msg) ->
                      error_json (Printf.sprintf "invalid cwd: %s" msg))
               end))
  end
;;

(* ============================================================ *)
(* Legendary Bash P2 — background-task siblings (Tick 6b).       *)
(* keeper_bash_output + keeper_bash_kill mirror claude-code's     *)
(* BashOutput / KillShell so an agent can poll and stop tasks    *)
(* spawned with run_in_background = true.                         *)
(* ============================================================ *)

(* ── BG task lifecycle (extracted to Keeper_shell_bg_task) ───── *)

let handle_keeper_bash_output = Keeper_shell_bg_task.handle_keeper_bash_output
let handle_keeper_bash_kill = Keeper_shell_bg_task.handle_keeper_bash_kill

(* ── GH repo context (extracted to Keeper_shell_gh_context) ──── *)

type gh_repo_context = Keeper_shell_gh_context.gh_repo_context =
  {
    task_id : string;
    git_root : string;
    worktree_cwd : string;
    repo_slug : string option;
  }

type gh_repo_context_error = Keeper_shell_gh_context.gh_repo_context_error =
  {
    code : string;
    detail : string;
    hint : string;
    task_id : string option;
    git_root : string option;
    worktree_path : string option;
  }

let gh_repo_context_error = Keeper_shell_gh_context.gh_repo_context_error
let gh_claim_first_hint = Keeper_shell_gh_context.gh_claim_first_hint
let gh_repo_context_error_json = Keeper_shell_gh_context.gh_repo_context_error_json
let resolve_gh_repo_context = Keeper_shell_gh_context.resolve_gh_repo_context

let handle_keeper_shell
      ~(turn_sandbox_runtime : Keeper_turn_sandbox_runtime.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_op =
    Safe_ops.json_string ~default:"" "op" args |> String.trim |> String.lowercase_ascii
  in
  (* Normalize common aliases so the model's naming variation doesn't cause
     unsupported_op failures. *)
  let op = match raw_op with
    | "git status" | "status" -> "git_status"
    | "git log" -> "git_log"
    | "git diff" -> "git_diff"
    | "git worktree" | "worktree" -> "git_worktree"
    | "read" | "file" | "type" -> "cat"
    | "grep" | "search" -> "rg"
    | "dir" | "list" -> "ls"
    | "git clone" | "clone" -> "git_clone"
    | _ -> raw_op
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  (* RFC-0006 Phase B-1.5: pin host-FS read guard for Docker keeper
     shell read ops. Local keepers remain on the host path. *)
  let containment_check target =
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target
  in
  let read_target () =
    match resolve_keeper_shell_read_path ~config ~meta ~args with
    | Error _ as e -> e
    | Ok target ->
      (match containment_check target with
       | Ok () -> Ok target
       | Error msg -> Error msg)
  in
  let cwd_target () =
    match resolve_keeper_shell_read_cwd ~config ~meta ~args with
    | Error _ as e -> e
    | Ok cwd ->
      (match containment_check cwd with
       | Ok () -> Ok cwd
       | Error msg -> Error msg)
  in
  (* Actionable error: Samchon/Claude Code validateInput pattern.
     Returns structured JSON with tried path, playground root, and concrete next action. *)
  let path_error e =
    actionable_path_error ~op ~meta ~raw_path ~error:e
  in
  let render_process_result ?cwd ~cmd argv =
    let st, out =
      run_argv_with_status_retry_eintr ?cwd ~timeout_sec:io_timeout_sec argv
    in
    Yojson.Safe.to_string
      (Exec_core.process_result_json
         ~artifact_policy:Exec_core.Inline_only
         ~base_path:root
         ~keeper_name:meta.name
         ~cmd
         ~extra:
           [
             "op", `String op;
             "cmd", `String cmd;
             ( "cwd",
               match cwd with
               | Some dir -> `String dir
               | None -> `Null );
           ]
         ~status:st
         ~output:out
         ())
  in
  let render_completed_process_result ?cwd ~cmd ?(extra = []) st out =
    Yojson.Safe.to_string
      (Exec_core.process_result_json
         ~artifact_policy:Exec_core.Inline_only
         ~base_path:root
         ~keeper_name:meta.name
         ~cmd
         ~extra:([
             "op", `String op;
             "cmd", `String cmd;
             ( "cwd",
               match cwd with
               | Some dir -> `String dir
               | None -> `Null );
           ] @ extra)
         ~status:st
         ~output:out
         ())
  in
  let docker_read_error ~target msg =
    error_json ~fields:[ "op", `String op; "path", `String target ] msg
  in
  let hostify_turn_runtime_output out =
    rewrite_turn_runtime_paths_to_host ~config ~meta out
  in
  let run_readonly_in_docker ?(ok_exit_codes = [ 0 ]) ~target ~command_argv
      ~max_bytes ~timeout_sec () =
    let max_eintr_retries = 8 in
    let rec loop attempts_left =
      match
        Keeper_docker_read.container_path_of_host ~config ~meta ~host_path:target
      with
      | Error e -> Error (docker_read_error ~target e)
      | Ok cpath -> (
          match
            Keeper_docker_read.run_command_in_container_with_status
              ?turn_sandbox_runtime
              ~ok_exit_codes ~config ~meta ~command_argv:(command_argv cpath)
              ~max_bytes ~timeout_sec ()
          with
          | Error msg
            when attempts_left > 0
                 && String_util.contains_substring_ci msg
                      "interrupted system call" ->
              loop (attempts_left - 1)
          | Error msg -> Error (docker_read_error ~target msg)
          | Ok payload -> Ok payload)
    in
    loop max_eintr_retries
  in
  let run_in_turn_runtime ?(ok_exit_codes = [ 0 ]) ~cwd ~cmd ~command_argv
      ~max_bytes ~timeout_sec ?(map_output = fun out -> out) ?(extra = []) () =
    match turn_sandbox_runtime with
    | Some runtime ->
      (match
         Keeper_turn_sandbox_runtime.run_command_with_status
           ~ok_exit_codes runtime ~cwd ~command_argv ~max_bytes ~timeout_sec ()
       with
       | Error msg ->
         error_json
           ~fields:([ "op", `String op; "cwd", `String cwd ] @ extra) msg
       | Ok (st, out) ->
         render_completed_process_result ~cwd ~cmd ~extra st (map_output out))
    | None ->
      render_process_result ~cwd ~cmd command_argv
  in
  let render_docker_process_result ~cwd ~cmd ~docker_cmd ~timeout_sec =
    match
      run_docker_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
        ~cmd:docker_cmd ~git_creds_enabled:false ~network_mode:Network_none
    with
    | Error msg -> error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
    | Ok result ->
      Yojson.Safe.to_string
        (Exec_core.process_result_json
           ~artifact_policy:Exec_core.Inline_only
           ~base_path:root
           ~keeper_name:meta.name
           ~cmd
           ~extra:
             [
               "op", `String op;
               "cmd", `String cmd;
               "cwd", `String cwd;
               "via", `String "docker";
             ]
           ~status:result.status
           ~output:result.output
           ())
  in
  let docker_git_log_path host_path =
    if String.trim host_path = "" then Ok ""
    else if Filename.is_relative host_path then Ok host_path
    else
      Keeper_docker_read.container_path_of_host ~config ~meta ~host_path
  in
  match op with
  | "pwd" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       if Keeper_docker_read.should_route_read ~meta then
         render_docker_process_result ~cwd ~cmd:"pwd" ~docker_cmd:"pwd"
           ~timeout_sec:io_timeout_sec
       else
         run_in_turn_runtime ~cwd ~cmd:"pwd" ~command_argv:[ "/bin/pwd" ]
           ~map_output:hostify_turn_runtime_output
           ~max_bytes:4096 ~timeout_sec:io_timeout_sec ())
  | "git_status" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       if Keeper_docker_read.should_route_read ~meta then
         render_docker_process_result ~cwd
           ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
           ~docker_cmd:"git --no-optional-locks status --short --branch"
           ~timeout_sec:read_timeout_sec
       else
         run_in_turn_runtime ~cwd
           ~cmd:"git --no-optional-locks status --short --branch"
           ~command_argv:
             [ "git"; "--no-optional-locks"; "status"; "--short"; "--branch" ]
           ~max_bytes:1_000_000
           ~timeout_sec:read_timeout_sec ())
  | "ls" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       (* RFC-0006 Phase B-3b: Docker keepers route ls through the same
          docker prelude as keeper_fs_read so the container's mount is
          the load-bearing isolation. The host-side containment guard
          above remains as defense in depth. *)
       if Keeper_docker_read.should_route_read ~meta then
         (match
            Keeper_docker_read.container_path_of_host ~config ~meta
              ~host_path:target
          with
          | Error e ->
            error_json
              ~fields:[ "op", `String op; "path", `String target ] e
          | Ok cpath ->
            (match
               Keeper_docker_read.run_command_in_container
                 ?turn_sandbox_runtime ~config ~meta
                 ~command_argv:[ "ls"; "-la"; cpath ]
                 ~max_bytes:1_000_000
                 ~timeout_sec:io_timeout_sec
                 ()
             with
             | Error msg ->
               error_json
                 ~fields:[ "op", `String op; "path", `String target ] msg
             | Ok out ->
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool true
                     ; "op", `String op
                     ; "path", `String target
                     ; "via", `String "docker"
                     ; "entries", lines_to_json ~limit out
                     ])))
        else
          let st, out =
           run_argv_with_status_retry_eintr
             ~timeout_sec:io_timeout_sec
             [ "/bin/ls"; "-la"; target ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "entries", lines_to_json ~limit out
               ]))
  | "cat" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let max_bytes = shell_readonly_cat_max_bytes args in
       (* RFC-0006 Phase B-3b: docker route via the existing
          read_file_in_container helper (which is already a [cat]
          wrapper around run_command_in_container). Symmetry with
          keeper_fs_read's [via: "docker"] response field. *)
       if Keeper_docker_read.should_route_read ~meta then
         (match
            Keeper_docker_read.read_file_in_container
              ?turn_sandbox_runtime ~config ~meta
              ~host_path:target ~max_bytes
              ~timeout_sec:read_timeout_sec
              ()
          with
          | Error msg ->
            error_json
              ~fields:[ "op", `String op; "path", `String target ] msg
          | Ok body ->
            let total = String.length body in
            let truncated = total >= max_bytes in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool true
                  ; "op", `String op
                  ; "path", `String target
                  ; "via", `String "docker"
                  ; "bytes", `Int total
                  ; "truncated", `Bool truncated
                  ; "content", `String body
                  ]))
       else
         let st, out =
           run_argv_with_status_retry_eintr
             ~timeout_sec:read_timeout_sec
             [ "/bin/cat"; target ]
         in
         let body =
           if String.length out > max_bytes then String.sub out 0 max_bytes else out
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "truncated", `Bool (String.length out > max_bytes)
               ; "content", `String body
               ]))
  | "rg" ->
    let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> path_error e
      | Ok target ->
        let limit = shell_readonly_limit args in
        (* Optional file-type filter (e.g. "ml", "py") *)
        let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
        (* Optional glob filter (e.g. "*.ml", "lib/**/*.ml") *)
        let glob = Safe_ops.json_string ~default:"" "glob" args |> String.trim in
        if Keeper_docker_read.should_route_read ~meta then
          let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
          let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
          let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
          (match
             run_readonly_in_docker ~target
               ~command_argv:(fun cpath ->
                 base_argv @ type_argv @ glob_argv @ [ pattern; cpath ])
               ~ok_exit_codes:[ 0; 1 ]
               ~max_bytes:1_000_000
               ~timeout_sec:read_timeout_sec
               ()
           with
           | Error response -> response
           | Ok (st, out) ->
             Yojson.Safe.to_string
               (`Assoc
                   [ "ok", `Bool true
                   ; "op", `String op
                   ; "path", `String target
                   ; "pattern", `String pattern
                   ; "via", `String "docker"
                   ; "status", Keeper_alerting_path.process_status_to_json st
                   ; "matches", lines_to_json ~limit out
                   ]))
        else
          let rg_available = shell_command_available "rg" in
          let grep_available = shell_command_available "grep" in
          let argv =
            if rg_available then
              let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
              let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
              let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
              Ok (base_argv @ type_argv @ glob_argv @ [ pattern; target ])
            else if not grep_available then
              Error "rg executable not found, and grep fallback is unavailable"
            else if file_type <> "" || glob <> "" then
              Error
                "rg executable not found; grep fallback only supports pattern and path"
            else
              (* Keep readonly rg usable in lean CI images that do not ship ripgrep. *)
              Ok
                [ "grep"; "-R"; "-n"; "-I"; "-m"; string_of_int limit; "--"; pattern; target ]
          in
          match argv with
          | Error e -> path_error e
          | Ok argv ->
            let st, out =
              run_argv_with_status_retry_eintr ~timeout_sec:read_timeout_sec argv
            in
            (* rg exit codes: 0=matches found, 1=no matches (not an error), 2+=real error.
               Treat exit 1 as success with empty results — "no match" is a valid answer. *)
            let is_ok = st = Unix.WEXITED 0 || st = Unix.WEXITED 1 in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool is_ok
                  ; "op", `String op
                  ; "path", `String target
                  ; "pattern", `String pattern
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "matches", lines_to_json ~limit out
                  ]))
  | "git_log" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       let count = max 1 (min 50 (Safe_ops.json_int ~default:10 "count" args)) in
       let format = Safe_ops.json_string ~default:"%h %s" "format" args in
       let file_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
       if Keeper_docker_read.should_route_read ~meta then
         (match docker_git_log_path file_path with
          | Error err ->
            error_json
              ~fields:[ "op", `String op; "cwd", `String cwd; "path", `String file_path ]
              err
          | Ok docker_file_path ->
            let docker_cmd =
              let base =
                Printf.sprintf "git --no-optional-locks log --format=%s -%d"
                  (Filename.quote format) count
              in
              if docker_file_path = "" then
                base
              else
                Printf.sprintf "%s -- %s" base (Filename.quote docker_file_path)
            in
            render_docker_process_result ~cwd
              ~cmd:"git -C <cwd> --no-optional-locks log --format=<fmt> -<n>"
              ~docker_cmd ~timeout_sec:read_timeout_sec)
       else
         let base_argv =
           [ "git"; "-C"; cwd; "--no-optional-locks"; "log";
             Printf.sprintf "--format=%s" format;
             Printf.sprintf "-%d" count ]
         in
         let argv = if file_path <> "" then base_argv @ [ "--"; file_path ] else base_argv in
         (match turn_sandbox_runtime with
          | Some runtime ->
            let argv =
              let base_argv =
                [ "git"; "--no-optional-locks"; "log";
                  Printf.sprintf "--format=%s" format;
                  Printf.sprintf "-%d" count ]
              in
              if file_path = "" then
                base_argv
              else
                let runtime_path =
                  if Filename.is_relative file_path then file_path
                  else
                    match
                      Keeper_turn_sandbox_runtime.container_path_of_host runtime
                        ~host_path:file_path
                    with
                    | Ok mapped -> mapped
                    | Error _ -> file_path
                in
                base_argv @ [ "--"; runtime_path ]
            in
            (match
               Keeper_turn_sandbox_runtime.run_command_with_status runtime
                 ~cwd ~command_argv:argv
                 ~ok_exit_codes:[ 0 ]
                 ~max_bytes:1_000_000
                 ~timeout_sec:read_timeout_sec ()
             with
             | Error msg ->
               error_json
                 ~fields:[ "op", `String op; "cwd", `String cwd ] msg
             | Ok (st, out) ->
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool true
                     ; "op", `String op
                     ; "cwd", `String cwd
                     ; "count", `Int count
                     ; "via", `String "docker"
                     ; "status", Keeper_alerting_path.process_status_to_json st
                     ; "entries", lines_to_json ~limit:50 out
                     ]))
          | None ->
            let st, out =
              Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec argv
            in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool (st = Unix.WEXITED 0)
                  ; "op", `String op
                  ; "cwd", `String cwd
                  ; "count", `Int count
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "entries", lines_to_json ~limit:50 out
                  ])))
  | "find" ->
    let name_pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if name_pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for find. Good: pattern='*.ml'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> path_error e
      | Ok target ->
        let limit = shell_readonly_limit args in
        if Keeper_docker_read.should_route_read ~meta then
          (match
             run_readonly_in_docker ~target
               ~command_argv:(fun cpath ->
                 [ "find"; cpath; "-maxdepth"; "5"; "-name"; name_pattern;
                   "-not"; "-path"; "*/.git/*";
                   "-not"; "-path"; "*/_build/*";
                   "-not"; "-path"; "*/.masc/*" ])
               ~max_bytes:1_000_000
               ~timeout_sec:read_timeout_sec
               ()
           with
           | Error response -> response
           | Ok (st, out) ->
             Yojson.Safe.to_string
               (`Assoc
                   [ "ok", `Bool true
                   ; "op", `String op
                   ; "path", `String target
                   ; "name", `String name_pattern
                   ; "via", `String "docker"
                   ; "status", Keeper_alerting_path.process_status_to_json st
                   ; "files", lines_to_json ~limit out
                   ]))
        else
          let st, out =
            run_argv_with_status_retry_eintr ~timeout_sec:read_timeout_sec
              [ "find"; target; "-maxdepth"; "5"; "-name"; name_pattern;
                "-not"; "-path"; "*/.git/*";
                "-not"; "-path"; "*/_build/*";
                "-not"; "-path"; "*/.masc/*" ]
          in
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool (st = Unix.WEXITED 0)
                ; "op", `String op
                ; "path", `String target
                ; "name", `String name_pattern
                ; "status", Keeper_alerting_path.process_status_to_json st
                ; "files", lines_to_json ~limit out
                ]))
  | "head" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let n = Safe_ops.json_int ~default:20 "lines" args |> fun v -> max 1 (min 200 v) in
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
              ~command_argv:(fun cpath ->
                [ "head"; "-n"; string_of_int n; cpath ])
              ~max_bytes:1_000_000
              ~timeout_sec:read_timeout_sec
              ()
          with
          | Error response -> response
          | Ok (st, out) ->
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool true
                  ; "op", `String op
                  ; "path", `String target
                  ; "lines", `Int n
                  ; "via", `String "docker"
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "content", `String out
                  ]))
       else
         let st, out =
           run_argv_with_status_retry_eintr ~timeout_sec:read_timeout_sec
             [ "/usr/bin/head"; "-n"; string_of_int n; target ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "lines", `Int n
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "content", `String out
               ]))
  | "tail" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let n = Safe_ops.json_int ~default:20 "lines" args |> fun v -> max 1 (min 200 v) in
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
              ~command_argv:(fun cpath ->
                [ "tail"; "-n"; string_of_int n; cpath ])
              ~max_bytes:1_000_000
              ~timeout_sec:read_timeout_sec
              ()
          with
          | Error response -> response
          | Ok (st, out) ->
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool true
                  ; "op", `String op
                  ; "path", `String target
                  ; "lines", `Int n
                  ; "via", `String "docker"
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "content", `String out
                  ]))
       else
         let st, out =
           run_argv_with_status_retry_eintr ~timeout_sec:read_timeout_sec
             [ "/usr/bin/tail"; "-n"; string_of_int n; target ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "lines", `Int n
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "content", `String out
               ]))
  | "wc" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
              ~command_argv:(fun cpath -> [ "wc"; "-l"; cpath ])
              ~max_bytes:4096
              ~timeout_sec:read_timeout_sec
              ()
          with
          | Error response -> response
          | Ok (st, out) ->
            Yojson.Safe.to_string
              (Exec_core.process_result_json
                 ~artifact_policy:Exec_core.Inline_only
                 ~base_path:root
                 ~keeper_name:meta.name
                 ~cmd:"wc"
                 ~extra:
                   [
                     "op", `String op;
                     "cmd", `String "wc";
                     "cwd", `Null;
                     "path", `String target;
                     "via", `String "docker";
                   ]
                 ~status:st
                 ~output:out
                 ()))
       else
         render_process_result ~cmd:"wc" [ "/usr/bin/wc"; "-l"; target ])
  | "tree" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
              ~command_argv:(fun cpath ->
                [ "find"; cpath; "-maxdepth"; "3"; "-print";
                  "-not"; "-path"; "*/.git/*";
                  "-not"; "-path"; "*/_build/*" ])
              ~max_bytes:1_000_000
              ~timeout_sec:read_timeout_sec
              ()
          with
           | Error response -> response
           | Ok (st, out) ->
             Yojson.Safe.to_string
               (`Assoc
                   [ "ok", `Bool true
                   ; "op", `String op
                   ; "path", `String target
                   ; "via", `String "docker"
                   ; "status", Keeper_alerting_path.process_status_to_json st
                   ; "entries", lines_to_json ~limit out
                   ]))
       else
         let st, out =
           run_argv_with_status_retry_eintr ~timeout_sec:read_timeout_sec
             [ "find"; target; "-maxdepth"; "3"; "-print";
               "-not"; "-path"; "*/.git/*";
               "-not"; "-path"; "*/_build/*" ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "entries", lines_to_json ~limit out
               ]))
  | "git_diff" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       run_in_turn_runtime ~cwd ~cmd:"git diff --stat"
         ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
         ~max_bytes:1_000_000 ~timeout_sec:read_timeout_sec ())
  | "git_worktree" ->
    let action =
      Safe_ops.json_string ~default:"list" "action" args
      |> String.trim |> String.lowercase_ascii
    in
    begin match action with
    | "list" ->
      (match cwd_target () with
       | Error e -> path_error e
       | Ok cwd ->
         run_in_turn_runtime ~cwd ~cmd:"git worktree list"
           ~map_output:hostify_turn_runtime_output
           ~command_argv:[ "git"; "worktree"; "list" ]
           ~max_bytes:1_000_000 ~timeout_sec:read_timeout_sec ())
    | "add" ->
      let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
      let base = Safe_ops.json_string ~default:"origin/main" "base" args |> String.trim in
      if branch = "" then
        error_json ~fields:[ "op", `String op ]
          "branch is required. Good: action='add', branch='feature/my-task'. Bad: branch=''."
      else (
        match cwd_target () with
        | Error e -> path_error e
        | Ok cwd ->
          let wt_out_result =
            match turn_sandbox_runtime with
            | Some runtime ->
              Keeper_turn_sandbox_runtime.run_command runtime
                ~cwd
                ~command_argv:[ "git"; "worktree"; "list"; "--porcelain" ]
                ~max_bytes:1_000_000
                ~timeout_sec:5.0 ()
            | None ->
              let _st, wt_out =
                run_argv_with_status_retry_eintr ~timeout_sec:5.0
                  [ "git"; "-C"; cwd; "worktree"; "list"; "--porcelain" ]
              in
              Ok wt_out
          in
          match wt_out_result with
          | Error msg ->
            error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
          | Ok wt_out ->
          if String_util.contains_substring_ci wt_out branch then
            let existing_path =
              String.split_on_char '\n' wt_out
              |> List.find_map (fun line ->
                if String_util.contains_substring_ci line "worktree"
                   && String_util.contains_substring_ci wt_out branch
                then Some (String.trim line) else None)
              |> Option.value ~default:"(unknown)"
            in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool false
                  ; "op", `String op
                  ; "error", `String "branch_already_in_worktree"
                  ; "branch", `String branch
                  ; "existing_worktree", `String existing_path
                  ; "hint", `String "Branch is already in a worktree. Use 'cd' to the existing path, or choose a different branch name."
                  ])
          else
            let wt_path = Printf.sprintf ".worktrees/%s"
              (String.map (fun c -> if c = '/' then '-' else c) branch)
            in
            run_in_turn_runtime ~cwd
              ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
              ~command_argv:[ "git"; "worktree"; "add"; wt_path; "-b"; branch; base ]
              ~max_bytes:1_000_000
              ~timeout_sec:io_timeout_sec ()
      )
    | other ->
      error_json ~fields:[ "op", `String op ]
        (Printf.sprintf "Unknown git_worktree action '%s'. Use: list, add." other)
    end
  | "bash" ->
    let cmd_str = Safe_ops.json_string ~default:"" "command" args |> String.trim in
    let timeout_sec = clamp_shell_timeout ~default:io_timeout_sec args in
    if cmd_str = "" then error_json ~fields:[ "op", `String op ] "command is required for bash op. Good: command='env'. Bad: command=''."

    else
      (* Non-overridable deny layer (runs after preset gate).
         First match wins — specific patterns before generic. *)
      let substring_rules =
        [ (* chaining *)
          "&&", "chaining"
        ; "||", "chaining"
        ; ";", "chaining"
        (* redirect *)
        ; "| tee ", "redirect"
        ; ">> ", "redirect"
        ; "> ", "redirect"
        ]
      in
      let matched =
        match List.find_opt (fun (pat, _cat) ->
          String_util.contains_substring_ci cmd_str pat
        ) substring_rules with
        | Some (pat, category) -> Some (pat, category)
        | None -> readonly_shell_token_match (lowercase_shell_words cmd_str)
      in
      (match matched with
      | Some (pat, category) ->
        let hint = readonly_hint_of_category category in
        Yojson.Safe.to_string
          (Exec_core.blocked_result_json
             ~cmd:cmd_str
             ~error:"command_blocked_readonly"
             ~reason:
               (Printf.sprintf
                  "Readonly shell blocked pattern '%s' in category '%s'."
                  pat category)
             ~hint
             ~diag:(diagnosis_of_readonly_category category)
             ~extra:
               [
                 "op", `String op;
                 "blocked_pattern", `String pat;
                 "category", `String category;
               ]
             ())
      | None ->
        (match cwd_target () with
         | Error e -> path_error e
         | Ok cwd ->
           (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd_str with
            | Error e -> path_error e
            | Ok () ->
              let st, out =
                match turn_sandbox_runtime with
                | Some runtime ->
                  (match
                     Keeper_turn_sandbox_runtime.run_bash_with_status runtime
                       ~cwd ~cmd:cmd_str ~timeout_sec ()
                   with
                   | Ok payload -> payload
                   | Error msg -> (Unix.WEXITED 127, msg))
                | None ->
                  run_argv_with_status_retry_eintr ~cwd ~timeout_sec
                    [ "bash"; "-lc"; cmd_str ^ " 2>&1" ]
              in
              if process_status_is_timeout st then
                Yojson.Safe.to_string
                  (Exec_core.process_result_json
                     ~artifact_policy:Exec_core.Inline_only
                     ~base_path:root
                     ~keeper_name:meta.name
                     ~cmd:cmd_str
                     ~extra:
                       [
                         "op", `String op;
                         "cwd", `String cwd;
                         "command", `String cmd_str;
                         "error", `String "command_timed_out";
                         "timeout_sec", `Float timeout_sec;
                       ]
                     ~status:st
                     ~output:out
                     ())
              else
                Yojson.Safe.to_string
                  (Exec_core.process_result_json
                     ~artifact_policy:Exec_core.Inline_only
                     ~base_path:root
                     ~keeper_name:meta.name
                     ~cmd:cmd_str
                     ~extra:
                       [
                         "op", `String op;
                         "cwd", `String cwd;
                         "command", `String cmd_str;
                       ]
                     ~status:st
                     ~output:out
                     ()))))
  | "git_clone" ->
    (* Clone a repo into this keeper's playground repos directory.
       Sandboxed: always targets .masc/playground/<keeper_name>/repos/<repo_name>.
       Validates against tool_policy.toml git_clone.allowed_orgs. *)
    let url = Safe_ops.json_string ~default:"" "url" args |> String.trim in
    if url = "" then
      error_json ~fields:[ "op", `String op ]
        "url is required for git_clone. Good: url='https://github.com/org/repo'. Bad: url=''."
    else
      let base_path = config.base_path in
      (match Tool_code_write.validate_clone_url ~base_path url with
       | Error reason ->
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool false
               ; "op", `String op
               ; "error", `String "clone_blocked"
               ; "reason", `String reason
               ; "url", `String url
               ])
       | Ok () ->
         let _bundle_paths = Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta in
         ignore (_bundle_paths : string list);
         let playground = keeper_playground_root ~config ~meta in
         let repos_dir = Filename.concat playground "repos" in
         Fs_compat.mkdir_p repos_dir;
         (* Derive repo name from URL: strip trailing slash, .git, then basename.
            Guard against empty/traversal names (e.g. url ending with "/" or ".."). *)
         let repo_name =
           let stripped =
             let s = String.trim url in
             if String.ends_with ~suffix:"/" s
             then String.sub s 0 (String.length s - 1) else s
           in
           let base = Filename.basename stripped in
           let name =
             if String.ends_with ~suffix:".git" base
             then String.sub base 0 (String.length base - 4)
             else base
           in
           (* Sanitize: only allow alphanumeric, hyphen, underscore, dot.
              Reject empty, ".", ".." to prevent traversal. *)
           let safe = String.map (fun c ->
             if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
             then c else '_') name
           in
           if safe = "" || safe = "." || safe = ".." then "repo" else safe
         in
         let clone_path = Filename.concat repos_dir repo_name in
         if Fs_compat.file_exists clone_path then
           (* Already cloned — pull latest instead *)
           let st, out =
             if meta.sandbox_profile = Docker then
               match
                 run_docker_shell_command_with_status ~config ~meta ~cwd:repos_dir
                   ~timeout_sec:60.0
                   ~cmd:(Printf.sprintf "git -C %s pull --ff-only"
                           (Filename.quote repo_name))
                   ~git_creds_enabled:true ~network_mode:Network_inherit
               with
               | Ok result -> (result.status, result.output)
               | Error msg -> (Unix.WEXITED 127, msg)
             else
               Process_eio.run_argv_with_status ~timeout_sec:60.0
                 [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
           in
           if st = Unix.WEXITED 0 then
             update_playground_repo_cache
               ~playground_dir:playground ~repo_name ~repo_path:clone_path
               ~action:"pull" ~shallow:false;
           Yojson.Safe.to_string
             (`Assoc
                 ([ "ok", `Bool (st = Unix.WEXITED 0)
                  ; "op", `String op
                  ; "action", `String "pull"
                  ; "path", `String clone_path
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "output", `String out
                  ]
                 @
                 (if meta.sandbox_profile = Docker then
                    [ "via", `String "docker" ]
                  else
                    [])))
         else
           let depth = Keeper_tool_policy.clone_depth () |> max 0 in
           let depth_args =
             if depth > 0 then ["--depth"; string_of_int depth] else []
           in
           let shallow = depth > 0 in
           let st, out =
             if meta.sandbox_profile = Docker then
               let clone_cmd =
                 String.concat " "
                   (List.map Filename.quote
                      ("git" :: "clone" :: depth_args @ [ url; repo_name ]))
               in
               match
                 run_docker_shell_command_with_status ~config ~meta ~cwd:repos_dir
                   ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
                   ~cmd:clone_cmd
                   ~git_creds_enabled:true ~network_mode:Network_inherit
               with
               | Ok result -> (result.status, result.output)
               | Error msg -> (Unix.WEXITED 127, msg)
             else
               Process_eio.run_argv_with_status
                 ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
                 ("git" :: "clone" :: depth_args @ [ url; clone_path ])
           in
           if st = Unix.WEXITED 0 then
             update_playground_repo_cache
               ~playground_dir:playground ~repo_name ~repo_path:clone_path
               ~action:"clone" ~shallow;
           Yojson.Safe.to_string
             (`Assoc
                 ([ "ok", `Bool (st = Unix.WEXITED 0)
                  ; "op", `String op
                  ; "action", `String "clone"
                  ; "path", `String clone_path
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "output", `String out
                  ]
                 @
                 (if meta.sandbox_profile = Docker then
                    [ "via", `String "docker" ]
                  else
                    []))))
  | "gh" ->
    let raw_cmd_str = Safe_ops.json_string ~default:"" "cmd" args in
    (* gh runs against remote network. Prior floors (1s, then 5s) kept
       firing gh_command_timed_out on plain read calls — 41 such
       rejections on 2026-04-17/18 (#8688), every single one at
       timeout_sec=5. GitHub API round-trip alone runs 1-8s even on
       small queries, and `gh` spends additional time on auth handshake
       and JSON encoding. Floor at 15s so the keeper LLM cannot request
       a sub-network-latency timeout; default remains the configured
       pr_create timeout (tool_policy.toml, default 30s). *)
    let gh_default_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
    let timeout_sec =
      clamp_shell_timeout ~min_sec:gh_min_timeout_sec ~default:gh_default_timeout args
    in
    if String.trim raw_cmd_str = "" then
      error_json ~fields:[ "op", `String op ]
        "cmd is required for gh op. Good: cmd='pr list --state open'. Bad: cmd=''."
    else (
      match Keeper_gh_shared.parse_simple_gh_command raw_cmd_str with
      | Error parse_error ->
        let reason =
          match parse_error with
          | Keeper_gh_shared.Empty_command -> "empty_command"
          | Keeper_gh_shared.Unsupported_shell_construct tag -> tag
          | Keeper_gh_shared.Unsupported_command_shape tag -> tag
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "op", `String op
              ; "error", `String "gh_command_shape_unsupported"
              ; "reason", `String reason
              ; "hint", `String
                 "keeper_shell op=gh only accepts one simple gh command. \
                   Avoid pipelines, redirects, env prefixes, and shell \
                   control syntax."
              ])
      | Ok parsed_cmd ->
        let allowed_orgs = Keeper_tool_policy.git_clone_allowed_orgs () in
        let canonical_cmd_str =
          Keeper_gh_shared.gh_simple_command_argv parsed_cmd
          |> String.concat " "
        in
        (* Reversibility gate (Thariq / Anthropic auto-mode principle):
           - R0 read / R1 reversible mutation: allowed; R1 is audit-logged.
           - R2 irreversible: rejected with a structured-tool hint so the
             LLM can self-recover toward an operator-approval path without
             a second round-trip. *)
        let reversibility =
          Worker_dev_tools.classify_gh_reversibility canonical_cmd_str
        in
        let rev_tag =
          Worker_dev_tools.string_of_gh_reversibility reversibility
        in
        let gh_cmd_display cmd =
          Printf.sprintf "gh %s"
            (Keeper_gh_shared.render_simple_gh_command cmd)
        in
        let gh_base ~ok ~cwd ~command extras =
          let route_fields =
            if meta.sandbox_profile = Docker then
              [ "via", `String "docker" ]
            else
              []
          in
          Yojson.Safe.to_string
            (`Assoc
                ([ "ok", `Bool ok
                 ; "op", `String op
                 ; "cwd", `String cwd
                 ; "command", `String command
                 ; "reversibility", `String rev_tag
                 ] @ route_fields @ extras))
        in
        let run_gh_command ~display_command ~parsed_command ~cwd
            ~(ctx : gh_repo_context option) =
          if reversibility = Worker_dev_tools.R1_Reversible then
            Log.Keeper.info
              "gh_audit: keeper=%s reversibility=R1 cwd=%s cmd=%s"
              meta.name cwd display_command;
          let gh_context_fields =
            match ctx with
            | Some ctx ->
              let repo_fields =
                match ctx.repo_slug with
                | Some repo_slug -> [ "repo", `String repo_slug ]
                | None -> []
              in
              [ "task_id", `String ctx.task_id
              ; "git_root", `String ctx.git_root
              ]
              @ repo_fields
            | None -> []
          in
          let gh_process =
            if meta.sandbox_profile = Docker then
              match
                run_docker_shell_command_with_status ~config ~meta ~cwd
                  ~timeout_sec ~cmd:display_command
                  ~git_creds_enabled:true ~network_mode:Network_inherit
              with
              | Ok result -> Ok (result.status, result.output)
              | Error msg -> Error msg
            else
              let env = Keeper_gh_env.process_env config in
              let gh_argv =
                "gh" :: Keeper_gh_shared.gh_simple_command_argv parsed_command
              in
              Ok (Process_eio.run_argv_with_status ?env ~cwd ~timeout_sec gh_argv)
          in
          match gh_process with
          | Error msg ->
            gh_base ~command:display_command ~ok:false ~cwd
              (gh_context_fields @ [ "error", `String msg ])
          | Ok (st, out) ->
            if process_status_is_timeout st then
              gh_base ~command:display_command ~ok:false ~cwd
                (gh_context_fields @
                [ "error", `String "gh_command_timed_out"
                ; "timeout_sec", `Float timeout_sec
                ; "status", Keeper_alerting_path.process_status_to_json st
                ; "output", `String out
                ; "hint", `String
                    "gh network call exceeded timeout_sec. Retry \
                     with a larger value — gh round-trip plus auth \
                     handshake is usually 3-10s, so prefer \
                     timeout_sec=30 or timeout_sec=60 rather than \
                     the 15s floor. You may also narrow the query \
                     (--state, --limit, --json)."
                ])
            else
              let ok = st = Unix.WEXITED 0 in
              let base_fields =
                gh_context_fields @
                [ "status", Keeper_alerting_path.process_status_to_json st
                ; "output", `String out ]
              in
              let hinted_fields =
                if (not ok)
                   && String_util.contains_substring_ci out
                        "Could not resolve to a Repository"
                then
                  base_fields @
                  [ "error", `String "gh_repo_resolve_failed"
                  ; "hint", `String
                      "gh is bound to the active task worktree repo. \
                       Ensure the linked sandbox clone still has a valid \
                       origin remote and recreate the task worktree if needed." ]
                else base_fields
              in
              gh_base ~command:display_command ~ok ~cwd hinted_fields
        in
        (match reversibility with
         | Worker_dev_tools.R2_Irreversible ->
           let hint =
             Option.value
               (Worker_dev_tools.structured_tool_hint_for_r2 canonical_cmd_str)
               ~default:
                 "This gh command mutates state that gh itself cannot \
                  restore. Route through the appropriate structured \
                  keeper tool or post on the board for operator approval."
           in
           Log.Keeper.warn
             "keeper_shell op=gh R2 blocked: %s (keeper=%s)"
             canonical_cmd_str meta.name;
           gh_base ~ok:false ~cwd:"" ~command:(gh_cmd_display parsed_cmd)
             [ "error", `String "gh_irreversible_blocked"
             ; "hint", `String hint ]
         | R0_Read | R1_Reversible ->
           begin
             match
               Worker_dev_tools.validate_gh_command
                 ~allowed_orgs canonical_cmd_str
             with
             | Error reason ->
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool false
                     ; "op", `String op
                     ; "error", `String "gh_command_blocked"
                     ; "reason", `String reason
                     ; "hint", `String
                         "Run `gh --help` shapes: pr/issue/repo/release/\
                         label/run/workflow/api/project/ruleset/search/\
                          status/cache/gist. auth/secret/ssh-key are blocked."
                     ])
             | Ok () ->
               (match resolve_keeper_shell_write_cwd ~config ~meta ~args with
                | Error e -> error_json e
                  | Ok gh_cwd ->
                  (match resolve_gh_repo_context ~config ~meta ~cwd:gh_cwd with
                   | Error err ->
                     gh_repo_context_error_json
                       ~op
                       ~cmd_display:(gh_cmd_display parsed_cmd) err
                   | Ok ctx ->
                     let cmd_to_run =
                       match ctx.repo_slug with
                       | Some repo_slug ->
                           Keeper_gh_shared.gh_simple_command_with_repo_flag
                             ~repo_slug parsed_cmd
                       | None -> parsed_cmd
                     in
                     run_gh_command
                       ~display_command:(gh_cmd_display cmd_to_run)
                       ~parsed_command:cmd_to_run
                       ~cwd:ctx.worktree_cwd
                       ~ctx:(Some ctx)))
           end))
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "error", `String "unsupported_op"
          ; "op", `String op
          ; ( "supported_ops"
              (* Issue #8524: derive from Variant SSOT instead of a
                 hand-rolled duplicate. *)
            , `List
                (List.map
                   (fun name -> `String name)
                   valid_shell_op_strings) )
          ])
;;
