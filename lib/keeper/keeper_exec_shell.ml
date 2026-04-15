open Keeper_types
open Keeper_exec_shared

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
let docker_playground_cwd ~(config : Coord.config) ~(meta : keeper_meta) host_cwd =
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

let handle_keeper_bash
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let cmd_for_log =
    cmd
    |> Worker_dev_tools.sanitize_command_for_log
    |> Worker_dev_tools.truncate_for_log
  in
  let timeout_sec = clamp_shell_timeout ~default:io_timeout_sec args in
  (* Write access is config-driven via permissions.shell_write_presets *)
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  if cmd = ""
  then error_json "cmd is required. Good: cmd='ls -la lib/'. Bad: cmd=''."

  else
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
    let root = Keeper_alerting_path.project_root_of_config config in
    let playground_abs =
      normalize_path_for_containment (Filename.concat root playground_rel)
    in
    let in_playground =
      String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
      || String.equal playground_abs cwd_canonical
    in
    let use_docker =
      Env_config_keeper.DockerPlayground.enabled && in_playground
    in
    (* Destructive guard: always active regardless of Docker or preset *)
    if Worker_dev_tools.is_destructive_bash_operation cmd
    then (
      Log.Keeper.warn "keeper_bash DESTRUCTIVE blocked: %s (keeper=%s)" cmd_for_log meta.name;
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "destructive_operation_blocked"
            ; ( "reason"
              , `String
                  "This command is destructive (force push, push to main, rm -rf, \
                   etc.) and is blocked for all presets." )
            ; "cmd", `String cmd_for_log
            ]))
    else if use_docker then (
      (* Docker playground path: skip command whitelist and path validation.
         The container provides isolation — chaining, pipes, tee are safe.
         Only the destructive guard above is retained. *)
      Log.Keeper.info "DOCKER_EXEC: keeper=%s cwd=%s cmd=%s"
        meta.name cwd cmd_for_log;
      let container = Env_config_keeper.DockerPlayground.container_name in
      let container_cwd = docker_playground_cwd ~config ~meta cwd in
      let st, out =
        Process_eio.run_argv_with_status
          ~cwd:(Sys.getcwd ()) ~timeout_sec
          [ "docker"; "exec"; "-u"; "keeper";
            "-w"; container_cwd;
            container; "bash"; "-c"; cmd ^ " 2>&1" ]
      in
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool (st = Unix.WEXITED 0)
            ; "cwd", `String cwd
            ; "status", Keeper_alerting_path.process_status_to_json st
            ; "output", `String out
            ]))
    else
      (* Local execution path: full validation applies *)
      let validate =
        if write_enabled then Worker_dev_tools.validate_command_coding
        else Worker_dev_tools.validate_command
      in
      match validate cmd with
      | Error reason ->
        Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason cmd_for_log;
        let lower_cmd = String.lowercase_ascii (String.trim cmd) in
        let starts_with_gh =
          String.length lower_cmd >= 2
          && String.sub lower_cmd 0 2 = "gh"
          && (String.length lower_cmd = 2 || lower_cmd.[2] = ' ')
        in
        let hint =
          if String.length reason > 0 &&
             (Re.execp (Re.Pcre.re "chain|redirect|pipe|semicolon" |> Re.compile) (String.lowercase_ascii reason))
          then "Use separate tool calls instead of chaining. Call keeper_bash once per command."
          else if Re.execp (Re.Pcre.re "inject|symbol" |> Re.compile) (String.lowercase_ascii reason)
          then "Avoid shell metacharacters. Use keeper_shell with a specific op (rg, find, ls) instead."
          else if starts_with_gh
          then "Use keeper_shell op='gh' for GitHub CLI commands. \
                The keeper_bash allow-list intentionally excludes gh — \
                the keeper_shell path carries the auth/audit hooks. \
                Example: keeper_shell(op='gh', cmd='pr list')."
          else "Check the command for blocked patterns. Use keeper_shell for structured ops (rg, ls, find)."
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "command_blocked"
              ; "reason", `String reason
              ; "hint", `String hint
              ])
      | Ok () ->
        (* Branch-switch guard *)
        if Worker_dev_tools.is_git_branch_switch cmd
                && not (write_enabled && in_playground)
        then (
          Log.Keeper.info
            "keeper_bash branch-switch blocked: %s (keeper=%s, write_enabled=%b, playground=%b)"
            cmd_for_log meta.name write_enabled in_playground;
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "branch_switch_blocked"
                ; ( "reason"
                  , `String
                      "git checkout/switch/branch mutations require a write-enabled preset \
                       (Coding/Delivery/Full) and a playground clone. \
                       Clone into your playground first (keeper_shell op=git_clone), \
                       then set cwd to the cloned repo path." )
                ; "cmd", `String cmd_for_log
                ; "hint", `String (Printf.sprintf "Use cwd=%srepos/REPO" (Playground_paths.bundle_root meta.name))
                ]))
        (* Write gate — preset layer *)
        else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
        then (
          Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s, playground=%b)"
            cmd_for_log meta.name in_playground;
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "write_operation_gated"
                ; ( "reason"
                  , `String
                      "This command modifies state (git push/commit, make deploy, etc.). \
                       A write-enabled preset (Coding/Delivery/Full) is required." )
                ; "cmd", `String cmd_for_log
                ]))
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
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "write_outside_playground_blocked"
                ; ( "reason"
                  , `String
                      (Printf.sprintf
                         "Write operations (git push/commit, make deploy, etc.) \
                          must run with cwd inside your playground \
                          (%s). Open a worktree under \
                          your playground clone first via masc_worktree_create, \
                          then set cwd to the returned worktree path."
                         (Playground_paths.bundle_root meta.name)) )
                ; "cmd", `String cmd_for_log
                ; "cwd", `String cwd
                ; "hint", `String (Printf.sprintf "cwd must start with %s" (Playground_paths.bundle_root meta.name))
                ]))
        else (
            (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd with
             | Error e -> error_json e
             | Ok () ->
               if write_enabled
                  && Worker_dev_tools.is_write_operation cmd then
                 Log.Keeper.info "WRITE_AUDIT: keeper=%s cwd=%s cmd=%s playground=%b"
                   meta.name cwd cmd_for_log in_playground;
               let st, out =
                 Process_eio.run_argv_with_status ~cwd ~timeout_sec
                   [ "/bin/bash"; "-lc"; cmd ^ " 2>&1" ]
               in
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool (st = Unix.WEXITED 0)
                     ; "cwd", `String cwd
                     ; "status", Keeper_alerting_path.process_status_to_json st
                     ; "output", `String out
                     ])))
;;

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
  let read_target () = resolve_keeper_shell_read_path ~config ~meta ~args in
  let cwd_target () = resolve_keeper_shell_read_cwd ~config ~meta ~args in
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
      (`Assoc
          [ "ok", `Bool (st = Unix.WEXITED 0)
          ; "op", `String op
          ; "cmd", `String cmd
          ; ( "cwd"
            , match cwd with
              | Some dir -> `String dir
              | None -> `Null )
          ; "status", Keeper_alerting_path.process_status_to_json st
          ; "output", `String out
          ])
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
      let hint_of_category = function
        | "chaining"        -> "Call the tool multiple times instead of chaining commands."
        | "redirect"        -> "Redirects are not allowed. Use keeper_fs_edit to write files."
        | "git_write"       -> "Use keeper_bash with coding preset for git write operations."
        | "package_install" -> "Package installation requires keeper_bash with coding preset."
        | "destructive"     -> "Use keeper_bash for write operations, not readonly shell."
        | _                 -> "This operation is not allowed in readonly shell."
      in
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
        let hint = hint_of_category category in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "op", `String op
              ; "error", `String "command_blocked_readonly"
              ; "blocked_pattern", `String pat
              ; "category", `String category
              ; "hint", `String hint
              ])
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
                  (`Assoc
                      [ "ok", `Bool false
                      ; "op", `String op
                      ; "cwd", `String cwd
                      ; "command", `String cmd_str
                      ; "error", `String "command_timed_out"
                      ; "timeout_sec", `Float timeout_sec
                      ; "status", Keeper_alerting_path.process_status_to_json st
                      ; "output", `String out
                      ; "hint", `String "Narrow the scope or use structured ops like rg/find/ls instead of broad bash scans."
                      ])
              else
                Yojson.Safe.to_string
                  (`Assoc
                      [ "ok", `Bool (st = Unix.WEXITED 0)
                      ; "op", `String op
                      ; "cwd", `String cwd
                      ; "command", `String cmd_str
                      ; "status", Keeper_alerting_path.process_status_to_json st
                      ; "output", `String out
                      ]))))
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
    (* gh runs against remote network, so 1s floor from shell default is
       too aggressive (observed: keepers passing timeout_sec=1 kills
       [gh pr create] mid-TCP). Floor at 5s and default at the configured
       pr_create timeout (tool_policy.toml, default 30s). *)
    let gh_default_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
    let timeout_sec =
      clamp_shell_timeout ~min_sec:5.0 ~default:gh_default_timeout args
    in
    if cmd_str = "" then
      error_json ~fields:[ "op", `String op ]
        "cmd is required for gh op. Good: cmd='pr list --state open'. Bad: cmd=''."
    else
      let allowed_orgs = Keeper_tool_policy.git_clone_allowed_orgs () in
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
            let full_cmd =
              Keeper_gh_env.with_env config
                (Printf.sprintf "gh %s 2>&1" cmd_str)
            in
            let st, out =
              Process_eio.run_argv_with_status ~cwd ~timeout_sec
                [ "bash"; "-lc"; full_cmd ]
            in
            if process_status_is_timeout st then
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool false
                    ; "op", `String op
                    ; "cwd", `String cwd
                    ; "command", `String (Printf.sprintf "gh %s" cmd_str)
                    ; "error", `String "gh_command_timed_out"
                    ; "timeout_sec", `Float timeout_sec
                    ; "status", Keeper_alerting_path.process_status_to_json st
                    ; "output", `String out
                    ; "hint", `String
                        "gh network call exceeded timeout_sec. Retry with a \
                         larger value (e.g. timeout_sec=60) or narrow the \
                         query (--state, --limit, --json)."
                    ])
            else
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool (st = Unix.WEXITED 0)
                    ; "op", `String op
                    ; "cwd", `String cwd
                    ; "command", `String (Printf.sprintf "gh %s" cmd_str)
                    ; "status", Keeper_alerting_path.process_status_to_json st
                    ; "output", `String out
                    ])))
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "error", `String "unsupported_op"
          ; "op", `String op
          ; ( "supported_ops"
            , `List
                (List.map
                   (fun name -> `String name)
                   [ "pwd"; "ls"; "cat"; "rg"; "git_status";
                     "find"; "head"; "tail"; "wc"; "tree";
                     "git_log"; "git_diff"; "git_worktree"; "bash";
                     "git_clone"; "gh" ]) )
          ])
;;
