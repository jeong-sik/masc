(** Development tools for autonomous agent coding.

    Provides file_read, file_write, shell_exec so Fleet agents
    can perform local development tasks (code generation, test runs,
    file modifications).

    file_read/file_write use OCaml stdlib (no Eio filesystem capability needed).
    shell_exec uses Eio.Process with fiber-based timeout. *)

(* --- Safety validation --- *)

(** Resolve '.' and '..' segments in a path without filesystem access.
    This prevents path traversal attacks like /tmp/../../etc/passwd. *)
let normalize_path ?base_dir path =
  let abs =
    if Filename.is_relative path then
      Filename.concat
        (Option.value ~default:(Sys.getcwd ()) base_dir)
        path
    else path
  in
  let parts = String.split_on_char '/' abs in
  let resolved = List.fold_left (fun acc part ->
    match part with
    | "" | "." -> acc
    | ".." -> (match acc with [] -> [] | _ :: rest -> rest)
    | s -> s :: acc
  ) [] parts in
  "/" ^ String.concat "/" (List.rev resolved)

(** Split a target path into the deepest existing ancestor and the missing
    segments below it. This lets us resolve symlinks in the existing prefix
    while still validating paths that don't exist yet. *)
let rec split_existing_path path missing =
  if Sys.file_exists path then (path, missing)
  else
    let parent = Filename.dirname path in
    if parent = path then (path, missing)
    else split_existing_path parent (Filename.basename path :: missing)

(** Resolve symlinks in the existing prefix of a path and then append the
    remaining missing path segments lexically. *)
let resolve_path ?base_dir path =
  let abs = normalize_path ?base_dir path in
  let existing_prefix, missing_segments = split_existing_path abs [] in
  let resolved_prefix =
    try Unix.realpath existing_prefix |> normalize_path
    with Unix.Unix_error _ -> normalize_path existing_prefix
  in
  List.fold_left Filename.concat resolved_prefix missing_segments
  |> normalize_path

(** Check whether [path] is exactly [dir] or a descendant of [dir]. *)
let is_within_dir ~dir path =
  path = dir
  || String.starts_with ~prefix:(dir ^ "/") path

(** Path allowlist. When workdir is set, restrict to workdir + /tmp only.
    When unset, allow /tmp, cwd subtree, and ~/me subtree (backward compat). *)
let validate_path ?workdir path =
  let resolved = resolve_path ?base_dir:workdir path in
  match workdir with
  | Some wd ->
    let resolved_wd = resolve_path wd in
    is_within_dir ~dir:(resolve_path "/tmp") resolved
    || is_within_dir ~dir:resolved_wd resolved
  | None ->
    is_within_dir ~dir:(resolve_path "/tmp") resolved
    || is_within_dir ~dir:(resolve_path (Sys.getcwd ())) resolved
    || (match Sys.getenv_opt "HOME" with
        | Some home -> is_within_dir ~dir:(resolve_path (Filename.concat home "me")) resolved
        | None -> false)

(** shell_exec intentionally supports only a narrow allowlist of dev/test
    commands and rejects shell control syntax to keep execution predictable. *)
let dev_allowed_commands =
  [
    "cat"; "cargo"; "cmake"; "cut"; "dune"; "echo"; "env"; "file"; "find";
    "git"; "go"; "gofmt"; "gradle"; "grep"; "head"; "java"; "javac"; "ls";
    "make"; "mvn"; "node"; "npm"; "ninja"; "npx"; "opam"; "pip"; "pnpm";
    "printf"; "pwd"; "pyright"; "pytest"; "python"; "python3"; "rg"; "ruff";
    "rustc"; "sed"; "sort"; "stat"; "tail"; "tr"; "uniq"; "uv"; "wc";
    "which"; "yarn";
  ]

let readonly_allowed_commands =
  [
    "cat"; "cut"; "echo"; "env"; "file"; "find"; "grep"; "head"; "ls";
    "printf"; "pwd"; "rg"; "sed"; "sort"; "stat"; "tail"; "tr"; "uniq";
    "wc"; "which";
  ]

let forbidden_shell_chars =
  [ ';'; '|'; '&'; '>'; '<'; '`'; '$'; '\n'; '\r' ]

let contains_forbidden_shell_chars cmd =
  String.exists (fun ch -> List.mem ch forbidden_shell_chars) cmd

let extract_command_name cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then None
  else
    let len = String.length trimmed in
    let rec find_sep i =
      if i >= len then len
      else
        match trimmed.[i] with
        | ' ' | '\t' -> i
        | _ -> find_sep (i + 1)
    in
    let token = String.sub trimmed 0 (find_sep 0) in
    Some (Filename.basename token)

let validate_command_with_allowlist ~allowed_commands cmd =
  let trimmed = String.trim cmd in
  if trimmed = "" then Error "command must not be empty"
  else if contains_forbidden_shell_chars trimmed then
    Error
      "Shell chaining/redirection is not allowed. Use the workdir field and run a single command, for example command='python3 check.py'."
  else
    match extract_command_name trimmed with
    | None -> Error "command must not be empty"
    | Some name when List.mem name allowed_commands -> Ok ()
    | Some name ->
      Error
        (Printf.sprintf
           "Command blocked: %s is not in the approved dev command allowlist"
           name)

let validate_command cmd =
  validate_command_with_allowlist ~allowed_commands:dev_allowed_commands cmd

(** Check if a command performs write/mutating operations.
    Returns [true] for commands like [git push], [git commit],
    [make deploy], [npm publish], [mv], [cp], etc.
    Read-only commands (git status, dune build, rg) return [false]. *)
let is_write_operation cmd =
  let parts = String.split_on_char ' ' (String.trim cmd) in
  match parts with
  | "git" :: sub :: _ ->
    List.mem sub ["push"; "commit"; "merge"; "rebase"; "reset";
                  "checkout"; "branch"; "tag"; "stash"]
  | "dune" :: sub :: _ ->
    List.mem sub ["clean"; "promote"]
  | "make" :: sub :: _ ->
    List.mem sub ["clean"; "deploy"; "install"; "publish"]
  | ("npm" | "pnpm" | "yarn") :: sub :: _ ->
    List.mem sub ["add"; "install"; "link"; "prune"; "publish"; "remove"; "unlink"; "update"; "up"]
  | cmd_name :: _ ->
    List.mem cmd_name ["mv"; "cp"; "mkdir"; "touch"; "chmod"]
  | [] -> false

(* --- Recursive mkdir --- *)

let mkdir_p path _perm =
  Fs_compat.mkdir_p path

type tool_exec_observer =
  tool_name:string -> success:bool -> duration_ms:int -> unit

(* --- Tool implementations --- *)

let make_file_read ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_read"
    ~descriptor:{ kind = None; mutation_class = Some "read_only";
                  shell = None; notes = []; examples = [] }
    ~description:"Read file contents by absolute path. Returns file text. \
      Use shell_exec with 'ls' instead if you need directory listing. \
      Maximum 100KB per read to prevent context overflow."
    ~parameters:[
      { name = "path";
        description = "Absolute file path to read";
        param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Worker_tool_input.extract_string "path" input with
       | Error e ->
         Error { Agent_sdk.Types.message = e; recoverable = false }
       | Ok path ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path) then
           let err =
             Printf.sprintf "Path blocked: %s (outside allowed directories)" path
           in
           let duration_ms =
             int_of_float ((Time_compat.now () -. started) *. 1000.0)
           in
           Option.iter
             (fun f -> f ~tool_name:"file_read" ~success:false ~duration_ms)
             on_exec;
           Error { Agent_sdk.Types.message = err; recoverable = false }
         else
           try
             let content = In_channel.with_open_text resolved_path In_channel.input_all in
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_read" ~success:true ~duration_ms)
               on_exec;
             if String.length content > 100_000 then
               Ok { Agent_sdk.Types.content =
                 String.sub content 0 100_000 ^ "\n[TRUNCATED at 100KB]" }
             else Ok { Agent_sdk.Types.content = content }
           with Sys_error msg ->
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_read" ~success:false ~duration_ms)
               on_exec;
             Error { Agent_sdk.Types.message =
               Printf.sprintf "Cannot read: %s" msg; recoverable = false })

let make_file_write ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_write"
    ~descriptor:{ kind = None; mutation_class = Some "workspace";
                  shell = None; notes = []; examples = [] }
    ~description:"Write content to a file by absolute path. Creates the file \
      if it doesn't exist, overwrites if it does. Creates parent directories. \
      Use file_read first to check existing content before overwriting."
    ~parameters:[
      { name = "path";
        description = "Absolute file path to write";
        param_type = Agent_sdk.Types.String; required = true };
      { name = "content";
        description = "Content to write to the file";
        param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Worker_tool_input.extract_string "path" input,
             Worker_tool_input.extract_string "content" input with
       | Error e, _ | _, Error e ->
         Error { Agent_sdk.Types.message = e; recoverable = false }
       | Ok path, Ok content ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path) then
           let err =
             Printf.sprintf "Path blocked: %s (outside allowed directories)" path
           in
           let duration_ms =
             int_of_float ((Time_compat.now () -. started) *. 1000.0)
           in
           Option.iter
             (fun f -> f ~tool_name:"file_write" ~success:false ~duration_ms)
             on_exec;
           Error { Agent_sdk.Types.message = err; recoverable = false }
         else
           try
             mkdir_p (Filename.dirname resolved_path) 0o755;
             Out_channel.with_open_text resolved_path
               (fun oc -> Out_channel.output_string oc content);
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_write" ~success:true ~duration_ms)
               on_exec;
             Ok { Agent_sdk.Types.content =
               Printf.sprintf "Written %d bytes to %s"
                 (String.length content) resolved_path }
           with Sys_error msg ->
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f -> f ~tool_name:"file_write" ~success:false ~duration_ms)
               on_exec;
             Error { Agent_sdk.Types.message =
               Printf.sprintf "Cannot write: %s" msg; recoverable = false })

let make_shell_exec_with_allowlist ~workdir ~on_exec ~proc_mgr ~clock ~allowed_commands
    ?(mutation_class = "workspace") ~description () =
  Agent_sdk.Tool.create
    ~name:"shell_exec"
    ~descriptor:{ kind = None; mutation_class = Some mutation_class;
                  shell = None; notes = []; examples = [] }
    ~description
    ~parameters:[
      { name = "command";
        description = "Shell command to execute";
        param_type = Agent_sdk.Types.String; required = true };
      { name = "timeout_s";
        description = "Timeout in seconds (default 30, max 120)";
        param_type = Agent_sdk.Types.Number; required = false };
    ]
    (fun input ->
       match Worker_tool_input.extract_string "command" input with
       | Error e ->
         Error { Agent_sdk.Types.message = e; recoverable = false }
       | Ok command ->
         (match validate_command_with_allowlist ~allowed_commands command with
          | Error e ->
            Error { Agent_sdk.Types.message = e; recoverable = false }
          | Ok () ->
           let timeout =
             Worker_tool_input.extract_float "timeout_s" input
             |> Option.value ~default:30.0
             |> Float.min 120.0
          in
           try
             let started = Time_compat.now () in
             let buf = Buffer.create 1024 in
             let wrapped_command =
               match workdir with
               | Some dir when String.trim dir <> "" ->
                   Printf.sprintf "cd %s && %s" (Filename.quote dir) command
               | _ -> command
             in
             let result =
               try
                 let status, output =
                   Eio.Time.with_timeout_exn clock timeout (fun () ->
                     Eio.Switch.run @@ fun sw ->
                     let proc = Eio.Process.spawn ~sw proc_mgr
                       ~stdout:(Eio.Flow.buffer_sink buf)
                       ["sh"; "-c"; wrapped_command ^ " 2>&1"] in
                     let status = Eio.Process.await proc in
                     (status, Buffer.contents buf))
                 in
                 match status with
                 | `Exited 0 ->
                   Ok { Agent_sdk.Types.content = output }
                 | `Exited code ->
                   Error { Agent_sdk.Types.message =
                     Printf.sprintf "Exit code %d:\n%s" code output;
                     recoverable = false }
                 | `Signaled sig_num ->
                   Error { Agent_sdk.Types.message =
                     Printf.sprintf "Killed by signal %d:\n%s" sig_num output;
                     recoverable = sig_num = Sys.sigterm }
               with
               | Eio.Time.Timeout ->
                 let output = Buffer.contents buf in
                 Error { Agent_sdk.Types.message =
                   Printf.sprintf "Timeout after %.0fs: %s\n%s" timeout command
                     output;
                   recoverable = true }
             in
             let duration_ms =
               int_of_float ((Time_compat.now () -. started) *. 1000.0)
             in
             Option.iter
               (fun f ->
                 f ~tool_name:"shell_exec"
                   ~success:(Result.is_ok result) ~duration_ms)
               on_exec;
             result
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             let duration_ms = 0 in
             Option.iter
               (fun f -> f ~tool_name:"shell_exec" ~success:false ~duration_ms)
               on_exec;
             Error { Agent_sdk.Types.message =
               Printf.sprintf "Command failed: %s" (Printexc.to_string exn);
               recoverable = false }))

let make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist ~workdir ~on_exec ~proc_mgr ~clock
    ~allowed_commands:dev_allowed_commands
    ~description:
      "Execute a shell command and return stdout+stderr. \
       Timeout: 30s default, max 120s. \
       Use for: running tests, git commands, build tools, directory listing. \
       Unlike file_read (single file), this handles approved CLI operations. \
       Commands run in /bin/sh but shell control syntax is rejected."
    ()

let make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist ~workdir ~on_exec ~proc_mgr ~clock
    ~allowed_commands:readonly_allowed_commands
    ~mutation_class:"read_only"
    ~description:
      "Execute a read-only shell command and return stdout+stderr. \
       Timeout: 30s default, max 120s. \
       Use for search, inspection, and verification only. \
       Write-oriented commands are intentionally excluded."
    ()

(** Create dev tools that close over Eio capabilities.
    Returns [file_read; file_write; shell_exec]. *)
let make_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ();
    make_file_write ?workdir ?on_exec ();
    make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock ]

let make_readonly_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ();
    make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock ]
