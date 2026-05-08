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
  | Git_clone -> "git_clone"
  | Gh -> "gh"

let all_shell_ops =
  [ Pwd; Ls; Cat; Rg; Git_status; Find; Head; Tail; Wc; Tree;
    Git_log; Git_diff; Git_worktree; Git_clone; Gh ]

let valid_shell_op_strings = List.map shell_op_to_string all_shell_ops

(** Shell operation timeout constants.
    - [io_timeout_sec]: commands that may block on network/disk I/O
      (git status, gh, ls with large dirs).
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

(* Public shell metadata timeout used by git-status helpers. The playground
   repo-cache writer keeps its own copy in the lower-level coord module so
   Coord_worktree can update the same cache without depending on this file. *)
let git_meta_timeout_sec = env_float "MASC_KEEPER_GIT_META_TIMEOUT_SEC" 5.0

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
       Issue one command per keeper_bash call, or use a dedicated \
       keeper_shell sub-op: git_log, git_status, git_diff, \
       git_worktree, find, ls, rg, head, tail, wc, tree, cat, pwd. \
       Good: keeper_bash cmd='git status'. \
       Bad: keeper_bash cmd='git status && git log -1'."
  | "redirect" ->
      "Redirects (`>`, `>>`, `| tee`) are blocked in readonly shell. \
       Use keeper_fs_edit to write files, or keeper_bash with the \
       coding preset for write operations. \
       Good: keeper_fs_edit path=notes.md content='...'. \
       Bad: command='echo hi > notes.md'."
  | "git_write" ->
      "Use keeper_bash with coding preset for git write operations. \
       Good: keeper_bash cmd='git add lib/foo.ml'. \
       Bad: keeper_bash cmd='git commit -m x' without write access \
       does not accept git write commands)."
  | "package_install" ->
      "Package installation requires keeper_bash with coding preset. \
       Good: keeper_bash cmd='opam install -y eio'. \
       Bad: keeper_bash cmd='opam install eio' without write access \
       does not accept package installs)."
  | "destructive" ->
      "Use keeper_bash for write operations, not readonly shell. \
       Good: keeper_bash cmd='rm .tmp/scratch.log'. \
       Bad: keeper_bash cmd='rm -rf .tmp/' (readonly shell does \
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
                Some "Split into two calls: keeper_bash cmd='git status' \
                      then keeper_bash cmd='git log -1'."
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
    ~replacement:
      (Keeper_sandbox.host_root_abs_of_meta ~config meta
       |> Keeper_alerting_path.strip_trailing_slashes)
    text

let rewrite_docker_host_paths_to_container
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      text
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let container_root =
    Keeper_sandbox.container_root meta.name
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:raw_host_root ~container_root text
  in
  if String.equal raw_host_root normalized_host_root then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:normalized_host_root ~container_root rewritten

let run_argv_with_status_retry_eintr ?cwd ~timeout_sec argv =
  let max_eintr_retries = 8 in
  let rec loop attempts_left =
    let result =
      Masc_exec.Exec_gate.run_argv_with_status ~actor:`Keeper_shell
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper shell command" ?cwd ~timeout_sec argv
    in
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
  match
    run_argv_with_status_retry_eintr
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Shell_probe ())
      [ "/bin/sh"; "-c"; probe ]
  with
  | Unix.WEXITED 0, _ -> true
  | _ -> false

(** Write playground repo state cache after successful clone/pull.
    Reads git metadata from [repo_path] and upserts into
    [playground_dir/.playground_state.json]. Best-effort: failures are logged
    but do not propagate. *)
let update_playground_repo_cache
      ~(playground_dir : string) ~(repo_name : string) ~(repo_path : string)
      ~(action : string) ~(shallow : bool) : unit =
  Playground_repo_cache.update ~playground_dir ~repo_name ~repo_path ~action
    ~shallow

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
    if String.ends_with ~suffix:"/" playground_bundle
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
   reference Keeper_shell_shared.* directly (tests, doc refs). *)
let effective_sandbox_profile = Keeper_shell_docker.effective_sandbox_profile
let cmd_targets_git_or_gh = Keeper_shell_docker.cmd_targets_git_or_gh
let cmd_targets_gh cmd =
  let trimmed = String.trim cmd in
  let first_word =
    match String.index_opt trimmed ' ' with
    | Some i -> String.sub trimmed 0 i
    | None -> trimmed
  in
  String.equal first_word "gh"

let ensure_keeper_sandbox_runtime = Keeper_shell_docker.ensure_keeper_sandbox_runtime
let command_uses_nested_container_runtime = Keeper_shell_docker.command_uses_nested_container_runtime
let run_docker_shell_command_with_status = Keeper_shell_docker.run_docker_shell_command_with_status
let run_docker_with_git_bash = Keeper_shell_docker.run_docker_with_git_bash
let run_docker_hardened_bash = Keeper_shell_docker.run_docker_hardened_bash
