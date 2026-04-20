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

let clamp_shell_timeout ?(min_sec = 1.0) ~default args =
  Safe_ops.json_float ~default "timeout_sec" args
  |> fun n -> max min_sec (min user_timeout_max_sec n)

let lowercase_shell_words text =
  text
  |> String.map (function '\t' | '\r' | '\n' -> ' ' | c -> c)
  |> String.lowercase_ascii
  |> String.split_on_char ' '
  |> List.filter (fun token -> token <> "")

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

let process_status_is_timeout = function
  | Unix.WSIGNALED sig_num -> sig_num = Sys.sigterm
  | Unix.WEXITED 124 -> true  (* Process_eio returns 124 on Eio.Time.Timeout *)
  | _ -> false

let shell_command_available name =
  let probe =
    Printf.sprintf "command -v %s >/dev/null 2>&1" (Filename.quote name)
  in
  match Process_eio.run_argv_with_status ~timeout_sec:2.0 [ "/bin/sh"; "-c"; probe ] with
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
    ignore (Fs_compat.save_file_atomic cache_path
      (Yojson.Safe.pretty_to_string json ^ "\n"))
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
  let playground_bundle = Playground_paths.bundle_root meta.name in
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

let keeper_sandbox_container_name (meta : keeper_meta) =
  Printf.sprintf "masc-keeper-%s-%d-%d"
    (Coord_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let keeper_private_container_root (meta : keeper_meta) =
  Keeper_sandbox.container_root meta.name

let docker_private_workspace_cwd ~(config : Coord.config) ~(meta : keeper_meta)
    host_cwd =
  let normalize_path_for_containment path =
    Keeper_alerting_path.normalize_path_for_check path
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let host_root =
    Filename.concat
      (Keeper_alerting_path.project_root_of_config config)
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
    |> normalize_path_for_containment
  in
  let container_root = keeper_private_container_root meta in
  let host_cwd = normalize_path_for_containment host_cwd in
  if host_cwd = host_root then
    container_root
  else if String.starts_with ~prefix:(host_root ^ "/") host_cwd then
    let suffix =
      String.sub host_cwd (String.length host_root + 1)
        (String.length host_cwd - String.length host_root - 1)
    in
    Filename.concat container_root suffix
  else
    container_root

let effective_sandbox_profile ~(meta : keeper_meta) ~in_playground =
  if meta.sandbox_profile = Legacy_local
     && Env_config_keeper.DockerPlayground.enabled
     && in_playground
  then
    (Docker_hardened, Network_inherit)
  else
    (meta.sandbox_profile, meta.network_mode)

let nested_container_runtime_tokens =
  [ "docker"; "podman"; "nerdctl"; "buildah" ]

let sandbox_socket_markers =
  [
    "/var/run/docker.sock";
    "/run/docker.sock";
    "/run/podman/podman.sock";
    "podman.sock";
    "containerd.sock";
    "buildkitd.sock";
  ]

let command_uses_nested_container_runtime cmd =
  let lowered_words = lowercase_shell_words cmd in
  let lowered_cmd = String.lowercase_ascii cmd in
  List.exists (fun token -> List.mem token nested_container_runtime_tokens)
    lowered_words
  || List.exists (String_util.contains_substring lowered_cmd) sandbox_socket_markers

let docker_info_security_options ~timeout_sec =
  let st, out =
    Process_eio.run_argv_with_status
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      [ "docker"; "info"; "--format"; "{{json .SecurityOptions}}" ]
  in
  if st <> Unix.WEXITED 0 then
    Error
      (Printf.sprintf "docker info failed while validating sandbox runtime: %s"
         (Worker_dev_tools.truncate_for_log out))
  else
    try
      match Yojson.Safe.from_string (String.trim out) with
      | `List items ->
          Ok
            (List.filter_map Yojson.Safe.Util.to_string_option items
            |> List.map String.lowercase_ascii)
      | `Null -> Ok []
      | _ ->
          Error
            "docker info returned unexpected SecurityOptions payload while validating sandbox runtime"
    with
    | Yojson.Json_error err ->
        Error
          (Printf.sprintf
             "failed to parse docker info SecurityOptions JSON: %s"
             err)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  let seccomp_profile =
    String.trim (Env_config_keeper.KeeperSandbox.seccomp_profile ())
  in
  let require_rootless = Env_config_keeper.KeeperSandbox.require_rootless () in
  let require_userns = Env_config_keeper.KeeperSandbox.require_userns () in
  let seccomp_args =
    if seccomp_profile = "" then
      Ok []
    else if Sys.file_exists seccomp_profile then
      Ok [ "--security-opt"; "seccomp=" ^ seccomp_profile ]
    else
      Error
        (Printf.sprintf
           "sandbox seccomp profile not found: %s"
           seccomp_profile)
  in
  match seccomp_args with
  | Error _ as err -> err
  | Ok seccomp_args ->
      if not require_rootless && not require_userns then
        Ok seccomp_args
      else
        match docker_info_security_options ~timeout_sec:(min 20.0 (max 5.0 timeout_sec)) with
        | Error _ as err -> err
        | Ok security_options ->
            let has needle =
              List.exists
                (fun option_text -> String_util.contains_substring option_text needle)
                security_options
            in
            if require_rootless && not (has "rootless") then
              Error
                "sandbox runtime requires Docker rootless mode (set MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS=false to disable this check)"
            else if require_userns && not (has "userns") then
              Error
                "sandbox runtime requires Docker userns support (set MASC_KEEPER_SANDBOX_REQUIRE_USERNS=false to disable this check)"
            else
              Ok seccomp_args

(* docker_with_git: leading-token check used by per-command dispatch.
   Returns true when the trimmed command's first whitespace-separated word
   is exactly "git" or "gh" (case-sensitive — both lowercase by convention).
   Subcommand args do not change the dispatch decision; e.g. "git push --force"
   still dispatches to docker_with_git, but the existing destructive-bash
   guard (Worker_dev_tools.is_destructive_bash_operation) already rejects
   force-push before this point. *)
let cmd_targets_git_or_gh cmd =
  let trimmed = String.trim cmd in
  let first_word =
    match String.index_opt trimmed ' ' with
    | Some i -> String.sub trimmed 0 i
    | None -> trimmed
  in
  match first_word with
  | "git" | "gh" -> true
  | _ -> false

(* Mount spec helper: only emit the -v flag when the host path is non-empty
   AND exists on disk. Missing files would cause docker to create them as
   directories, breaking gh / git config reads. *)
let optional_ro_mount ~host ~container =
  if host = "" then []
  else if not (Sys.file_exists host) then []
  else [ "-v"; host ^ ":" ^ container ^ ":ro" ]

let run_docker_with_git_bash
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(cwd : string)
    ~(timeout_sec : float)
    ~(cmd : string) =
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  let sandbox_error_json message =
    Keeper_registry.record_error ~base_path:config.base_path meta.name message;
    error_json message
  in
  if String.trim image = "" then
    sandbox_error_json "keeper sandbox docker image is not configured"
  else if command_uses_nested_container_runtime cmd then
    sandbox_error_json
      "docker_with_git blocks nested container runtimes and host socket references"
  else
    match ensure_keeper_sandbox_runtime ~timeout_sec with
    | Error err -> sandbox_error_json err
    | Ok seccomp_args ->
    let host_root =
      keeper_playground_root ~config ~meta
      |> Keeper_alerting_path.normalize_path_for_check
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    let container_name = keeper_sandbox_container_name meta in
    let container_root = keeper_private_container_root meta in
    let container_cwd = docker_private_workspace_cwd ~config ~meta cwd in
    let uid = Unix.getuid () in
    let gid = Unix.getgid () in
    let gh_creds = Env_config_keeper.KeeperSandbox.gh_creds_host_path () in
    let gitconfig = Env_config_keeper.KeeperSandbox.gitconfig_host_path () in
    let ssh_dir = Env_config_keeper.KeeperSandbox.ssh_dir_host_path () in
    let gh_token = Env_config_keeper.KeeperSandbox.gh_token () in
    let cred_mounts =
      optional_ro_mount ~host:gh_creds ~container:"/root/.config/gh"
      @ optional_ro_mount ~host:gitconfig ~container:"/root/.gitconfig"
      @ optional_ro_mount ~host:ssh_dir ~container:"/root/.ssh"
    in
    let token_env =
      if gh_token = "" then [] else [ "-e"; "GH_TOKEN=" ^ gh_token ]
    in
    let argv =
      [
        "docker";
        "run";
        "--rm";
        "--name";
        container_name;
        "-i";
        "--user";
        Printf.sprintf "%d:%d" uid gid;
        "--read-only";
        "--tmpfs";
        (Printf.sprintf "/tmp:rw,nosuid,nodev,noexec,size=%s"
           (Env_config_keeper.KeeperSandbox.tmpfs_size ()));
        "--cap-drop=ALL";
        "--security-opt";
        "no-new-privileges";
      ]
      @ seccomp_args
      @ [
        "--pids-limit";
        string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ());
        "--memory";
        Env_config_keeper.KeeperSandbox.memory ();
        "-v";
        host_root ^ ":" ^ container_root ^ ":rw";
        "--workdir";
        container_cwd;
        "--network";
        "bridge";
      ]
      @ cred_mounts
      @ token_env
      @ [ image; "bash"; "-lc"; cmd ^ " 2>&1" ]
    in
    let st, out =
      Process_eio.run_argv_with_status
        ~cwd:(Sys.getcwd ()) ~timeout_sec argv
    in
    if st <> Unix.WEXITED 0 then
      Keeper_registry.record_error ~base_path:config.base_path meta.name
        (Printf.sprintf "sandbox docker exec failed (%s): %s"
           image
           (Worker_dev_tools.truncate_for_log out))
    else
      Keeper_registry.clear_error ~base_path:config.base_path meta.name;
    Yojson.Safe.to_string
      (`Assoc
         [
           ("ok", `Bool (st = Unix.WEXITED 0));
           ("cwd", `String cwd);
           ("sandbox_profile", `String "docker_with_git");
           ("network_mode", `String "bridge");
           ("effective_sandbox_image", `String image);
           ("status", Keeper_alerting_path.process_status_to_json st);
           ("output", `String out);
         ])

let run_docker_hardened_bash
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(cwd : string)
    ~(timeout_sec : float)
    ~(cmd : string)
    ~(network_mode : network_mode) =
  let image = Env_config_keeper.KeeperSandbox.docker_image () in
  let sandbox_error_json message =
    Keeper_registry.record_error ~base_path:config.base_path meta.name message;
    error_json message
  in
  if String.trim image = "" then
    sandbox_error_json "keeper sandbox docker image is not configured"
  else if command_uses_nested_container_runtime cmd then
    sandbox_error_json
      "docker_hardened blocks nested container runtimes and host socket references"
  else
    match ensure_keeper_sandbox_runtime ~timeout_sec with
    | Error err -> sandbox_error_json err
    | Ok seccomp_args ->
    let host_root =
      keeper_playground_root ~config ~meta
      |> Keeper_alerting_path.normalize_path_for_check
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    let container_name = keeper_sandbox_container_name meta in
    let container_root = keeper_private_container_root meta in
    let container_cwd = docker_private_workspace_cwd ~config ~meta cwd in
    let uid = Unix.getuid () in
    let gid = Unix.getgid () in
    let network_args =
      match network_mode with
      | Network_none -> [ "--network"; "none" ]
      | Network_inherit -> []
    in
    let argv =
      [
        "docker";
        "run";
        "--rm";
        "--name";
        container_name;
        "-i";
        "--user";
        Printf.sprintf "%d:%d" uid gid;
        "--read-only";
        "--tmpfs";
        (Printf.sprintf "/tmp:rw,nosuid,nodev,noexec,size=%s"
           (Env_config_keeper.KeeperSandbox.tmpfs_size ()));
        "--cap-drop=ALL";
        "--security-opt";
        "no-new-privileges";
      ]
      @ seccomp_args
      @ [
        "--pids-limit";
        string_of_int (Env_config_keeper.KeeperSandbox.pids_limit ());
        "--memory";
        Env_config_keeper.KeeperSandbox.memory ();
        "-v";
        host_root ^ ":" ^ container_root ^ ":rw";
        "--workdir";
        container_cwd;
      ]
      @ network_args
      @ [ image; "bash"; "-lc"; cmd ^ " 2>&1" ]
    in
    let st, out =
      Process_eio.run_argv_with_status
        ~cwd:(Sys.getcwd ()) ~timeout_sec argv
    in
    if st <> Unix.WEXITED 0 then
      Keeper_registry.record_error ~base_path:config.base_path meta.name
        (Printf.sprintf "sandbox docker exec failed (%s): %s"
           image
           (Worker_dev_tools.truncate_for_log out))
    else
      Keeper_registry.clear_error ~base_path:config.base_path meta.name;
    Yojson.Safe.to_string
      (`Assoc
         [
           ("ok", `Bool (st = Unix.WEXITED 0));
           ("cwd", `String cwd);
           ("sandbox_profile", `String "docker_hardened");
           ("network_mode", `String (network_mode_to_string network_mode));
           ("effective_sandbox_image", `String image);
           ("status", Keeper_alerting_path.process_status_to_json st);
           ("output", `String out);
         ])

let handle_keeper_bash
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
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
       let counter_tag : Legendary_counters.gate_diff_tag =
         match diff with
         | Worker_dev_tools.Agree -> `Agree
         | Worker_dev_tools.Legacy_allow_shadow_deny ->
           `Legacy_allow_shadow_deny
         | Worker_dev_tools.Legacy_deny_shadow_allow ->
           `Legacy_deny_shadow_allow
         | Worker_dev_tools.Shadow_cannot_parse -> `Shadow_cannot_parse
       in
       Legendary_counters.incr_gate_diff counter_tag;
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
    let normalize_path_for_containment path =
      Keeper_alerting_path.normalize_path_for_check path
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    let cwd_canonical =
      normalize_path_for_containment cwd
    in
    let playground_rel =
      Keeper_alerting_path.playground_path_of_keeper meta.name
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
    (* docker_with_git per-command dispatch. Upgrades a Docker_hardened keeper
       to Docker_with_git when the command's leading token is git/gh, so the
       container gets bridge network + read-only credential mounts.
       Disabled when MASC_KEEPER_SANDBOX_GIT_DISPATCH=false. *)
    let sandbox_profile, sandbox_network_mode =
      if base_profile = Docker_hardened
         && Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled ()
         && cmd_targets_git_or_gh cmd
      then (Docker_with_git, Network_inherit)
      else (base_profile, base_network_mode)
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
           ~retryability:Exec_core.Operator_required
           ~extra:[ "cmd", `String cmd_for_log ]
           ()))
    else if sandbox_profile = Docker_with_git then (
      Log.Keeper.info
        "DOCKER_WITH_GIT_EXEC: keeper=%s cwd=%s cmd=%s"
        meta.name cwd cmd_for_log;
      run_docker_with_git_bash
        ~config ~meta ~cwd ~timeout_sec ~cmd)
    else if sandbox_profile = Docker_hardened then (
      Log.Keeper.info
        "DOCKER_HARDENED_EXEC: keeper=%s cwd=%s cmd=%s network=%s"
        meta.name cwd cmd_for_log (network_mode_to_string sandbox_network_mode);
      run_docker_hardened_bash
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
        Yojson.Safe.to_string
          (Exec_core.blocked_result_json
             ~cmd
             ~error:"command_blocked"
             ~reason:reason_str
             ~hint
             ())
      | Ok () ->
        (* Branch-switch guard *)
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
                  (Coding/Delivery/Full) and a playground clone. \
                  Clone into your playground first (keeper_shell op=git_clone), \
                  then set cwd to the cloned repo path."
               ~hint:(Printf.sprintf "Use cwd=%srepos/REPO" (Playground_paths.bundle_root meta.name))
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log ]
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
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log ]
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
                     must run with cwd inside your playground \
                     (%s). Open a worktree under \
                     your playground clone first via masc_worktree_create, \
                     then set cwd to the returned worktree path."
                    (Playground_paths.bundle_root meta.name))
               ~hint:(Printf.sprintf "cwd must start with %s" (Playground_paths.bundle_root meta.name))
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log; "cwd", `String cwd ]
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
                   let t0 =
                     if auto_bg_observe_enabled && not auto_bg_enabled
                     then Unix.gettimeofday ()
                     else 0.0
                   in
                   let st, out =
                     Process_eio.run_argv_with_status
                       ~cwd ~timeout_sec argv_merged
                   in
                   (if auto_bg_observe_enabled && not auto_bg_enabled then begin
                      let duration_ms =
                        int_of_float ((Unix.gettimeofday () -. t0) *. 1000.)
                      in
                      let budget_ms =
                        Masc_exec.Exec_run.default_budget_ms ()
                      in
                      let promoted_candidate = duration_ms >= budget_ms in
                      Legendary_counters.incr_auto_bg_observed
                        ~promoted_candidate;
                      if promoted_candidate then
                        Log.Keeper.info
                          "auto_bg_would_have_promoted keeper=%s \
                           cmd_hash=%s duration_ms=%d budget_ms=%d"
                          meta.name
                          (Worker_dev_tools.cmd_hash_for_log cmd)
                          duration_ms
                          budget_ms
                    end);
                   Yojson.Safe.to_string
                     (Exec_core.process_result_json
                        ~base_path:root
                        ~keeper_name:meta.name
                        ~cmd
                        ~extra:[ "cwd", `String cwd ]
                        ~status:st
                        ~output:out
                        ())
                 | Some clock ->
                   let budget_ms = Masc_exec.Exec_run.default_budget_ms () in
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
                      Yojson.Safe.to_string
                        (Exec_core.process_result_json
                           ~base_path:root
                           ~keeper_name:meta.name
                           ~cmd
                           ~extra:[ "cwd", `String cwd ]
                           ~status:r.status
                           ~output:r.stdout
                           ())
                    | Masc_exec.Exec_run.Promoted p ->
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

let status_to_json_opt = function
  | None -> `Null
  | Some st -> Keeper_alerting_path.process_status_to_json st

let handle_keeper_bash_output
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t) =
  let _ = config in
  let raw_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
  let since_stdout = Safe_ops.json_int ~default:0 "since_stdout" args in
  let since_stderr = Safe_ops.json_int ~default:0 "since_stderr" args in
  if raw_id = "" then
    error_json
      "task_id is required. Example: task_id='bgt-<timestamp>-<seq>-<pid>'."
  else
    let tid = Bg_task.task_id_of_string_exn raw_id in
    match Bg_task.read tid ~since_stdout ~since_stderr with
    | Error (Bg_task.Unknown_task _) ->
        error_json
          (Printf.sprintf
             "no background task with id=%s (already reaped or never spawned)"
             raw_id)
    | Error (Bg_task.Read_failed msg) ->
        error_json (Printf.sprintf "bash_output read failed: %s" msg)
    | Ok snap ->
        let tid_str = Bg_task.task_id_to_string tid in
        let semantic_fields =
          if not (Masc_exec.Exec_semantic.enabled ()) then []
          else match snap.status with
          | None -> []
          | Some st ->
              let merged = snap.stdout_since ^ snap.stderr_since in
              let sem =
                Masc_exec.Exec_semantic.interpret_cmd
                  ~cmd:"" ~status:st ~output:merged
              in
              [
                ( "return_code_interpretation",
                  match Masc_exec.Exec_semantic.to_hint sem with
                  | None -> `Null
                  | Some h -> `String h );
              ]
        in
        Log.Keeper.info
          "BG_OUTPUT: keeper=%s task_id=%s closed=%b"
          meta.name tid_str snap.closed;
        Yojson.Safe.to_string
          (`Assoc
            ([
               ("ok", `Bool true);
               ("task_id", `String tid_str);
               ("stdout_since", `String snap.stdout_since);
               ("stderr_since", `String snap.stderr_since);
               ("closed", `Bool snap.closed);
               ("status", status_to_json_opt snap.status);
               ("bytes_dropped_stdout", `Int snap.bytes_dropped_stdout);
               ("bytes_dropped_stderr", `Int snap.bytes_dropped_stderr);
             ]
             @ semantic_fields))

let signal_of_name_or_num args =
  match Safe_ops.json_string ~default:"" "signal" args |> String.uppercase_ascii with
  | "" | "TERM" | "SIGTERM" -> Sys.sigterm
  | "KILL" | "SIGKILL" -> Sys.sigkill
  | "INT" | "SIGINT" -> Sys.sigint
  | "HUP" | "SIGHUP" -> Sys.sighup
  | "QUIT" | "SIGQUIT" -> Sys.sigquit
  | raw ->
      (* Accept numeric form too. *)
      (try int_of_string raw with _ -> Sys.sigterm)

let handle_keeper_bash_kill
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t) =
  let _ = config in
  let raw_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
  let signal = signal_of_name_or_num args in
  let grace_sec =
    let raw = Safe_ops.json_float ~default:2.0 "grace_sec" args in
    if raw < 0.0 then 0.0
    else if raw > 30.0 then 30.0
    else raw
  in
  if raw_id = "" then
    error_json
      "task_id is required. Example: task_id='bgt-<timestamp>-<seq>-<pid>'."
  else
    let tid = Bg_task.task_id_of_string_exn raw_id in
    match Bg_task.kill tid ~signal ~grace_sec with
    | Error (Bg_task.Unknown_task_kill _) ->
        error_json
          (Printf.sprintf
             "no background task with id=%s (already reaped or never spawned)"
             raw_id)
    | Error (Bg_task.Kill_failed msg) ->
        error_json (Printf.sprintf "bash_kill failed: %s" msg)
    | Ok () ->
        let tid_str = Bg_task.task_id_to_string tid in
        Log.Keeper.info
          "BG_KILL: keeper=%s task_id=%s signal=%d grace=%.2f"
          meta.name tid_str signal grace_sec;
        Yojson.Safe.to_string
          (`Assoc
            [
              ("ok", `Bool true);
              ("task_id", `String tid_str);
              ("signal", `Int signal);
              ("grace_sec", `Float grace_sec);
            ])

let handle_keeper_shell
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
  (* RFC-0006 Phase B-1.5: pin host-FS read guard for hardened keeper
     shell read ops. No-op for legacy keepers and when
     MASC_KEEPER_SYMMETRIC_SANDBOX is off. *)
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
    actionable_path_error ~op ~keeper_name:meta.name ~raw_path ~error:e
  in
  let render_process_result ?cwd ~cmd argv =
    let st, out =
      Process_eio.run_argv_with_status ?cwd ~timeout_sec:io_timeout_sec argv
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
  match op with
  | "pwd" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd -> render_process_result ~cwd ~cmd:"pwd" [ "/bin/pwd" ])
  | "git_status" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       render_process_result ~cwd
         ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
         [ "git"; "-C"; cwd; "--no-optional-locks"; "status"; "--short"; "--branch" ])
  | "ls" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:io_timeout_sec [ "/bin/ls"; "-la"; target ]
       in
       let limit = shell_readonly_limit args in
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
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec [ "/bin/cat"; target ]
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
          Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec argv
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
       let base_argv =
         [ "git"; "-C"; cwd; "--no-optional-locks"; "log";
           Printf.sprintf "--format=%s" format;
           Printf.sprintf "-%d" count ]
       in
       let argv = if file_path <> "" then base_argv @ [ "--"; file_path ] else base_argv in
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
             ]))
  | "find" ->
    let name_pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if name_pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for find. Good: pattern='*.ml'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> path_error e
      | Ok target ->
        let limit = shell_readonly_limit args in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
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
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
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
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
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
       render_process_result ~cmd:"wc" [ "/usr/bin/wc"; "-l"; target ])
  | "tree" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:read_timeout_sec
           [ "find"; target; "-maxdepth"; "3"; "-print";
             "-not"; "-path"; "*/.git/*";
             "-not"; "-path"; "*/_build/*" ]
       in
       let limit = shell_readonly_limit args in
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
       render_process_result ~cwd
         ~cmd:"git diff --stat"
         [ "git"; "-C"; cwd; "--no-optional-locks"; "diff"; "--stat" ])
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
         render_process_result ~cwd ~cmd:"git worktree list"
           [ "git"; "-C"; cwd; "worktree"; "list" ])
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
          let _st, wt_out =
            Process_eio.run_argv_with_status ~timeout_sec:5.0
              [ "git"; "-C"; cwd; "worktree"; "list"; "--porcelain" ]
          in
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
            render_process_result ~cwd
              ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
              [ "git"; "-C"; cwd; "worktree"; "add"; wt_path; "-b"; branch; base ]
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
                Process_eio.run_argv_with_status ~cwd ~timeout_sec
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
         ignore (Keeper_alerting_path.ensure_playground_bundle ~config ~name:meta.name);
         let playground = Filename.concat root
           (Keeper_alerting_path.playground_path_of_keeper meta.name) in
         let repos_dir = Filename.concat root
           (Keeper_alerting_path.playground_repos_path meta.name) in
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
             Process_eio.run_argv_with_status ~timeout_sec:60.0
               [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
           in
           if st = Unix.WEXITED 0 then
             update_playground_repo_cache
               ~playground_dir:playground ~repo_name ~repo_path:clone_path
               ~action:"pull" ~shallow:false;
           Yojson.Safe.to_string
             (`Assoc
                 [ "ok", `Bool (st = Unix.WEXITED 0)
                 ; "op", `String op
                 ; "action", `String "pull"
                 ; "path", `String clone_path
                 ; "status", Keeper_alerting_path.process_status_to_json st
                 ; "output", `String out
                 ])
         else
           let depth = Keeper_tool_policy.clone_depth () |> max 0 in
           let depth_args =
             if depth > 0 then ["--depth"; string_of_int depth] else []
           in
           let shallow = depth > 0 in
           let st, out =
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
                 [ "ok", `Bool (st = Unix.WEXITED 0)
                 ; "op", `String op
                 ; "action", `String "clone"
                 ; "path", `String clone_path
                 ; "status", Keeper_alerting_path.process_status_to_json st
                 ; "output", `String out
                 ]))
  | "gh" ->
    let cmd_str =
      Safe_ops.json_string ~default:"" "cmd" args
      |> normalize_gh_command
    in
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
    if cmd_str = "" then
      error_json ~fields:[ "op", `String op ]
        "cmd is required for gh op. Good: cmd='pr list --state open'. Bad: cmd=''."
    else
      let allowed_orgs = Keeper_tool_policy.git_clone_allowed_orgs () in
      (* Reversibility gate (Thariq / Anthropic auto-mode principle):
         - R0 read / R1 reversible mutation: allowed; R1 is audit-logged.
         - R2 irreversible: rejected with a structured-tool hint so the
           LLM can self-recover toward an operator-approval path without
           a second round-trip. *)
      let reversibility = Worker_dev_tools.classify_gh_reversibility cmd_str in
      let rev_tag = Worker_dev_tools.string_of_gh_reversibility reversibility in
      let gh_cmd_display = Printf.sprintf "gh %s" cmd_str in
      let gh_base ~ok ~cwd extras =
        Yojson.Safe.to_string
          (`Assoc
              ([ "ok", `Bool ok
               ; "op", `String op
               ; "cwd", `String cwd
               ; "command", `String gh_cmd_display
               ; "reversibility", `String rev_tag
               ] @ extras))
      in
      (match reversibility with
       | Worker_dev_tools.R2_Irreversible ->
         let hint =
           Option.value
             (Worker_dev_tools.structured_tool_hint_for_r2 cmd_str)
             ~default:
               "This gh command mutates state that gh itself cannot \
                restore. Route through the appropriate structured \
                keeper tool or post on the board for operator approval."
         in
         Log.Keeper.warn
           "keeper_shell op=gh R2 blocked: %s (keeper=%s)"
           cmd_str meta.name;
         gh_base ~ok:false ~cwd:""
           [ "error", `String "gh_irreversible_blocked"
           ; "hint", `String hint ]
       | R0_Read | R1_Reversible ->
         (match Worker_dev_tools.validate_gh_command ~allowed_orgs cmd_str with
          | Error reason ->
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool false
                  ; "op", `String op
                  ; "error", `String "gh_command_blocked"
                  ; "reason", `String reason
                  ; "hint", `String
                      "Run `gh --help` shapes: pr/issue/repo/release/label/run/\
                       workflow/api/project/ruleset/search/status/cache/gist. \
                       auth/secret/ssh-key are blocked."
                  ])
          | Ok () ->
            (match cwd_target () with
             | Error e -> path_error e
             | Ok cwd ->
               if reversibility = Worker_dev_tools.R1_Reversible then
                 Log.Keeper.info
                   "gh_audit: keeper=%s reversibility=R1 cwd=%s cmd=gh %s"
                   meta.name cwd cmd_str;
               let full_cmd =
                 Keeper_gh_env.with_env config
                   (Printf.sprintf "gh %s 2>&1" cmd_str)
               in
               let st, out =
                 Process_eio.run_argv_with_status ~cwd ~timeout_sec
                   [ "bash"; "-lc"; full_cmd ]
               in
               if process_status_is_timeout st then
                 gh_base ~ok:false ~cwd
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
                   ]
               else
                 let ok = st = Unix.WEXITED 0 in
                 (* #8688: 37 repo-resolve rejects on 2026-04-17/18 came
                    back with "Could not resolve to a Repository". All
                    originated from keeper_shell op=gh run from a
                    playground cwd that has no upstream
                    (.masc/playground/<name>), so gh falls through to
                    the parent working dir and gives up. The keeper LLM
                    got only gh's raw stderr, which named the fake
                    repo but not the fix. Attach a concrete hint. *)
                 let base_fields =
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
                         "gh ran from a keeper playground cwd with no \
                          upstream remote, so it resolved the working \
                          directory name as the repository. Retry with \
                          an explicit `--repo OWNER/NAME` (e.g. \
                          `gh pr list --repo jeong-sik/masc-mcp \
                          --state open`), or git_clone the repo first \
                          and cd into the clone." ]
                   else base_fields
                 in
                 gh_base ~ok ~cwd hinted_fields)))
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
