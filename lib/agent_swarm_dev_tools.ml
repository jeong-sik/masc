(** Development tools for autonomous agent coding.

    Provides file_read, file_write, shell_exec so Fleet agents
    can perform local development tasks (code generation, test runs,
    file modifications).

    file_read/file_write use OCaml stdlib (no Eio filesystem capability needed).
    shell_exec uses Eio.Process with fiber-based timeout. *)

(* --- Safety validation --- *)

(** Resolve '.' and '..' segments in a path without filesystem access.
    This prevents path traversal attacks like /tmp/../../etc/passwd. *)
let normalize_path path =
  let abs =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
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
let resolve_path path =
  let abs = normalize_path path in
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
  let resolved = resolve_path path in
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

(** Command blocklist: reject destructive patterns. *)
let blocked_patterns =
  ["rm -rf /"; "mkfs"; "dd if="; "> /dev/"; ":(){ :|:& };:"]

let validate_command cmd =
  let cmd_lower = String.lowercase_ascii cmd in
  not (List.exists (fun pat ->
    let pat_lower = String.lowercase_ascii pat in
    (* Simple substring check — no regex needed for these patterns *)
    let pat_len = String.length pat_lower in
    let cmd_len = String.length cmd_lower in
    if pat_len > cmd_len then false
    else
      let found = ref false in
      for i = 0 to cmd_len - pat_len do
        if String.sub cmd_lower i pat_len = pat_lower then found := true
      done;
      !found
  ) blocked_patterns)

(* --- Recursive mkdir --- *)

let rec mkdir_p path perm =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if parent <> path then mkdir_p parent perm;
    (try Unix.mkdir path perm with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

(* --- Tool implementations --- *)

let make_file_read ?workdir () =
  Agent_sdk.Tool.create
    ~name:"file_read"
    ~description:"Read file contents by absolute path. Returns file text. \
      Use shell_exec with 'ls' instead if you need directory listing. \
      Maximum 100KB per read to prevent context overflow."
    ~parameters:[
      { name = "path";
        description = "Absolute file path to read";
        param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Agent_swarm_tool_input.extract_string "path" input with
       | Error e -> Error e
       | Ok path ->
         let resolved_path = resolve_path path in
         if not (validate_path ?workdir resolved_path) then
           Error (Printf.sprintf
             "Path blocked: %s (outside allowed directories)" path)
         else
           try
             let content = In_channel.with_open_text resolved_path In_channel.input_all in
             if String.length content > 100_000 then
               Ok (String.sub content 0 100_000 ^ "\n[TRUNCATED at 100KB]")
             else Ok content
           with Sys_error msg ->
             Error (Printf.sprintf "Cannot read: %s" msg))

let make_file_write ?workdir () =
  Agent_sdk.Tool.create
    ~name:"file_write"
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
       match Agent_swarm_tool_input.extract_string "path" input,
             Agent_swarm_tool_input.extract_string "content" input with
       | Error e, _ | _, Error e -> Error e
       | Ok path, Ok content ->
         let resolved_path = resolve_path path in
         if not (validate_path ?workdir resolved_path) then
           Error (Printf.sprintf
             "Path blocked: %s (outside allowed directories)" path)
         else
           try
             mkdir_p (Filename.dirname resolved_path) 0o755;
             Out_channel.with_open_text resolved_path
               (fun oc -> Out_channel.output_string oc content);
             Ok (Printf.sprintf "Written %d bytes to %s"
               (String.length content) resolved_path)
           with Sys_error msg ->
             Error (Printf.sprintf "Cannot write: %s" msg))

let make_shell_exec ~proc_mgr ~clock =
  Agent_sdk.Tool.create
    ~name:"shell_exec"
    ~description:"Execute a shell command and return stdout+stderr. \
      Timeout: 30s default, max 120s. \
      Use for: running tests, git commands, build tools, directory listing. \
      Unlike file_read (single file), this handles any CLI operation. \
      Commands run in /bin/sh."
    ~parameters:[
      { name = "command";
        description = "Shell command to execute";
        param_type = Agent_sdk.Types.String; required = true };
      { name = "timeout_s";
        description = "Timeout in seconds (default 30, max 120)";
        param_type = Agent_sdk.Types.Number; required = false };
    ]
    (fun input ->
       match Agent_swarm_tool_input.extract_string "command" input with
       | Error e -> Error e
       | Ok command ->
         if not (validate_command command) then
           Error (Printf.sprintf "Command blocked: %s" command)
         else
           let timeout =
             Agent_swarm_tool_input.extract_float "timeout_s" input
             |> Option.value ~default:30.0
             |> Float.min 120.0
           in
           try
             Eio.Fiber.first
               (fun () ->
                  Eio.Switch.run @@ fun sw ->
                  let buf = Buffer.create 1024 in
                  let proc = Eio.Process.spawn ~sw proc_mgr
                    ~stdout:(Eio.Flow.buffer_sink buf)
                    ~stderr:(Eio.Flow.buffer_sink buf)
                    ["sh"; "-c"; command] in
                  let status = Eio.Process.await proc in
                  let output = Buffer.contents buf in
                  (match status with
                   | `Exited 0 -> Ok output
                   | `Exited code ->
                     Error (Printf.sprintf "Exit code %d:\n%s" code output)
                   | `Signaled sig_num ->
                     Error (Printf.sprintf "Killed by signal %d:\n%s" sig_num output)))
               (fun () ->
                  Eio.Time.sleep clock timeout;
                  Error (Printf.sprintf "Timeout after %.0fs: %s" timeout command))
           with exn ->
             Error (Printf.sprintf "Command failed: %s" (Printexc.to_string exn)))

(** Create dev tools that close over Eio capabilities.
    Returns [file_read; file_write; shell_exec]. *)
let make_tools ~proc_mgr ~clock ?workdir () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ();
    make_file_write ?workdir ();
    make_shell_exec ~proc_mgr ~clock ]
